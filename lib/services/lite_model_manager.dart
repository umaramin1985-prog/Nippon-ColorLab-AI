import 'dart:typed_data';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:flutter/services.dart' show rootBundle;

class LiteModelManager {
  OrtSession? samEncoder;
  OrtSession? samDecoder;
  OrtSession? clipVision;
  OrtSession? clipText;
  
  bool isInitialized = false;

  // Singleton pattern
  static final LiteModelManager _instance = LiteModelManager._internal();
  factory LiteModelManager() => _instance;
  LiteModelManager._internal();

  Future<void> initialize() async {
    if (isInitialized) return;

    try {
      OrtEnv.instance.init();

      final encoderOptions = OrtSessionOptions();
      final encoderBytes = await rootBundle.load('assets/models/mobilesam/mobile_sam_image_encoder.onnx');
      samEncoder = OrtSession.fromBuffer(encoderBytes.buffer.asUint8List(), encoderOptions);

      final decoderOptions = OrtSessionOptions();
      final decoderBytes = await rootBundle.load('assets/models/mobilesam/sam_mask_decoder_single.onnx');
      samDecoder = OrtSession.fromBuffer(decoderBytes.buffer.asUint8List(), decoderOptions);

      final visionOptions = OrtSessionOptions();
      final visionBytes = await rootBundle.load('assets/models/mobileclip/onnx/vision_model.onnx');
      clipVision = OrtSession.fromBuffer(visionBytes.buffer.asUint8List(), visionOptions);

      final textOptions = OrtSessionOptions();
      final textBytes = await rootBundle.load('assets/models/mobileclip/onnx/text_model.onnx');
      clipText = OrtSession.fromBuffer(textBytes.buffer.asUint8List(), textOptions);

      isInitialized = true;
      print("LiteModelManager: All ONNX models successfully loaded offline.");
    } catch (e) {
      print("LiteModelManager Initialization Error: $e");
    }
  }

  void dispose() {
    samEncoder?.release();
    samDecoder?.release();
    clipVision?.release();
    clipText?.release();
    OrtEnv.instance.release();
    isInitialized = false;
  }
}
