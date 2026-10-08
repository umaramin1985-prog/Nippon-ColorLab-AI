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
      final encoderOutputs = encoderSession.run(encoderRunOptions, encoderInputs);
      
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
      final textEmbedding = _matcher.getTextEmbedding(object);
      final imageBytes = await File(imagePath).readAsBytes();
      final image = img.decodeImage(imageBytes);
      if (image == null) return null;

      double bestSimilarity = -1.0;
      AIMask? bestMask;

      final imageEmbeddingsTensor = OrtValueTensor.createTensorWithDataList(_lastImageEmbeddings!, [1, 256, 64, 64]);

      for (int gy = 1; gy <= 3; gy++) {
        for (int gx = 1; gx <= 3; gx++) {
          double scale = 1024.0 / math.max(_lastOrigW, _lastOrigH);
          double newW = _lastOrigW * scale;
          double newH = _lastOrigH * scale;
          
          double px = (gx * newW / 4);
          double py = (gy * newH / 4);

          final pointCoords = Float32List.fromList([px, py]);
          final pointLabels = Float32List.fromList([1.0]);
          final maskInput = Float32List(1 * 1 * 256 * 256);
          final hasMaskInput = Float32List.fromList([0.0]);
          final origImSize = Float32List.fromList([_lastOrigH.toDouble(), _lastOrigW.toDouble()]);

          final pointCoordsTensor = OrtValueTensor.createTensorWithDataList(pointCoords, [1, 1, 2]);
          final pointLabelsTensor = OrtValueTensor.createTensorWithDataList(pointLabels, [1, 1]);
          final maskInputTensor = OrtValueTensor.createTensorWithDataList(maskInput, [1, 1, 256, 256]);
          final hasMaskInputTensor = OrtValueTensor.createTensorWithDataList(hasMaskInput, [1]);
          final origImSizeTensor = OrtValueTensor.createTensorWithDataList(origImSize, [2]);

          final decoderRunOptions = OrtRunOptions();
          final decoded = decoderSession.run(decoderRunOptions, {
            'image_embeddings': imageEmbeddingsTensor,
            'point_coords': pointCoordsTensor,
            'point_labels': pointLabelsTensor,
            'mask_input': maskInputTensor,
            'has_mask_input': hasMaskInputTensor,
            'orig_im_size': origImSizeTensor,
          });
          
          final rawMask = decoded[0]?.value;
          final currentOrigW = _lastOrigW;
          final currentOrigH = _lastOrigH;

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

            int minX = currentOrigW, minY = currentOrigH, maxX = 0, maxY = 0;
            final confMask = List<double>.filled(currentOrigW * currentOrigH, 0.0);

            for (int y = 0; y < currentOrigH; y++) {
              for (int x = 0; x < currentOrigW; x++) {
                if (maskValues[y * currentOrigW + x] > 0.0) {
                  if (x < minX) minX = x;
                  if (x > maxX) maxX = x;
                  if (y < minY) minY = y;
                  if (y > maxY) maxY = y;
                  
                  confMask[y * currentOrigW + x] = 1.0;
                }
              }
            }
            return [confMask, minX, minY, maxX, maxY];
          });

          int minX = maskResult[1] as int;
          int minY = maskResult[2] as int;
          int maxX = maskResult[3] as int;
          int maxY = maskResult[4] as int;
          final confMask = maskResult[0] as List<double>;

          if (maxX > minX && maxY > minY) {
            int cropW = maxX - minX;
            int cropH = maxY - minY;
            
            if (cropW > 0 && cropH > 0) {
              img.Image candidateCrop = img.copyCrop(image, x: minX, y: minY, width: cropW, height: cropH);
              final candidateEmbed = _matcher.getImageEmbedding(candidateCrop);
              double similarity = _matcher.calculateSimilarity(textEmbedding, candidateEmbed);
              
              // MobileCLIP prefers tight crops of plain textures, which penalizes large objects like walls that include other items in their bounding box.
              // We add a small area bias to prefer larger masks.
              double areaRatio = (cropW * cropH) / (_lastOrigW * _lastOrigH);
              double adjustedSimilarity = similarity + (areaRatio * 0.1);
              
              if (adjustedSimilarity > bestSimilarity) {
                bestSimilarity = adjustedSimilarity;
                bestMask = AIMask(confMask, 0, 0, _lastOrigW, _lastOrigH);
              }
            }
          }

          pointCoordsTensor.release();
          pointLabelsTensor.release();
          maskInputTensor.release();
          hasMaskInputTensor.release();
          origImSizeTensor.release();
          decoderRunOptions.release();
          for (var out in decoded) { out?.release(); }
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

      final imageEmbeddingsTensor = OrtValueTensor.createTensorWithDataList(_lastImageEmbeddings!, [1, 256, 64, 64]);
      final pointCoordsTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([px, py]), [1, 1, 2]);
      final pointLabelsTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([1.0]), [1, 1]);
      final maskInputTensor = OrtValueTensor.createTensorWithDataList(Float32List(1 * 1 * 256 * 256), [1, 1, 256, 256]);
      final hasMaskInputTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([0.0]), [1]);
      final origImSizeTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([_lastOrigH.toDouble(), _lastOrigW.toDouble()]), [2]);

      final decoderRunOptions = OrtRunOptions();
      final decoded = decoderSession.run(decoderRunOptions, {
        'image_embeddings': imageEmbeddingsTensor,
        'point_coords': pointCoordsTensor,
        'point_labels': pointLabelsTensor,
        'mask_input': maskInputTensor,
        'has_mask_input': hasMaskInputTensor,
        'orig_im_size': origImSizeTensor,
      });
      
      final rawMask = decoded[0]?.value;
      final currentOrigW = _lastOrigW;
      final currentOrigH = _lastOrigH;
      
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

        final confMask = List<double>.filled(currentOrigW * currentOrigH, 0.0);
        int minX = currentOrigW, minY = currentOrigH, maxX = 0, maxY = 0;

        for (int y = 0; y < currentOrigH; y++) {
          for (int x = 0; x < currentOrigW; x++) {
            if (maskValues[y * currentOrigW + x] > 0.0) {
              if (x < minX) minX = x;
              if (x > maxX) maxX = x;
              if (y < minY) minY = y;
              if (y > maxY) maxY = y;

              confMask[y * currentOrigW + x] = 1.0;
            }
          }
        }
        return [confMask, minX, minY, maxX, maxY];
      });

          int minX = maskResult[1] as int;
          int minY = maskResult[2] as int;
          int maxX = maskResult[3] as int;
          int maxY = maskResult[4] as int;
          final confMask = maskResult[0] as List<double>;

      pointCoordsTensor.release();
      pointLabelsTensor.release();
      maskInputTensor.release();
      hasMaskInputTensor.release();
      origImSizeTensor.release();
      imageEmbeddingsTensor.release();
      decoderRunOptions.release();
      for (var out in decoded) { out?.release(); }

      if (maxX < minX || maxY < minY) return null;

      return AIMask(confMask, 0, 0, _lastOrigW, _lastOrigH);
    } catch (e, stack) {
      debugPrint("LiteSegmentation Error (Point): $e\n$stack");
      return null;
    }
  }

  @override
  void dispose() {}
}
