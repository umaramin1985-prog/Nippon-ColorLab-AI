import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'lite_model_manager.dart';

class LiteObjectMatcher {
  Map<String, int> _vocab = {};

  Future<void> initialize() async {
    if (_vocab.isNotEmpty) return;
    try {
      final jsonStr = await rootBundle.loadString('assets/models/mobileclip/tokenizer.json');
      final Map<String, dynamic> data = jsonDecode(jsonStr);
      final vocabMap = data['model']['vocab'] as Map<String, dynamic>;
      _vocab = vocabMap.map((key, value) => MapEntry(key, value as int));
      print("LiteObjectMatcher: Tokenizer loaded with ${_vocab.length} tokens.");
    } catch (e) {
      print("LiteObjectMatcher Tokenizer Error: $e");
    }
  }

  int _getToken(String word) {
    return _vocab['$word</w>'] ?? _vocab[word] ?? _vocab['<unk>'] ?? 49407;
  }

  List<double> getTextEmbedding(String text) {
    try {
      final session = LiteModelManager().clipText;
      if (session == null) throw Exception("CLIP Text session not initialized");

      final words = text.toLowerCase().split(' ');
      final inputIds = List<int>.filled(77, 0);

      inputIds[0] = 49406; // SOT

      int idx = 1;
      for (var w in words) {
        if (idx >= 76) break;
        inputIds[idx] = _getToken(w);
        idx++;
      }
      
      inputIds[idx] = 49407; // EOT

      final inputIdsBuffer = Int64List.fromList(inputIds);
      final inputIdsTensor = OrtValueTensor.createTensorWithDataList(inputIdsBuffer, [1, 77]);

      final runOptions = OrtRunOptions();
      final inputs = {
        session.inputNames[0]: inputIdsTensor,
      };

      final outputs = session.run(runOptions, inputs);
      final textEmbedsTensor = outputs[0]?.value as OrtValueTensor;
      final rawEmbeds = textEmbedsTensor.value;
      
      final flatEmbeds = Float32List(512);
      if (rawEmbeds is List) {
        int flatIdx = 0;
        void flatten(dynamic list) {
          if (list is List) {
            for (var e in list) flatten(e);
          } else if (list is num) {
            if (flatIdx < 512) flatEmbeds[flatIdx++] = list.toDouble();
          }
        }
        flatten(rawEmbeds);
      } else if (rawEmbeds is Float32List) {
        flatEmbeds.setAll(0, rawEmbeds);
      }

      inputIdsTensor.release();
      for (var out in outputs) {
        out?.release();
      }
      runOptions.release();

      return _normalize(flatEmbeds);
    } catch (e, stack) {
      print("getTextEmbedding error: $e\n$stack");
      return List<double>.filled(512, 0.0);
    }
  }

  List<double> getImageEmbedding(img.Image image) {
    try {
      final session = LiteModelManager().clipVision;
      if (session == null) throw Exception("CLIP Vision session not initialized");

      img.Image resized = img.copyResizeCropSquare(image, size: 256);

      final floatList = Float32List(1 * 3 * 256 * 256);
      final mean = [0.48145466, 0.4578275, 0.40821073];
      final std = [0.26862954, 0.26130258, 0.27577711];

      int planeSize = 256 * 256;
      for (int y = 0; y < 256; y++) {
        for (int x = 0; x < 256; x++) {
          final pixel = resized.getPixel(x, y);
          int index = y * 256 + x;
          floatList[index] = ((pixel.r / 255.0) - mean[0]) / std[0]; // R
          floatList[planeSize + index] = ((pixel.g / 255.0) - mean[1]) / std[1]; // G
          floatList[2 * planeSize + index] = ((pixel.b / 255.0) - mean[2]) / std[2]; // B
        }
      }

      final inputTensor = OrtValueTensor.createTensorWithDataList(floatList, [1, 3, 256, 256]);
      final runOptions = OrtRunOptions();
      final inputs = {session.inputNames[0]: inputTensor};

      final outputs = session.run(runOptions, inputs);
      final imageEmbedsTensor = outputs[0]?.value as OrtValueTensor;
      final rawEmbeds = imageEmbedsTensor.value;
      
      final flatEmbeds = Float32List(512);
      if (rawEmbeds is List) {
        int flatIdx = 0;
        void flatten(dynamic list) {
          if (list is List) {
            for (var e in list) flatten(e);
          } else if (list is num) {
            if (flatIdx < 512) flatEmbeds[flatIdx++] = list.toDouble();
          }
        }
        flatten(rawEmbeds);
      } else if (rawEmbeds is Float32List) {
        flatEmbeds.setAll(0, rawEmbeds);
      }

      inputTensor.release();
      for (var out in outputs) {
        out?.release();
      }
      runOptions.release();

      return _normalize(flatEmbeds);
    } catch (e, stack) {
      print("getImageEmbedding error: $e\n$stack");
      return List<double>.filled(512, 0.0);
    }
  }

  double calculateSimilarity(List<double> embed1, List<double> embed2) {
    double dot = 0.0;
    for (int i = 0; i < embed1.length; i++) {
      dot += embed1[i] * embed2[i];
    }
    return dot;
  }

  List<double> _normalize(Float32List vector) {
    double sum = 0.0;
    for (var v in vector) {
      sum += v * v;
    }
    double mag = sqrt(sum);
    return vector.map((v) => v / mag).toList();
  }
}
