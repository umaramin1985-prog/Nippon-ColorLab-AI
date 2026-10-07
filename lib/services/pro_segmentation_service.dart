import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';
import '../models/ai_mask.dart';
import 'ai_segmentation_service.dart';

class ProSegmentationService implements AISegmentationService {
  // Replace with your actual Replicate API Token
  static const String _apiToken = 'YOUR_REPLICATE_API_TOKEN';
  
  // Replace with the actual Replicate model ID you want to use
  static const String _modelEndpoint = 'https://api.replicate.com/v1/models/black-forest-labs/flux-kontext-dev/predictions';

  Future<bool> isAvailable() async {
    return _apiToken != 'YOUR_REPLICATE_API_TOKEN' && _apiToken.isNotEmpty;
  }

  // Returns the directly edited image bytes from FLUX
  Future<Uint8List?> editImage({
    required String imagePath,
    required String prompt,
  }) async {
    try {
      final imageFile = File(imagePath);
      final imageBytes = await imageFile.readAsBytes();
      final mimeType = lookupMimeType(imagePath) ?? 'image/jpeg';
      final base64Image = base64Encode(imageBytes);
      final dataUri = 'data:$mimeType;base64,$base64Image';

      // 1. Start the prediction on Replicate
      var response = await http.post(
        Uri.parse(_modelEndpoint),
        headers: {
          'Authorization': 'Bearer $_apiToken',
          'Content-Type': 'application/json',
          'Prefer': 'wait'
        },
        body: jsonEncode({
          'input': {
            'prompt': prompt,
            'go_fast': true,
            'guidance': 2.5,
            'input_image': dataUri,
            'aspect_ratio': 'match_input_image',
            'output_format': 'jpg',
            'output_quality': 80,
            'num_inference_steps': 30
          }
        }),
      );

      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception('Replicate API error: ${response.statusCode} - ${response.body}');
      }

      var jsonResponse = jsonDecode(response.body);
      String predictionUrl = jsonResponse['urls']['get'];

      // 2. Poll the prediction until it's complete
      String? outputUrl;
      while (true) {
        var statusResponse = await http.get(
          Uri.parse(predictionUrl),
          headers: {'Authorization': 'Bearer $_apiToken'},
        );

        if (statusResponse.statusCode != 200) {
          throw Exception('Failed to poll Replicate API');
        }

        var statusJson = jsonDecode(statusResponse.body);
        String status = statusJson['status'];

        if (status == 'succeeded') {
          var output = statusJson['output'];
          if (output is List && output.isNotEmpty) {
            outputUrl = output[0];
          } else if (output is String) {
            outputUrl = output;
          }
          break;
        } else if (status == 'failed' || status == 'canceled') {
          throw Exception('Prediction $status: ${statusJson['error']}');
        }

        // Wait a bit before polling again
        await Future.delayed(const Duration(seconds: 2));
      }

      if (outputUrl == null) {
        throw Exception('No output URL returned from Replicate');
      }

      // 3. Download and return the edited image
      var maskResponse = await http.get(Uri.parse(outputUrl));
      if (maskResponse.statusCode != 200) {
        throw Exception('Failed to download edited image');
      }

      return maskResponse.bodyBytes;

    } catch (e) {
      print('Replicate FLUX Kontext editing error: $e');
      return null;
    }
  }

  @override
  Future<AIMask?> segment({
    required String imagePath,
    required String object,
    String? position,
  }) async {
    // This is no longer used for FLUX, returning null
    return null;
  }


  @override
  Future<AIMask?> segmentByPoint({
    required String imagePath,
    required math.Point<int> point,
  }) async {
    return null;
  }

  @override
  void dispose() {}
}
