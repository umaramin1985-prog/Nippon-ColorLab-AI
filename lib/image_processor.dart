import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
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

  ProcessImageParams({
    required this.image,
    required this.taps,
    this.aiMasks = const [],
    this.manualStrokes = const [],
    required this.targetColor,
    required this.tolerance,
    this.showMaskOverlay = false,
  });
}

Future<img.Image> processImage(ProcessImageParams params) async {
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

  if (taps.isEmpty && aiMasks.isEmpty && manualStrokes.isEmpty)
    return image.clone();

  final result = image.clone();
  final width = result.width;
  final height = result.height;

  // 1. Create a unified boolean mask
  final mask = List<bool>.filled(width * height, false);

  // 2. Apply AI Masks to the mask array
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

  // 3. Apply Flood Fill taps to the mask array
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
    final edgeTolSq = (tolerance * 1.5) * (tolerance * 1.5) * 255 * 255 * 3;

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

        void tryAdd(int nx, int ny) {
          final nidx = ny * width + nx;
          if (!visited[nidx]) {
            final np = image.getPixel(nx, ny);
            final dr = p.r - np.r;
            final dg = p.g - np.g;
            final db = p.b - np.b;
            if ((dr * dr + dg * dg + db * db) <= edgeTolSq) {
              queue.add(nidx);
              visited[nidx] = true;
            }
          }
        }

        if (x > 0) tryAdd(x - 1, y);
        if (x < width - 1) tryAdd(x + 1, y);
        if (y > 0) tryAdd(x, y - 1);
        if (y < height - 1) tryAdd(x, y + 1);
      }
    }
  }

  // 4. Apply Manual Strokes (Brush/Eraser)
  // Simple rasterization of circles at each stroke point
  for (final stroke in manualStrokes) {
    final r = stroke.brushSize.toInt();
    final rSq = r * r;
    for (final pt in stroke.points) {
      // Draw a circle of radius r
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

  // 5. Colorize the final mask
  final tR = targetColor.red;
  final tG = targetColor.green;
  final tB = targetColor.blue;
  final targetHsl = _rgbToHsl(tR, tG, tB);

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      if (mask[y * width + x]) {
        if (showMaskOverlay) {
          // Highlight in bright neon green for mask editing mode
          result.setPixelRgb(x, y, 0, 255, 0);
        } else {
          final p = image.getPixel(x, y);
          final originalHsl = _rgbToHsl(p.r, p.g, p.b);

          double h = targetHsl[0];
          double s = targetHsl[1];
          double l = originalHsl[2];

          final newRgb = _hslToRgb(h, s, l);

          final blendR = ((newRgb[0] * 0.7) + ((p.r * tR) / 255 * 0.3)).toInt();
          final blendG = ((newRgb[1] * 0.7) + ((p.g * tG) / 255 * 0.3)).toInt();
          final blendB = ((newRgb[2] * 0.7) + ((p.b * tB) / 255 * 0.3)).toInt();

          result.setPixelRgb(x, y, blendR, blendG, blendB);
        }
      }
    }
  }

  return result;
}

List<double> _rgbToHsl(num r, num g, num b) {
  r /= 255;
  g /= 255;
  b /= 255;
  final max = [r, g, b].reduce((a, b) => a > b ? a : b);
  final min = [r, g, b].reduce((a, b) => a < b ? a : b);
  double h = 0, s = 0, l = (max + min) / 2.0;
  if (max != min) {
    final d = max - min;
    s = l > 0.5 ? d / (2.0 - max - min) : d / (max + min);
    if (max == r) {
      h = (g - b) / d + (g < b ? 6.0 : 0.0);
    } else if (max == g) {
      h = (b - r) / d + 2.0;
    } else {
      h = (r - g) / d + 4.0;
    }
    h /= 6.0;
  }
  return [h, s, l];
}

List<int> _hslToRgb(double h, double s, double l) {
  double r, g, b;
  if (s == 0) {
    r = g = b = l;
  } else {
    double hue2rgb(double p, double q, double t) {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }

    double q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    double p = 2 * l - q;
    r = hue2rgb(p, q, h + 1 / 3);
    g = hue2rgb(p, q, h);
    b = hue2rgb(p, q, h - 1 / 3);
  }
  return [(r * 255).round(), (g * 255).round(), (b * 255).round()];
}
