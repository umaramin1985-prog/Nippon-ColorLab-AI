import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:onnxruntime/onnxruntime.dart';

void main() {
  test('Test ONNX Encoder', () async {
    OrtEnv.instance.init();
    final encoderBytes = await File('assets/models/mobilesam/mobile_sam_image_encoder.onnx').readAsBytes();
    final encoderOptions = OrtSessionOptions();
    final encoderSession = OrtSession.fromBuffer(encoderBytes, encoderOptions);
    
    final floatList = Float32List(1024 * 1024 * 3);
    final encoderInputTensor = OrtValueTensor.createTensorWithDataList(floatList, [1024, 1024, 3]);
    final encoderRunOptions = OrtRunOptions();
    final encoderInputs = {encoderSession.inputNames[0]: encoderInputTensor};
    try {
      final encoderOutputs = encoderSession.run(encoderRunOptions, encoderInputs);
      final rawEmbeds = (encoderOutputs[0]?.value as OrtValueTensor).value;
      print("Encoder success. rawEmbeds type: ${rawEmbeds.runtimeType}");
      
      final decBytes = await File('assets/models/mobilesam/sam_mask_decoder_single.onnx').readAsBytes();
      final decSession = OrtSession.fromBuffer(decBytes, OrtSessionOptions());
      
      final embedTensor = OrtValueTensor.createTensorWithDataList(Float32List(1 * 256 * 64 * 64), [1, 256, 64, 64]);
      final coordsTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([100.0, 100.0]), [1, 1, 2]);
      final labelsTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([1.0]), [1, 1]);
      final maskInputTensor = OrtValueTensor.createTensorWithDataList(Float32List(1 * 1 * 256 * 256), [1, 1, 256, 256]);
      final hasMaskTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([0.0]), [1]);
      final sizeTensor = OrtValueTensor.createTensorWithDataList(Float32List.fromList([200.0, 200.0]), [2]);
      
      final decOutputs = decSession.run(OrtRunOptions(), {
        'image_embeddings': embedTensor,
        'point_coords': coordsTensor,
        'point_labels': labelsTensor,
        'mask_input': maskInputTensor,
        'has_mask_input': hasMaskTensor,
        'orig_im_size': sizeTensor,
      });
      final maskVal = (decOutputs[0]?.value as OrtValueTensor).value;
      print("Decoder success. maskVal type: ${maskVal.runtimeType}");
      
      if (maskVal is List) {
        double maxVal = -9999.0;
        void findMax(dynamic list) {
          if (list is List) {
            for (var e in list) findMax(e);
          } else if (list is num) {
            if (list.toDouble() > maxVal) maxVal = list.toDouble();
          }
        }
        findMax(maskVal);
        print("Max mask value: $maxVal");
      }
    } catch (e) {
      print("ERROR: $e");
    }
  });
}
