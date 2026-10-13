import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'onnxruntime_stub.dart' if (dart.library.io) 'package:onnxruntime/onnxruntime.dart';
import '../models/ai_mask.dart';
import 'ai_segmentation_service.dart';
import 'lite_model_manager.dart';
import 'lite_object_matcher.dart';

class LiteSegmentationService implements AISegmentationService {
  final LiteObjectMatcher _matcher = LiteObjectMatcher();

  LiteSegmentationService() {
    _matcher.initialize();
    LiteModelManager().initialize();
  }

  String? _lastImagePath;
  Float32List? _lastImageEmbeddings;
  int _lastOrigW = 0;
  int _lastOrigH = 0;

  Future<void> _ensureEmbeddings(String imagePath) async {
    try {
      await LiteModelManager().initialize();
      if (_lastImagePath == imagePath && _lastImageEmbeddings != null) return;

      final imageBytes = await File(imagePath).readAsBytes();
      
      final prepData = await Isolate.run(() {
        final image = img.decodeImage(imageBytes);
        if (image == null) return null;

        final origW = image.width;
        final origH = image.height;

        int newW, newH;
        if (origW > origH) {
          newW = 1024;
          newH = (1024.0 * origH / origW).round();
        } else {
          newH = 1024;
          newW = (1024.0 * origW / origH).round();
        }

        final resized = img.copyResize(image, width: newW, height: newH);
        final floatList = Float32List(1024 * 1024 * 3);
        
        int index = 0;
        for (int y = 0; y < 1024; y++) {
          for (int x = 0; x < 1024; x++) {
            if (x < newW && y < newH) {
              final pixel = resized.getPixel(x, y);
              floatList[index++] = pixel.r.toDouble();
              floatList[index++] = pixel.g.toDouble();
              floatList[index++] = pixel.b.toDouble();
            } else {
              floatList[index++] = 0.0;
              floatList[index++] = 0.0;
              floatList[index++] = 0.0;
            }
          }
        }
        return [floatList, origW, origH];
      });

      if (prepData == null) return;
      _lastOrigW = prepData[1] as int;
      _lastOrigH = prepData[2] as int;
      final floatList = prepData[0] as Float32List;

      final encoderSession = LiteModelManager().samEncoder;
      if (encoderSession == null) return;

      final encoderInputTensor = OrtValueTensor.createTensorWithDataList(floatList, [1024, 1024, 3]);
      final encoderRunOptions = OrtRunOptions();
      final encoderInputs = {encoderSession.inputNames[0]: encoderInputTensor};
      final encoderOutputs = await encoderSession.runAsync(encoderRunOptions, encoderInputs);
      if (encoderOutputs == null) return;
      
      final rawEmbeddings = encoderOutputs[0]?.value;
      
      final flatEmbeddings = await Isolate.run(() {
        final flat = Float32List(1 * 256 * 64 * 64);
        if (rawEmbeddings is List) {
          int idx = 0;
          void flatten(dynamic list) {
            if (list is List) {
              for (var e in list) flatten(e);
            } else if (list is num) {
              if (idx < flat.length) flat[idx++] = list.toDouble();
            }
          }
          flatten(rawEmbeddings);
        } else if (rawEmbeddings is Float32List) {
          flat.setAll(0, rawEmbeddings);
        }
        return flat;
      });
      
      _lastImageEmbeddings = flatEmbeddings;
      _lastImagePath = imagePath;

      encoderInputTensor.release();
      encoderRunOptions.release();
      for (var out in encoderOutputs) {
        out?.release();
      }
    } catch (e, stack) {
      debugPrint("LiteSegmentation _ensureEmbeddings Error: $e\n$stack");
    }
  }

