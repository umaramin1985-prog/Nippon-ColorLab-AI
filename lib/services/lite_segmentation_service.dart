import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import '../models/ai_mask.dart';
import 'ai_segmentation_service.dart';

class LiteSegmentationService implements AISegmentationService {
  final SubjectSegmenter _segmenter;
  SubjectSegmentationResult? _lastResult;
  String? _lastImagePath;

  LiteSegmentationService()
      : _segmenter = SubjectSegmenter(
          options: SubjectSegmenterOptions(
            enableForegroundConfidenceMask: false,
            enableForegroundBitmap: false,
            enableMultipleSubjects: SubjectResultOptions(
              enableConfidenceMask: true,
              enableSubjectBitmap: false,
            ),
          ),
        );

  Future<SubjectSegmentationResult?> _getResult(String imagePath) async {
    if (_lastImagePath == imagePath && _lastResult != null) {
      return _lastResult;
    }
    final inputImage = InputImage.fromFilePath(imagePath);
    final result = await _segmenter.processImage(inputImage);
    _lastImagePath = imagePath;
    _lastResult = result;
    return result;
  }

  @override
  Future<AIMask?> segment({
    required String imagePath,
    required String object,
    String? position,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      debugPrint("ML Kit not supported on this platform.");
      return null;
    }

    try {
      final result = await _getResult(imagePath);
      if (result == null || result.subjects.isEmpty) {
        return null;
      }

      var selectedSubject = result.subjects[0];
      final pos = position?.toLowerCase() ?? '';
      final obj = object.toLowerCase();

      if (pos.contains('top') || obj.contains('ceiling') || obj.contains('roof')) {
        int minStartY = selectedSubject.startY;
        for (var s in result.subjects) {
          if (s.startY < minStartY) {
            minStartY = s.startY;
            selectedSubject = s;
          }
        }
      } else if (pos.contains('bottom') || obj.contains('floor') || obj.contains('ground') || obj.contains('carpet')) {
        int maxBottomY = selectedSubject.startY + selectedSubject.height;
        for (var s in result.subjects) {
          int bottomY = s.startY + s.height;
          if (bottomY > maxBottomY) {
            maxBottomY = bottomY;
            selectedSubject = s;
          }
        }
      } else if (pos.contains('left')) {
        int minStartX = selectedSubject.startX;
        for (var s in result.subjects) {
          if (s.startX < minStartX) {
            minStartX = s.startX;
            selectedSubject = s;
          }
        }
      } else if (pos.contains('right')) {
        int maxRightX = selectedSubject.startX + selectedSubject.width;
        for (var s in result.subjects) {
          int rightX = s.startX + s.width;
          if (rightX > maxRightX) {
            maxRightX = rightX;
            selectedSubject = s;
          }
        }
      } else {
        var maxArea = selectedSubject.width * selectedSubject.height;
        for (var s in result.subjects) {
          var area = s.width * s.height;
          if (area > maxArea) {
            maxArea = area;
            selectedSubject = s;
          }
        }
      }

      if (selectedSubject.confidenceMask == null) return null;

      return AIMask(
        selectedSubject.confidenceMask!,
        selectedSubject.startX,
        selectedSubject.startY,
        selectedSubject.width,
        selectedSubject.height,
      );
    } catch (e) {
      debugPrint("ML Kit failed: $e");
      return null;
    }
  }

  @override
  Future<AIMask?> segmentByPoint({
    required String imagePath,
    required math.Point<int> point,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return null;
    }

    try {
      final result = await _getResult(imagePath);
      if (result == null || result.subjects.isEmpty) {
        return null;
      }

      for (var subject in result.subjects) {
        if (point.x >= subject.startX &&
            point.x < subject.startX + subject.width &&
            point.y >= subject.startY &&
            point.y < subject.startY + subject.height) {
          int localX = point.x - subject.startX;
          int localY = point.y - subject.startY;
          int idx = localY * subject.width + localX;

          if (subject.confidenceMask != null &&
              subject.confidenceMask![idx] > 0.5) {
            return AIMask(
              subject.confidenceMask!,
              subject.startX,
              subject.startY,
              subject.width,
              subject.height,
            );
          }
        }
      }
    } catch (e) {
      debugPrint("ML Kit point segmentation failed: $e");
    }
    return null;
  }

  @override
  void dispose() {
    _segmenter.close();
  }
}
