import 'dart:math' as math;
import '../models/ai_mask.dart';

typedef ProgressCallback = void Function(double progress, String message);

abstract class AISegmentationService {
  Future<AIMask?> segment({
    required String imagePath,
    required String object,
    String? position,
    ProgressCallback? onProgress,
  });

  Future<AIMask?> segmentByPoint({
    required String imagePath,
    required math.Point<int> point,
    ProgressCallback? onProgress,
  });

  void dispose();
}
