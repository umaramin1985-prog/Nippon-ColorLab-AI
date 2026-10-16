import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'onnxruntime_stub.dart' if (dart.library.io) 'package:onnxruntime/onnxruntime.dart';
import '../models/ai_mask.dart';
import 'ai_segmentation_service.dart';
import 'lite_model_manager.dart';
import 'lite_object_matcher.dart';

class LiteSegmentationService implements AISegmentationService {
  final LiteObjectMatcher _matcher = LiteObjectMatcher();

  LiteSegmentationService();

  String? _lastImagePath;
  Float32List? _lastImageEmbeddings;
  int _lastOrigW = 0;
  int _lastOrigH = 0;

  Future<void> _ensureEmbeddings(String imagePath, [ProgressCallback? onProgress]) async {
    try {
      onProgress?.call(0.05, "Initializing AI models...");
      final samReady = await LiteModelManager().initSam();
      if (!samReady) return;
      if (_lastImagePath == imagePath && _lastImageEmbeddings != null) {
        onProgress?.call(0.25, "Image features ready");
        return;
      }

      onProgress?.call(0.10, "Preprocessing image...");
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
      List<dynamic>? encoderOutputs;
      try {
        onProgress?.call(0.18, "Generating image embeddings...");
        final encoderInputs = {encoderSession.inputNames[0]: encoderInputTensor};
        encoderOutputs = await encoderSession.runAsync(encoderRunOptions, encoderInputs);
        if (encoderOutputs == null) return;
        
        onProgress?.call(0.26, "Extracting features...");
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
      } finally {
        encoderInputTensor.release();
        encoderRunOptions.release();
        if (encoderOutputs != null) {
          for (var out in encoderOutputs) {
            out?.release();
          }
        }
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
    ProgressCallback? onProgress,
  }) async {
    try {
      await _ensureEmbeddings(imagePath, onProgress);
      if (_lastImageEmbeddings == null) return null;

      final decoderSession = LiteModelManager().samDecoder;
      if (decoderSession == null) return null;

      onProgress?.call(0.30, "Analyzing prompt '$object'...");
      await _matcher.initialize();

      final normObj = object.toLowerCase().trim();
      final isCeiling = normObj.contains('ceiling') || normObj.contains('roof');
      final isWall = normObj.contains('wall');
      final isFloor = normObj.contains('floor') || normObj.contains('ground');
      final isTable = normObj.contains('table') || normObj.contains('desk') || normObj.contains('counter') || normObj.contains('bench');
      final isFurniture = normObj.contains('chair') || normObj.contains('sofa') || normObj.contains('couch');
      final isSky = normObj.contains('sky') || normObj.contains('cloud');

      // Craft descriptive prompt for MobileCLIP
      String clipPrompt = object;
      if (isCeiling) {
        clipPrompt = 'the ceiling of a room, overhead ceiling';
      } else if (isSky) {
        clipPrompt = 'the sky, open blue or cloudy sky outside';
      } else if (isWall) {
        clipPrompt = 'an interior wall of a room, vertical painted wall surface';
      } else if (isFloor) {
        clipPrompt = 'the floor or flooring of a room';
      } else if (isTable) {
        clipPrompt = 'a table, desk surface or tabletop';
      } else if (isFurniture) {
        clipPrompt = 'a chair, sofa or seating furniture';
      }

      onProgress?.call(0.38, "Locating surfaces...");
      final textEmbedding = await _matcher.getTextEmbedding(clipPrompt);
      final imageBytes = await File(imagePath).readAsBytes();
      final image = await Isolate.run(() => img.decodeImage(imageBytes));
      if (image == null) return null;

      double bestScore = -1e9;
      AIMask? bestMask;

      final imageEmbeddingsTensor = OrtValueTensor.createTensorWithDataList(_lastImageEmbeddings!, [1, 256, 64, 64]);

      // Define grid points tailored to the target object
      final List<List<double>> samplePoints = [];
      final List<List<List<double>>> negativePoints = [];

      double scale = 1024.0 / math.max(_lastOrigW, _lastOrigH);
      double newW = _lastOrigW * scale;
      double newH = _lastOrigH * scale;

      if (isCeiling) {
        // Ceiling is at the top of the room
        for (var gy in [0.10, 0.18]) {
          for (var gx in [0.25, 0.50, 0.75]) {
            samplePoints.add([gx * newW, gy * newH]);
            negativePoints.add([
              [gx * newW, 0.50 * newH],
            ]);
          }
        }
      } else if (isSky) {
        // Sky is at the upper region of an exterior/outdoor scene
        for (var gy in [0.08, 0.18]) {
          for (var gx in [0.25, 0.50, 0.75]) {
            samplePoints.add([gx * newW, gy * newH]);
            negativePoints.add([
              [gx * newW, 0.75 * newH],
            ]);
          }
        }
      } else if (isWall) {
        // Walls are vertical surfaces spanning middle and upper-middle (6 strategic points)
        for (var gy in [0.28, 0.42]) {
          for (var gx in [0.25, 0.50, 0.75]) {
            samplePoints.add([gx * newW, gy * newH]);
            // Negative prompts: ceiling and table/floor to isolate wall surface
            negativePoints.add([
              [gx * newW, 0.05 * newH],
              [gx * newW, 0.80 * newH],
            ]);
          }
        }
      } else if (isFloor) {
        // Floor is at the bottom
        for (var gy in [0.80, 0.90]) {
          for (var gx in [0.30, 0.50, 0.70]) {
            samplePoints.add([gx * newW, gy * newH]);
            negativePoints.add([
              [gx * newW, 0.10 * newH],
              [gx * newW, 0.45 * newH],
            ]);
          }
        }
      } else if (isTable) {
        // Tables are horizontal surfaces in the lower-middle half
        for (var gy in [0.60, 0.75]) {
          for (var gx in [0.30, 0.50, 0.70]) {
            samplePoints.add([gx * newW, gy * newH]);
            negativePoints.add([
              [gx * newW, 0.15 * newH],
            ]);
          }
        }
      } else {
        // General object: 2x2 grid
        for (int gy = 1; gy <= 2; gy++) {
          for (int gx = 1; gx <= 2; gx++) {
            samplePoints.add([(gx * newW / 3), (gy * newH / 3)]);
            negativePoints.add([]);
          }
        }
      }

      for (int i = 0; i < samplePoints.length; i++) {
        final progress = 0.40 + ((i + 1) / samplePoints.length) * 0.52;
        onProgress?.call(progress, "Scanning surfaces (${(progress * 100).toInt()}%)...");

        final posPt = samplePoints[i];
        final negPts = negativePoints[i];

        final pointCoords = <double>[posPt[0], posPt[1]];
        final pointLabels = <double>[1.0];

        for (final negPt in negPts) {
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

          // Connected component BFS using Float32List (TypedData, zero boxing overhead)
          final visited = Uint8List(currentOrigW * currentOrigH);
          final queue = <int>[];
          final confMask = Float32List(currentOrigW * currentOrigH);

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
            double conf = prob >= 0.5 ? 1.0 : (prob - 0.35) / 0.15;
            confMask[idx] = conf.clamp(0.0, 1.0);
            pixelCount++;

            if (cx < minX) minX = cx;
            if (cx > maxX) maxX = cx;
            if (cy < minY) minY = cy;
            if (cy > maxY) maxY = cy;

            if (cx > 0) {
              int nidx = idx - 1;
              if (visited[nidx] == 0 && maskValues[nidx] > -0.2) {
                visited[nidx] = 1;
                queue.add(nidx);
              }
            }
            if (cx < currentOrigW - 1) {
              int nidx = idx + 1;
              if (visited[nidx] == 0 && maskValues[nidx] > -0.2) {
                visited[nidx] = 1;
                queue.add(nidx);
              }
            }
            if (cy > 0) {
              int nidx = idx - currentOrigW;
              if (visited[nidx] == 0 && maskValues[nidx] > -0.2) {
                visited[nidx] = 1;
                queue.add(nidx);
              }
            }
            if (cy < currentOrigH - 1) {
              int nidx = idx + currentOrigW;
              if (visited[nidx] == 0 && maskValues[nidx] > -0.2) {
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
        final confMask = maskResult[0] as Float32List;

        if (maxX > minX && maxY > minY) {
          int cropW = maxX - minX;
          int cropH = maxY - minY;
          double centerY = (minY + maxY) / (2.0 * _lastOrigH);
          double topRatio = minY / _lastOrigH;
          double bottomRatio = maxY / _lastOrigH;
          double heightRatio = cropH / _lastOrigH;

          // Spatial validation
          if (isCeiling) {
            if (topRatio > 0.25 || centerY > 0.40) continue;
          } else if (isWall) {
            if (topRatio > 0.38 || centerY > 0.52) continue;
            if (bottomRatio < 0.30 || heightRatio < 0.15) continue;
            if (topRatio < 0.05 && bottomRatio < 0.25) continue;
          } else if (isFloor) {
            if (bottomRatio < 0.70 || centerY < 0.55) continue;
          } else if (isTable) {
            if (centerY < 0.38 || topRatio < 0.20) continue;
          }

          double areaRatio = (pixelCount) / (_lastOrigW * _lastOrigH);
          double spatialBoost = 0.0;
          if (isCeiling && topRatio < 0.10) {
            spatialBoost = 0.08;
          } else if (isWall && topRatio < 0.28 && centerY < 0.50 && bottomRatio > 0.40) {
            spatialBoost = 0.10;
          } else if (isFloor && bottomRatio > 0.85) {
            spatialBoost = 0.08;
          } else if (isTable && centerY > 0.50 && bottomRatio > 0.60) {
            spatialBoost = 0.08;
          }

          // Branch pruning: skip expensive CLIP inference if candidate cannot beat bestScore
          if (bestScore > -1e8 && (0.25 + (areaRatio * 0.05) + spatialBoost) <= bestScore) {
            continue;
          }

          final candidateEmbed = await _matcher.getCropEmbedding(image, minX, minY, cropW, cropH);
          double similarity = _matcher.calculateSimilarity(textEmbedding, candidateEmbed);
          double score = similarity + (areaRatio * 0.05) + spatialBoost;

          if (score > bestScore) {
            bestScore = score;
            bestMask = AIMask(confMask, 0, 0, _lastOrigW, _lastOrigH);
          }
        }

        // Yield to the UI event loop so the progress indicator animation remains 60FPS fluid
        await Future.delayed(const Duration(milliseconds: 2));
      }

      onProgress?.call(0.96, "Selecting optimal surface...");
      imageEmbeddingsTensor.release();
      onProgress?.call(1.0, "Surface detected!");
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
    ProgressCallback? onProgress,
  }) async {
    try {
      onProgress?.call(0.15, "Loading image features...");
      await _ensureEmbeddings(imagePath, onProgress);
      if (_lastImageEmbeddings == null) return null;

      onProgress?.call(0.40, "Segmenting tapped surface...");
      final decoderSession = LiteModelManager().samDecoder;
      if (decoderSession == null) return null;

      // Scale the tapped point from original image resolution to the unpadded 1024 tensor coordinate space
      double scale = 1024.0 / math.max(_lastOrigW, _lastOrigH);
      double px = point.x * scale;
      double py = point.y * scale;
      double newH = _lastOrigH * scale;

      final pointCoords = <double>[px, py];
      final pointLabels = <double>[1.0];

      // Smart negative prompt:
      if (point.y >= _lastOrigH * 0.20 && point.y <= _lastOrigH * 0.55) {
        // User tapped a wall (middle/upper vertical region):
        // Prevent bleed upward into ceiling and downward into table/floor
        pointCoords.addAll([px, 0.05 * newH]);
        pointLabels.add(0.0);
        pointCoords.addAll([px, 0.85 * newH]);
        pointLabels.add(0.0);
      } else if (point.y < _lastOrigH * 0.20) {
        // User tapped ceiling (top 20% of height): prevent downward bleed into wall
        pointCoords.addAll([px, 0.50 * newH]);
        pointLabels.add(0.0);
      } else if (point.y > _lastOrigH * 0.55) {
        // User tapped furniture, table, or floor: prevent upward bleed into wall
        pointCoords.addAll([px, 0.25 * newH]);
        pointLabels.add(0.0);
      }

      final numPoints = pointLabels.length;
      OrtValueTensor? imageEmbeddingsTensor;
      OrtValueTensor? pointCoordsTensor;
      OrtValueTensor? pointLabelsTensor;
      OrtValueTensor? maskInputTensor;
      OrtValueTensor? hasMaskInputTensor;
      OrtValueTensor? origImSizeTensor;
      OrtRunOptions? decoderRunOptions;
      List<dynamic>? decoded;

      dynamic rawMask;
      try {
        imageEmbeddingsTensor = OrtValueTensor.createTensorWithDataList(_lastImageEmbeddings!, [1, 256, 64, 64]);
        pointCoordsTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList(pointCoords), [1, numPoints, 2]);
        pointLabelsTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList(pointLabels), [1, numPoints]);
        maskInputTensor = OrtValueTensor.createTensorWithDataList(Float32List(1 * 1 * 256 * 256), [1, 1, 256, 256]);
        hasMaskInputTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([0.0]), [1]);
        origImSizeTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([_lastOrigH.toDouble(), _lastOrigW.toDouble()]), [2]);

        decoderRunOptions = OrtRunOptions();
        decoded = await decoderSession.runAsync(decoderRunOptions, {
          'image_embeddings': imageEmbeddingsTensor,
          'point_coords': pointCoordsTensor,
          'point_labels': pointLabelsTensor,
          'mask_input': maskInputTensor,
          'has_mask_input': hasMaskInputTensor,
          'orig_im_size': origImSizeTensor,
        });
        if (decoded == null) return null;
        
        rawMask = decoded[0]?.value;
      } finally {
        pointCoordsTensor?.release();
        pointLabelsTensor?.release();
        maskInputTensor?.release();
        hasMaskInputTensor?.release();
        origImSizeTensor?.release();
        imageEmbeddingsTensor?.release();
        decoderRunOptions?.release();
        if (decoded != null) {
          for (var out in decoded) {
            out?.release();
          }
        }
      }

      if (rawMask == null) return null;

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
        final confMask = Float32List(currentOrigW * currentOrigH);

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
          double conf = prob >= 0.5 ? 1.0 : (prob - 0.35) / 0.15;
          confMask[idx] = conf.clamp(0.0, 1.0);
          pixelCount++;

          if (cx < minX) minX = cx;
          if (cx > maxX) maxX = cx;
          if (cy < minY) minY = cy;
          if (cy > maxY) maxY = cy;

          if (cx > 0) {
            int nidx = idx - 1;
            if (visited[nidx] == 0 && maskValues[nidx] > -0.2) {
              visited[nidx] = 1;
              queue.add(nidx);
            }
          }
          if (cx < currentOrigW - 1) {
            int nidx = idx + 1;
            if (visited[nidx] == 0 && maskValues[nidx] > -0.2) {
              visited[nidx] = 1;
              queue.add(nidx);
            }
          }
          if (cy > 0) {
            int nidx = idx - currentOrigW;
            if (visited[nidx] == 0 && maskValues[nidx] > -0.2) {
              visited[nidx] = 1;
              queue.add(nidx);
            }
          }
          if (cy < currentOrigH - 1) {
            int nidx = idx + currentOrigW;
            if (visited[nidx] == 0 && maskValues[nidx] > -0.2) {
              visited[nidx] = 1;
              queue.add(nidx);
            }
          }
        }

        if (pixelCount < 20) return null;
        return [confMask, minX, minY, maxX, maxY];
      });

      if (maskResult == null) return null;

      onProgress?.call(1.0, "Surface detected!");
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
