import 'dart:math' as math;
import '../models/ai_mask.dart';

abstract class AISegmentationService {
  Future<AIMask?> segment({
    required String imagePath,
    required String object,
    String? position,
  });

  Future<AIMask?> segmentByPoint({
    required String imagePath,
    required math.Point<int> point,
  });

  void dispose();
}
