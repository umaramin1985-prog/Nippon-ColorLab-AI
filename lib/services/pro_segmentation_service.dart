import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import '../models/ai_mask.dart';
import 'ai_segmentation_service.dart';

class ProSegmentationService implements AISegmentationService {
  final String backendUrl;

  ProSegmentationService({this.backendUrl = 'http://192.168.18.195:8000/api/v1/segment'});

  @override
  Future<AIMask?> segment({
    required String imagePath,
    required String object,
    String? position,
  }) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse(backendUrl));
      request.fields['object'] = object;
      if (position != null) {
        request.fields['position'] = position;
      }
      
      request.files.add(await http.MultipartFile.fromPath('image', imagePath));

      var response = await request.send();
      if (response.statusCode != 200) {
        throw Exception('Backend returned status code ${response.statusCode}');
      }

      var responseData = await response.stream.bytesToString();
      var json = jsonDecode(responseData);

      if (json['success'] != true) {
        throw Exception(json['error'] ?? 'Unknown error from backend');
      }

      String maskBase64 = json['mask'];
      Map<String, dynamic> bbox = json['bbox'];
      
      int startX = bbox['x1'];
      int startY = bbox['y1'];
      int width = bbox['x2'] - bbox['x1'];
      int height = bbox['y2'] - bbox['y1'];

      var maskBytes = base64Decode(maskBase64);
      var maskImg = img.decodePng(maskBytes);
      
      if (maskImg == null) {
        throw Exception('Failed to decode mask image');
      }
      
      List<double> confidenceMask = List<double>.filled(width * height, 0.0);
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          var p = maskImg.getPixel(x, y);
          confidenceMask[y * width + x] = p.r / 255.0;
        }
      }

      return AIMask(confidenceMask, startX, startY, width, height);
    } catch (e) {
      print('Pro segmentation error: $e');
      return null;
    }
  }

  @override
  Future<AIMask?> segmentByPoint({
    required String imagePath,
    required math.Point<int> point,
  }) async {
    // For tap, we can just send the point coordinates if backend supports it,
    // or we can fall back to returning null so it defaults to tap flood-fill.
    // The requirement focuses on NLP prompt for Pro mode.
    // Let's assume point based SAM is out of scope unless we add a point parameter
    // in the backend API.
    return null;
  }

  @override
  void dispose() {
    // Nothing to dispose
  }
}
