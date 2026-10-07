import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart' show Color;
import 'models/ai_mask.dart';

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

  // 1. Create a unified alpha mask
  final alphaMask = List<double>.filled(width * height, 0.0);

  // 2. Apply AI Masks to the mask array
  for (var aiMask in aiMasks) {
    for (int my = 0; my < aiMask.height; my++) {
      for (int mx = 0; mx < aiMask.width; mx++) {
        final confidence = aiMask.confidenceMask[my * aiMask.width + mx];
        if (confidence > 0.1) {
          int py = aiMask.startY + my;
          int px = aiMask.startX + mx;
          if (px >= 0 && px < width && py >= 0 && py < height) {
            // Take the max confidence if masks overlap
            alphaMask[py * width + px] = math.max(alphaMask[py * width + px], confidence);
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
        alphaMask[y * width + x] = 1.0;

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
              alphaMask[py * width + px] = stroke.isEraser ? 0.0 : 1.0;
            }
          }
        }
      }
    }
  }

  // 5. Colorize the final mask using LAB color space
  final tR = targetColor.red;
  final tG = targetColor.green;
  final tB = targetColor.blue;
  final targetLab = _rgbToLab(tR, tG, tB);
  
  final strength = 0.85; // Recolor strength parameter (0.7 - 0.9 recommended)

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final maskAlpha = alphaMask[y * width + x];
      
      if (maskAlpha > 0.05) {
        if (showMaskOverlay) {
          result.setPixelRgb(x, y, 0, (255 * maskAlpha).toInt(), 0);
        } else {
          final p = image.getPixel(x, y);
          final originalLab = _rgbToLab(p.r, p.g, p.b);

          // Preserve Original Luminance (L), blend A and B channels
          double newL = originalLab[0];
          
          // Reduce recolor strength in extremely dark or bright regions to preserve highlights/shadows
          double localStrength = strength;
          if (newL < 15.0) localStrength *= (newL / 15.0); // fade out in dark shadows
          if (newL > 90.0) localStrength *= ((100.0 - newL) / 10.0); // fade out in pure highlights

          double newA = originalLab[1] * (1 - localStrength) + targetLab[1] * localStrength;
          double newB = originalLab[2] * (1 - localStrength) + targetLab[2] * localStrength;

          final newRgb = _labToRgb(newL, newA, newB);

          // Alpha Mask Blending
          final blendR = (p.r * (1 - maskAlpha) + newRgb[0] * maskAlpha).toInt().clamp(0, 255);
          final blendG = (p.g * (1 - maskAlpha) + newRgb[1] * maskAlpha).toInt().clamp(0, 255);
          final blendB = (p.b * (1 - maskAlpha) + newRgb[2] * maskAlpha).toInt().clamp(0, 255);

          result.setPixelRgb(x, y, blendR, blendG, blendB);
        }
      }
    }
  }

  return result;
}

// LAB Color Space Conversions
List<double> _rgbToLab(num r, num g, num b) {
  double varR = r / 255.0;
  double varG = g / 255.0;
  double varB = b / 255.0;

  varR = varR > 0.04045 ? math.pow((varR + 0.055) / 1.055, 2.4).toDouble() : varR / 12.92;
  varG = varG > 0.04045 ? math.pow((varG + 0.055) / 1.055, 2.4).toDouble() : varG / 12.92;
  varB = varB > 0.04045 ? math.pow((varB + 0.055) / 1.055, 2.4).toDouble() : varB / 12.92;

  varR = varR * 100;
  varG = varG * 100;
  varB = varB * 100;

  double x = varR * 0.4124 + varG * 0.3576 + varB * 0.1805;
  double y = varR * 0.2126 + varG * 0.7152 + varB * 0.0722;
  double z = varR * 0.0193 + varG * 0.1192 + varB * 0.9505;

  double varX = x / 95.047;
  double varY = y / 100.000;
  double varZ = z / 108.883;

  varX = varX > 0.008856 ? math.pow(varX, 1.0 / 3.0).toDouble() : (7.787 * varX) + (16.0 / 116.0);
  varY = varY > 0.008856 ? math.pow(varY, 1.0 / 3.0).toDouble() : (7.787 * varY) + (16.0 / 116.0);
  varZ = varZ > 0.008856 ? math.pow(varZ, 1.0 / 3.0).toDouble() : (7.787 * varZ) + (16.0 / 116.0);

  double l = (116.0 * varY) - 16.0;
  double a = 500.0 * (varX - varY);
  double bVal = 200.0 * (varY - varZ);

  return [l, a, bVal];
}

List<int> _labToRgb(double l, double a, double b) {
  double varY = (l + 16.0) / 116.0;
  double varX = a / 500.0 + varY;
  double varZ = varY - b / 200.0;

  varY = math.pow(varY, 3) > 0.008856 ? math.pow(varY, 3).toDouble() : (varY - 16.0 / 116.0) / 7.787;
  varX = math.pow(varX, 3) > 0.008856 ? math.pow(varX, 3).toDouble() : (varX - 16.0 / 116.0) / 7.787;
  varZ = math.pow(varZ, 3) > 0.008856 ? math.pow(varZ, 3).toDouble() : (varZ - 16.0 / 116.0) / 7.787;

  double x = varX * 95.047;
  double y = varY * 100.000;
  double z = varZ * 108.883;

  varX = x / 100.0;
  varY = y / 100.0;
  varZ = z / 100.0;

  double varR = varX * 3.2406 + varY * -1.5372 + varZ * -0.4986;
  double varG = varX * -0.9689 + varY * 1.8758 + varZ * 0.0415;
  double varB = varX * 0.0557 + varY * -0.2040 + varZ * 1.0570;

  varR = varR > 0.0031308 ? 1.055 * math.pow(varR, 1 / 2.4) - 0.055 : 12.92 * varR;
  varG = varG > 0.0031308 ? 1.055 * math.pow(varG, 1 / 2.4) - 0.055 : 12.92 * varG;
  varB = varB > 0.0031308 ? 1.055 * math.pow(varB, 1 / 2.4) - 0.055 : 12.92 * varB;

  return [
    (varR * 255.0).round().clamp(0, 255),
    (varG * 255.0).round().clamp(0, 255),
    (varB * 255.0).round().clamp(0, 255)
  ];
}
