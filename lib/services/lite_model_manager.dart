import 'onnxruntime_stub.dart' if (dart.library.io) 'package:onnxruntime/onnxruntime.dart';
import 'package:flutter/services.dart' show rootBundle;

class LiteModelManager {
  OrtSession? samEncoder;
  OrtSession? samDecoder;
  OrtSession? clipVision;
  OrtSession? clipText;
  
  bool isSamInitialized = false;
  bool isClipInitialized = false;
  bool _isEnvInitialized = false;

  // Singleton pattern
  static final LiteModelManager _instance = LiteModelManager._internal();
  factory LiteModelManager() => _instance;
  LiteModelManager._internal();

  void _ensureEnv() {
    if (!_isEnvInitialized) {
      try {
        OrtEnv.instance.init();
        _isEnvInitialized = true;
      } catch (e) {
        print("LiteModelManager OrtEnv init: $e");
      }
    }
  }

  Future<void> initialize() async {
    await initSam();
  }

  Future<bool> initSam() async {
    if (isSamInitialized && samEncoder != null && samDecoder != null) return true;

    try {
      _ensureEnv();

      if (samEncoder == null) {
        final encoderOptions = OrtSessionOptions();
        final encoderBytes = await rootBundle.load('assets/models/mobilesam/mobile_sam_image_encoder.onnx');
        samEncoder = OrtSession.fromBuffer(encoderBytes.buffer.asUint8List(), encoderOptions);
      }

      if (samDecoder == null) {
        final decoderOptions = OrtSessionOptions();
        final decoderBytes = await rootBundle.load('assets/models/mobilesam/sam_mask_decoder_single.onnx');
        samDecoder = OrtSession.fromBuffer(decoderBytes.buffer.asUint8List(), decoderOptions);
      }

      isSamInitialized = samEncoder != null && samDecoder != null;
      print("LiteModelManager: MobileSAM models loaded successfully.");
      return isSamInitialized;
    } catch (e) {
      print("LiteModelManager SAM Initialization Error: $e");
      return false;
    }
  }

  Future<bool> initClip() async {
    if (isClipInitialized && clipVision != null && clipText != null) return true;

    try {
      _ensureEnv();

      if (clipVision == null) {
        final visionOptions = OrtSessionOptions();
        final visionBytes = await rootBundle.load('assets/models/mobileclip/onnx/vision_model.onnx');
        clipVision = OrtSession.fromBuffer(visionBytes.buffer.asUint8List(), visionOptions);
      }

      if (clipText == null) {
        final textOptions = OrtSessionOptions();
        final textBytes = await rootBundle.load('assets/models/mobileclip/onnx/text_model.onnx');
        clipText = OrtSession.fromBuffer(textBytes.buffer.asUint8List(), textOptions);
      }

      isClipInitialized = clipVision != null && clipText != null;
      print("LiteModelManager: MobileCLIP models loaded successfully.");
      return isClipInitialized;
    } catch (e) {
      print("LiteModelManager CLIP Initialization Error: $e");
      return false;
    }
  }

  void dispose() {
    try {
      samEncoder?.release();
      samDecoder?.release();
      clipVision?.release();
      clipText?.release();
      if (_isEnvInitialized) {
        OrtEnv.instance.release();
        _isEnvInitialized = false;
      }
    } catch (e) {
      print("LiteModelManager dispose error: $e");
    }
    samEncoder = null;
    samDecoder = null;
    clipVision = null;
    clipText = null;
    isSamInitialized = false;
    isClipInitialized = false;
  }
}
