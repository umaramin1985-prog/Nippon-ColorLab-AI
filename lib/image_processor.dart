import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart' show Color;

class AIMask {
  final List<double> confidenceMask;
  final int startX;
  final int startY;
  final int width;
  final int height;

  AIMask(
    this.confidenceMask,
    this.startX,
    this.startY,
    this.width,
    this.height,
  );
}

class Stroke {
  final List<math.Point<int>> points;
  final double brushSize;
  final bool isEraser;

  Stroke(this.points, this.brushSize, this.isEraser);
}

class ProcessImageParams {
  final img.Image image;
  final List<math.Point<int>> taps;
  final List<AIMask> aiMasks;
  final List<Stroke> manualStrokes;
  final Color targetColor;
  final double tolerance;
  final bool showMaskOverlay;
  final math.Rectangle<int>? boundingBox;

  ProcessImageParams({
    required this.image,
    required this.taps,
    this.aiMasks = const [],
    this.manualStrokes = const [],
    required this.targetColor,
    required this.tolerance,
    this.showMaskOverlay = false,
    this.boundingBox,
  });
}

Future<img.Image> processImage(ProcessImageParams params) async {
  if (kIsWeb) {
    return _floodFillColorize(params);
  }
  return await Isolate.run(() => _floodFillColorize(params));
}

img.Image _floodFillColorize(ProcessImageParams params) {
  final image = params.image;
  final taps = params.taps;
  final targetColor = params.targetColor;
  final tolerance = params.tolerance;
  final aiMasks = params.aiMasks;
  final manualStrokes = params.manualStrokes;
  final showMaskOverlay = params.showMaskOverlay;
  final boundingBox = params.boundingBox;

  if (taps.isEmpty && aiMasks.isEmpty && manualStrokes.isEmpty) {
    return image.clone();
  }

  final result = image.clone();
  final width = result.width;
  final height = result.height;

  final mask = List<bool>.filled(width * height, false);

  // 1. Apply AI Masks (ML Kit Segmentation)
  for (var aiMask in aiMasks) {
    for (int my = 0; my < aiMask.height; my++) {
      for (int mx = 0; mx < aiMask.width; mx++) {
        final confidence = aiMask.confidenceMask[my * aiMask.width + mx];
        if (confidence > 0.5) {
          int py = aiMask.startY + my;
          int px = aiMask.startX + mx;
          if (px >= 0 && px < width && py >= 0 && py < height) {
            mask[py * width + px] = true;
          }
        }
      }
    }
  }

  // 2. High-Precision Edge-Aware Flood Fill for Taps
  if (taps.isNotEmpty) {
    final visited = List<bool>.filled(width * height, false);
    final queue = <int>[];
    final tapColors = <math.Point<int>, List<num>>{};

    for (final tap in taps) {
      if (tap.x < 0 || tap.x >= width || tap.y < 0 || tap.y >= height) continue;
      final p = image.getPixel(tap.x, tap.y);
      tapColors[tap] = [p.r, p.g, p.b];
      queue.add(tap.y * width + tap.x);
      visited[tap.y * width + tap.x] = true;
    }

    final tolSq = tolerance * tolerance * 255 * 255 * 3;
    final maxGrad = 35.0; // Edge barrier to prevent object bleeding while allowing smooth wall fill

    while (queue.isNotEmpty) {
      final idx = queue.removeLast();
      final x = idx % width;
      final y = idx ~/ width;
      final p = image.getPixel(x, y);

      bool withinTolerance = false;
      for (final startColor in tapColors.values) {
        final dr = p.r - startColor[0];
        final dg = p.g - startColor[1];
        final db = p.b - startColor[2];
        if ((dr * dr + dg * dg + db * db) <= tolSq) {
          withinTolerance = true;
          break;
        }
      }

      if (withinTolerance) {
        mask[y * width + x] = true;

        void tryAddNeighbor(int nx, int ny) {
          final nidx = ny * width + nx;
          if (!visited[nidx]) {
            final np = image.getPixel(nx, ny);
            final dr = (p.r - np.r).abs();
            final dg = (p.g - np.g).abs();
            final db = (p.b - np.b).abs();
            final grad = (dr + dg + db) / 3.0;

            if (grad < maxGrad) {
              queue.add(nidx);
              visited[nidx] = true;
            }
          }
        }

        if (x > 0) tryAddNeighbor(x - 1, y);
        if (x < width - 1) tryAddNeighbor(x + 1, y);
        if (y > 0) tryAddNeighbor(x, y - 1);
        if (y < height - 1) tryAddNeighbor(x, y + 1);
      }
    }
  }

  // 3. Apply Manual Strokes (Brush / Eraser)
  for (final stroke in manualStrokes) {
    final r = stroke.brushSize.toInt();
    final rSq = r * r;
    for (final pt in stroke.points) {
      for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
          if (dx * dx + dy * dy <= rSq) {
            final px = pt.x + dx;
            final py = pt.y + dy;
            if (px >= 0 && px < width && py >= 0 && py < height) {
              mask[py * width + px] = !stroke.isEraser;
            }
          }
        }
      }
    }
  }

  // 4. Photorealistic Multiplicative & Soft-Light Luminance Blending
  final tR = targetColor.red / 255.0;
  final tG = targetColor.green / 255.0;
  final tB = targetColor.blue / 255.0;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final idx = y * width + x;
      if (mask[idx]) {
        if (boundingBox != null && !boundingBox.containsPoint(math.Point(x, y))) {
          continue;
        }

        if (showMaskOverlay) {
          result.setPixelRgb(x, y, 0, 255, 0);
        } else {
          final p = image.getPixel(x, y);
          final origR = p.r / 255.0;
          final origG = p.g / 255.0;
          final origB = p.b / 255.0;

          // Standard ITU-R BT.709 Perceptual Luminance
          final lum = (0.2126 * origR + 0.7152 * origG + 0.0722 * origB);

          // Soft-Knee Shadow & Highlight Curve
          final shadowFactor = math.pow(lum, 0.85).toDouble();

          final newR = (tR * shadowFactor * 1.15 * 255.0).clamp(0.0, 255.0);
          final newG = (tG * shadowFactor * 1.15 * 255.0).clamp(0.0, 255.0);
          final newB = (tB * shadowFactor * 1.15 * 255.0).clamp(0.0, 255.0);

          result.setPixelRgb(x, y, newR.round(), newG.round(), newB.round());
        }
      }
    }
  }

  return result;
}