  @override
  Future<AIMask?> segment({
    required String imagePath,
    required String object,
    String? position,
  }) async {
    try {
      await _ensureEmbeddings(imagePath);
      if (_lastImageEmbeddings == null) return null;

      final decoderSession = LiteModelManager().samDecoder;
      if (decoderSession == null) return null;

      await _matcher.initialize();

      final normObj = object.toLowerCase().trim();
      final isCeiling = normObj.contains('ceiling') || normObj.contains('roof');
      final isWall = normObj.contains('wall');
      final isFloor = normObj.contains('floor') || normObj.contains('ground');

      // Craft descriptive prompt for MobileCLIP
      String clipPrompt = object;
      if (isCeiling) {
        clipPrompt = 'the ceiling of a room, overhead ceiling';
      } else if (isWall) {
        clipPrompt = 'an interior wall of a room, painted vertical wall';
      } else if (isFloor) {
        clipPrompt = 'the floor of a room';
      }

      final textEmbedding = await _matcher.getTextEmbedding(clipPrompt);
      final imageBytes = await File(imagePath).readAsBytes();
      final image = await Isolate.run(() => img.decodeImage(imageBytes));
      if (image == null) return null;

      double bestScore = -1e9;
      AIMask? bestMask;

      final imageEmbeddingsTensor = OrtValueTensor.createTensorWithDataList(_lastImageEmbeddings!, [1, 256, 64, 64]);

      // Define grid points tailored to the target object
      final List<List<double>> samplePoints = [];
      final List<List<double>?> negativePoints = [];

      double scale = 1024.0 / math.max(_lastOrigW, _lastOrigH);
      double newW = _lastOrigW * scale;
      double newH = _lastOrigH * scale;

      if (isCeiling) {
        // Ceiling is at the top of the room
        for (var gy in [0.08, 0.15, 0.22]) {
          for (var gx in [0.25, 0.50, 0.75]) {
            samplePoints.add([gx * newW, gy * newH]);
            // Negative prompt down in the wall area
            negativePoints.add([gx * newW, 0.55 * 1024]);
          }
        }
      } else if (isWall) {
        // Walls are vertical surfaces spanning middle and upper-middle
        for (var gy in [0.35, 0.50, 0.65]) {
          for (var gx in [0.20, 0.35, 0.50, 0.65, 0.80]) {
            samplePoints.add([gx * newW, gy * newH]);
            // Negative prompt up in the ceiling area
            negativePoints.add([gx * newW, 0.05 * 1024]);
          }
        }
      } else if (isFloor) {
        // Floor is at the bottom
        for (var gy in [0.75, 0.85, 0.92]) {
          for (var gx in [0.30, 0.50, 0.70]) {
            samplePoints.add([gx * newW, gy * newH]);
            negativePoints.add([gx * newW, 0.05 * 1024]);
          }
        }
      } else {
        // General object: 3x3 grid
        for (int gy = 1; gy <= 3; gy++) {
          for (int gx = 1; gx <= 3; gx++) {
            samplePoints.add([(gx * newW / 4), (gy * newH / 4)]);
            negativePoints.add(null);
          }
        }
      }

      for (int i = 0; i < samplePoints.length; i++) {
        final posPt = samplePoints[i];
        final negPt = negativePoints[i];

        final pointCoords = <double>[posPt[0], posPt[1]];
        final pointLabels = <double>[1.0];

        if (negPt != null) {
          pointCoords.addAll([negPt[0], negPt[1]]);
          pointLabels.add(0.0);
        }

        final numPoints = pointLabels.length;
        final pointCoordsTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList(pointCoords), [1, numPoints, 2]);
        final pointLabelsTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList(pointLabels), [1, numPoints]);
        final maskInputTensor = OrtValueTensor.createTensorWithDataList(Float32List(1 * 1 * 256 * 256), [1, 1, 256, 256]);
        final hasMaskInputTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([0.0]), [1]);
        final origImSizeTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([_lastOrigH.toDouble(), _lastOrigW.toDouble()]), [2]);

        final decoderRunOptions = OrtRunOptions();
        final decoded = await decoderSession.runAsync(decoderRunOptions, {
          'image_embeddings': imageEmbeddingsTensor,
          'point_coords': pointCoordsTensor,
          'point_labels': pointLabelsTensor,
          'mask_input': maskInputTensor,
          'has_mask_input': hasMaskInputTensor,
          'orig_im_size': origImSizeTensor,
        });
        if (decoded == null) {
          pointCoordsTensor.release();
          pointLabelsTensor.release();
          maskInputTensor.release();
          hasMaskInputTensor.release();
          origImSizeTensor.release();
          decoderRunOptions.release();
          continue;
        }

        final rawMask = decoded[0]?.value;
        final currentOrigW = _lastOrigW;
        final currentOrigH = _lastOrigH;

        final origTapX = (posPt[0] / scale).round().clamp(0, currentOrigW - 1);
        final origTapY = (posPt[1] / scale).round().clamp(0, currentOrigH - 1);

        final maskResult = await Isolate.run(() {
          final maskValues = Float32List(currentOrigH * currentOrigW);
          if (rawMask is List) {
            int idx = 0;
            void flatten(dynamic list) {
              if (list is List) {
                for (var e in list) flatten(e);
              } else if (list is num) {
                if (idx < maskValues.length) maskValues[idx++] = list.toDouble();
              }
            }
            flatten(rawMask);
          } else if (rawMask is Float32List) {
            maskValues.setAll(0, rawMask);
          }

          // Check if seed has positive logit or search nearby
          int seedX = origTapX;
          int seedY = origTapY;
          if (maskValues[seedY * currentOrigW + seedX] <= 0.0) {
            double maxV = -1e9;
            for (int r = 1; r <= 15; r++) {
              for (int dy = -r; dy <= r; dy++) {
                for (int dx = -r; dx <= r; dx++) {
                  int nx = origTapX + dx;
                  int ny = origTapY + dy;
                  if (nx >= 0 && nx < currentOrigW && ny >= 0 && ny < currentOrigH) {
                    double v = maskValues[ny * currentOrigW + nx];
                    if (v > maxV) {
                      maxV = v;
                      seedX = nx;
                      seedY = ny;
                    }
                  }
                }
              }
              if (maxV > 0.0) break;
            }
          }

          if (maskValues[seedY * currentOrigW + seedX] <= 0.0) {
            return null;
          }

          // Connected component BFS
          final visited = Uint8List(currentOrigW * currentOrigH);
          final queue = <int>[];
          final confMask = List<double>.filled(currentOrigW * currentOrigH, 0.0);

          int startIdx = seedY * currentOrigW + seedX;
          queue.add(startIdx);
          visited[startIdx] = 1;

          int minX = currentOrigW, minY = currentOrigH, maxX = 0, maxY = 0;
          int pixelCount = 0;

          while (queue.isNotEmpty) {
            int idx = queue.removeLast();
            int cx = idx % currentOrigW;
            int cy = idx ~/ currentOrigW;

            double val = maskValues[idx];
            double prob = 1.0 / (1.0 + math.exp(-val));
            double conf = prob >= 0.7 ? 1.0 : (prob - 0.5) / 0.2;
            confMask[idx] = conf.clamp(0.0, 1.0);
            pixelCount++;

            if (cx < minX) minX = cx;
            if (cx > maxX) maxX = cx;
            if (cy < minY) minY = cy;
            if (cy > maxY) maxY = cy;

            if (cx > 0) {
              int nidx = idx - 1;
              if (visited[nidx] == 0 && maskValues[nidx] > 0.0) {
                visited[nidx] = 1;
                queue.add(nidx);
              }
            }
            if (cx < currentOrigW - 1) {
              int nidx = idx + 1;
              if (visited[nidx] == 0 && maskValues[nidx] > 0.0) {
                visited[nidx] = 1;
                queue.add(nidx);
              }
            }
            if (cy > 0) {
              int nidx = idx - currentOrigW;
              if (visited[nidx] == 0 && maskValues[nidx] > 0.0) {
                visited[nidx] = 1;
                queue.add(nidx);
              }
            }
            if (cy < currentOrigH - 1) {
              int nidx = idx + currentOrigW;
              if (visited[nidx] == 0 && maskValues[nidx] > 0.0) {
                visited[nidx] = 1;
                queue.add(nidx);
              }
            }
          }

          if (pixelCount < 50) return null;
          return [confMask, minX, minY, maxX, maxY, pixelCount];
        });

        pointCoordsTensor.release();
        pointLabelsTensor.release();
        maskInputTensor.release();
        hasMaskInputTensor.release();
        origImSizeTensor.release();
        decoderRunOptions.release();
        for (var out in decoded) { out?.release(); }

        if (maskResult == null) continue;

        int minX = maskResult[1] as int;
        int minY = maskResult[2] as int;
        int maxX = maskResult[3] as int;
        int maxY = maskResult[4] as int;
        int pixelCount = maskResult[5] as int;
        final confMask = maskResult[0] as List<double>;

        if (maxX > minX && maxY > minY) {
          int cropW = maxX - minX;
          int cropH = maxY - minY;
          double centerY = (minY + maxY) / (2.0 * _lastOrigH);
          double topRatio = minY / _lastOrigH;
          double bottomRatio = maxY / _lastOrigH;

          // Spatial validation
          if (isCeiling) {
            // Ceiling MUST be near the top: bounding box shouldn't start below 25% or have center below 40%
            if (topRatio > 0.25 || centerY > 0.40) continue;
          } else if (isWall) {
            // Wall must have substantial height and extend downwards
            if (bottomRatio < 0.35) continue;
            // Wall shouldn't be purely a thin strip at the very top (ceiling)
            if (topRatio < 0.05 && bottomRatio < 0.25) continue;
          } else if (isFloor) {
            if (bottomRatio < 0.70 || centerY < 0.55) continue;
          }

          img.Image candidateCrop = await Isolate.run(() => img.copyCrop(image, x: minX, y: minY, width: cropW, height: cropH));
          final candidateEmbed = await _matcher.getImageEmbedding(candidateCrop);
          double similarity = _matcher.calculateSimilarity(textEmbedding, candidateEmbed);

          double areaRatio = (pixelCount) / (_lastOrigW * _lastOrigH);
          double score = similarity + (areaRatio * 0.05);

          // Spatial prior boost
          if (isCeiling && topRatio < 0.10) {
            score += 0.08;
          } else if (isWall && bottomRatio > 0.50 && topRatio > 0.08) {
            score += 0.08;
          }

          if (score > bestScore) {
            bestScore = score;
            bestMask = AIMask(confMask, 0, 0, _lastOrigW, _lastOrigH);
          }
        }
      }

      imageEmbeddingsTensor.release();
      return bestMask;
    } catch (e, stack) {
      debugPrint("LiteSegmentation Error: $e\n$stack");
      rethrow;
    }
  }

  @override
  Future<AIMask?> segmentByPoint({
    required String imagePath,
    required math.Point<int> point,
  }) async {
    try {
      await _ensureEmbeddings(imagePath);
      if (_lastImageEmbeddings == null) return null;

      final decoderSession = LiteModelManager().samDecoder;
      if (decoderSession == null) return null;

      // Scale the tapped point from original image resolution to the unpadded 1024 tensor coordinate space
      double scale = 1024.0 / math.max(_lastOrigW, _lastOrigH);
      double px = point.x * scale;
      double py = point.y * scale;

      final pointCoords = <double>[px, py];
      final pointLabels = <double>[1.0];

      // Smart negative prompt:
      // If user tapped a wall (below 28% of height), place negative prompt in ceiling to prevent upward bleed
      if (point.y > _lastOrigH * 0.28) {
        pointCoords.addAll([px, 0.05 * 1024]);
        pointLabels.add(0.0);
      } else if (point.y < _lastOrigH * 0.18) {
        // If user tapped ceiling (top 18% of height), place negative prompt on wall below to prevent downward bleed
        pointCoords.addAll([px, 0.55 * 1024]);
        pointLabels.add(0.0);
      }

      final numPoints = pointLabels.length;
      final imageEmbeddingsTensor = OrtValueTensor.createTensorWithDataList(_lastImageEmbeddings!, [1, 256, 64, 64]);
      final pointCoordsTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList(pointCoords), [1, numPoints, 2]);
      final pointLabelsTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList(pointLabels), [1, numPoints]);
      final maskInputTensor = OrtValueTensor.createTensorWithDataList(Float32List(1 * 1 * 256 * 256), [1, 1, 256, 256]);
      final hasMaskInputTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([0.0]), [1]);
      final origImSizeTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([_lastOrigH.toDouble(), _lastOrigW.toDouble()]), [2]);

      final decoderRunOptions = OrtRunOptions();
      final decoded = await decoderSession.runAsync(decoderRunOptions, {
        'image_embeddings': imageEmbeddingsTensor,
        'point_coords': pointCoordsTensor,
        'point_labels': pointLabelsTensor,
        'mask_input': maskInputTensor,
        'has_mask_input': hasMaskInputTensor,
        'orig_im_size': origImSizeTensor,
      });
      if (decoded == null) return null;
      
      final rawMask = decoded[0]?.value;
      final currentOrigW = _lastOrigW;
      final currentOrigH = _lastOrigH;
      final tapX = point.x.clamp(0, currentOrigW - 1);
      final tapY = point.y.clamp(0, currentOrigH - 1);
      
      final maskResult = await Isolate.run(() {
        final maskValues = Float32List(currentOrigH * currentOrigW);
        if (rawMask is List) {
          int idx = 0;
          void flatten(dynamic list) {
            if (list is List) {
              for (var e in list) flatten(e);
            } else if (list is num) {
              if (idx < maskValues.length) maskValues[idx++] = list.toDouble();
            }
          }
          flatten(rawMask);
        } else if (rawMask is Float32List) {
          maskValues.setAll(0, rawMask);
        }

        // Find nearest positive seed to user tap
        int seedX = tapX;
        int seedY = tapY;
        if (maskValues[seedY * currentOrigW + seedX] <= 0.0) {
          double maxVal = -1e9;
          for (int r = 1; r <= 15; r++) {
            for (int dy = -r; dy <= r; dy++) {
              for (int dx = -r; dx <= r; dx++) {
                int nx = tapX + dx;
                int ny = tapY + dy;
                if (nx >= 0 && nx < currentOrigW && ny >= 0 && ny < currentOrigH) {
                  double val = maskValues[ny * currentOrigW + nx];
                  if (val > maxVal) {
                    maxVal = val;
                    seedX = nx;
                    seedY = ny;
                  }
                }
              }
            }
            if (maxVal > 0.0) break;
          }
        }

        if (maskValues[seedY * currentOrigW + seedX] <= 0.0) {
          return null;
        }

        // Connected component extraction starting from tapped seed
        final visited = Uint8List(currentOrigW * currentOrigH);
        final queue = <int>[];
        final confMask = List<double>.filled(currentOrigW * currentOrigH, 0.0);

        int startIdx = seedY * currentOrigW + seedX;
        queue.add(startIdx);
        visited[startIdx] = 1;

        int minX = currentOrigW, minY = currentOrigH, maxX = 0, maxY = 0;
        int pixelCount = 0;

        while (queue.isNotEmpty) {
          int idx = queue.removeLast();
          int cx = idx % currentOrigW;
          int cy = idx ~/ currentOrigW;

          double val = maskValues[idx];
          double prob = 1.0 / (1.0 + math.exp(-val));
          double conf = prob >= 0.7 ? 1.0 : (prob - 0.5) / 0.2;
          confMask[idx] = conf.clamp(0.0, 1.0);
          pixelCount++;

          if (cx < minX) minX = cx;
          if (cx > maxX) maxX = cx;
          if (cy < minY) minY = cy;
          if (cy > maxY) maxY = cy;

          if (cx > 0) {
            int nidx = idx - 1;
            if (visited[nidx] == 0 && maskValues[nidx] > 0.0) {
              visited[nidx] = 1;
              queue.add(nidx);
            }
          }
          if (cx < currentOrigW - 1) {
            int nidx = idx + 1;
            if (visited[nidx] == 0 && maskValues[nidx] > 0.0) {
              visited[nidx] = 1;
              queue.add(nidx);
            }
          }
          if (cy > 0) {
            int nidx = idx - currentOrigW;
            if (visited[nidx] == 0 && maskValues[nidx] > 0.0) {
              visited[nidx] = 1;
              queue.add(nidx);
            }
          }
          if (cy < currentOrigH - 1) {
            int nidx = idx + currentOrigW;
            if (visited[nidx] == 0 && maskValues[nidx] > 0.0) {
              visited[nidx] = 1;
              queue.add(nidx);
            }
          }
        }

        if (pixelCount < 20) return null;
        return [confMask, minX, minY, maxX, maxY];
      });

      pointCoordsTensor.release();
      pointLabelsTensor.release();
      maskInputTensor.release();
      hasMaskInputTensor.release();
      origImSizeTensor.release();
      imageEmbeddingsTensor.release();
      decoderRunOptions.release();
      for (var out in decoded) { out?.release(); }

      if (maskResult == null) return null;

      final confMask = maskResult[0] as List<double>;
      return AIMask(confMask, 0, 0, _lastOrigW, _lastOrigH);
    } catch (e, stack) {
      debugPrint("LiteSegmentation Error (Point): $e\n$stack");
      return null;
    }
  }

  @override
  void dispose() {}
}
