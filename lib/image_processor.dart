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
  final Color color;

  Stroke(this.points, this.brushSize, this.isEraser, this.color);
}

class TapEdit {
  final math.Point<int> point;
  final Color color;
  final double tolerance;

  TapEdit(this.point, this.color, this.tolerance);
}

class MaskEdit {
  final AIMask mask;
  final Color color;

  MaskEdit(this.mask, this.color);
}

class ProcessImageParams {
  final Uint8List imageBytes;
  final List<TapEdit> tapEdits;
  final List<MaskEdit> maskEdits;
  final List<Stroke> manualStrokes;
  final bool showMaskOverlay;

  ProcessImageParams({
    required this.imageBytes,
    this.tapEdits = const [],
    this.maskEdits = const [],
    this.manualStrokes = const [],
    this.showMaskOverlay = false,
  });
}

Future<Uint8List?> processImage(ProcessImageParams params) async {
  return await Isolate.run(() {
    final image = img.decodeImage(params.imageBytes);
    if (image == null) return null;
    final result = _floodFillColorize(image, params);
    return img.encodePng(result);
  });
}

img.Image _floodFillColorize(img.Image image, ProcessImageParams params) {
  final tapEdits = params.tapEdits;
  final maskEdits = params.maskEdits;
  final manualStrokes = params.manualStrokes;
  final showMaskOverlay = params.showMaskOverlay;

  if (tapEdits.isEmpty && maskEdits.isEmpty && manualStrokes.isEmpty)
    return image.clone();

  final result = image.clone();
  final width = result.width;
  final height = result.height;

  void applyColorToMask(List<double> alphaMask, Color color) {
    final tR = color.red;
    final tG = color.green;
    final tB = color.blue;
    final targetLab = _rgbToLab(tR, tG, tB);
    final strength = 0.85; 

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final maskAlpha = alphaMask[y * width + x];
        if (maskAlpha <= 0.05) continue;
        
        final p = image.getPixel(x, y); 

        // SKY PROTECTION: Never allow the sky to change color
        if (y < height * 0.65) {
          final isBlueSky = p.b > 115 && p.b > p.r + 20 && p.b >= p.g - 5 && (p.r + p.g + p.b) > 280;
          final isOvercastSky = y < height * 0.45 && p.r > 220 && p.g > 220 && p.b > 220 &&
              (p.r - p.g).abs() < 12 && (p.g - p.b).abs() < 12 && (p.r - p.b).abs() < 12;
          if (isBlueSky || isOvercastSky) continue;
        }
        
        final effectiveAlpha = maskAlpha;
        
        if (showMaskOverlay) {
          result.setPixelRgb(x, y, 0, (255 * effectiveAlpha).toInt(), 0);
        } else {
          final currentP = result.getPixel(x, y); 
          
          final originalLab = _rgbToLab(p.r, p.g, p.b);
          final oL = originalLab[0];

          // Realistic architectural paint lighting modulation:
          // Accurately renders the target Nippon Paint lightness and color,
          // while preserving shadows, lighting gradients, and subtle wall texture.
          double lumModulation = (oL - 75.0) * 0.45;
          double newL = (targetLab[0] + lumModulation).clamp(8.0, 96.0);

          // Deep shadow protection: keep deep shadows (dark cracks, switch recesses) naturally dark
          if (oL < 20.0) newL = math.min(newL, oL);
          // Highlight protection: preserve specular sheen / light reflections
          if (oL > 95.0) newL = math.max(newL, oL);

          // Rich pigment coverage for target color
          double newA = targetLab[1] * strength + originalLab[1] * (1.0 - strength);
          double newB = targetLab[2] * strength + originalLab[2] * (1.0 - strength);

          final newRgb = _labToRgb(newL, newA, newB);

          final blendR = (currentP.r * (1 - effectiveAlpha) + newRgb[0] * effectiveAlpha).toInt().clamp(0, 255);
          final blendG = (currentP.g * (1 - effectiveAlpha) + newRgb[1] * effectiveAlpha).toInt().clamp(0, 255);
          final blendB = (currentP.b * (1 - effectiveAlpha) + newRgb[2] * effectiveAlpha).toInt().clamp(0, 255);

          result.setPixelRgb(x, y, blendR, blendG, blendB);
        }
      }
    }
  }

  // Process MaskEdits
  for (final maskEdit in maskEdits) {
    final alphaMask = List<double>.filled(width * height, 0.0);
    final aiMask = maskEdit.mask;
    for (int my = 0; my < aiMask.height; my++) {
      for (int mx = 0; mx < aiMask.width; mx++) {
        final confidence = aiMask.confidenceMask[my * aiMask.width + mx];
        if (confidence > 0.1) {
          int py = aiMask.startY + my;
          int px = aiMask.startX + mx;
          if (px >= 0 && px < width && py >= 0 && py < height) {
            alphaMask[py * width + px] = math.max(alphaMask[py * width + px], confidence);
          }
        }
      }
    }
    applyColorToMask(alphaMask, maskEdit.color);
  }

  // Process TapEdits with Edge-Aware Boundary Protection (Stops at ceiling seams/moldings)
  if (tapEdits.isNotEmpty) {
    final lum = Uint8List(width * height);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final p = image.getPixel(x, y);
        lum[y * width + x] = ((p.r * 299 + p.g * 587 + p.b * 114) ~/ 1000).clamp(0, 255);
      }
    }

    for (final tapEdit in tapEdits) {
      final alphaMask = List<double>.filled(width * height, 0.0);
      final visited = List<bool>.filled(width * height, false);
      final queue = <int>[];
      
      final tap = tapEdit.point;
      if (tap.x < 0 || tap.x >= width || tap.y < 0 || tap.y >= height) continue;
      
      final p = image.getPixel(tap.x, tap.y);
      final startColor = [p.r, p.g, p.b];
      queue.add(tap.y * width + tap.x);
      visited[tap.y * width + tap.x] = true;

      final tolSq = tapEdit.tolerance * tapEdit.tolerance * 255 * 255 * 3;
      final maxStepSq = math.min(tapEdit.tolerance * tapEdit.tolerance * 255 * 255 * 3 * 0.4, 550.0);

      while (queue.isNotEmpty) {
        final idx = queue.removeLast();
        final x = idx % width;
        final y = idx ~/ width;
        
        final cp = image.getPixel(x, y);

        final dr = cp.r - startColor[0];
        final dg = cp.g - startColor[1];
        final db = cp.b - startColor[2];
        final distFromStartSq = dr * dr + dg * dg + db * db;
        
        if (distFromStartSq <= tolSq) {
          final ratio = distFromStartSq / tolSq;
          alphaMask[y * width + x] = ratio > 0.85 ? ((1.0 - ratio) / 0.15).clamp(0.2, 1.0) : 1.0;

          final cLum = lum[idx];

          void tryAdd(int nx, int ny) {
            final nidx = ny * width + nx;
            if (!visited[nidx]) {
              final nLum = lum[nidx];
              final lumDiff = (cLum - nLum).abs();
              // Prevent jumping across ceiling crease, shadow line, or molding
              if (lumDiff > 20) return;

              // Local gradient edge magnitude
              int grad = 0;
              if (nx > 0 && nx < width - 1) {
                grad += (lum[ny * width + nx + 1] - lum[ny * width + nx - 1]).abs();
              }
              if (ny > 0 && ny < height - 1) {
                grad += (lum[(ny + 1) * width + nx] - lum[(ny - 1) * width + nx]).abs();
              }
              if (grad > 38) return; // Structural boundary

              final np = image.getPixel(nx, ny);

              // Sky protection: flood-fill should never cross into sky
              if (ny < height * 0.65) {
                final isBlueSky = np.b > 115 && np.b > np.r + 20 && np.b >= np.g - 5 && (np.r + np.g + np.b) > 280;
                final isOvercastSky = ny < height * 0.45 && np.r > 220 && np.g > 220 && np.b > 220 &&
                    (np.r - np.g).abs() < 12 && (np.g - np.b).abs() < 12 && (np.r - np.b).abs() < 12;
                if (isBlueSky || isOvercastSky) return;
              }

              final ndr = cp.r - np.r;
              final ndg = cp.g - np.g;
              final ndb = cp.b - np.b;
              final stepSq = ndr * ndr + ndg * ndg + ndb * ndb;

              if (stepSq <= maxStepSq) {
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
      applyColorToMask(alphaMask, tapEdit.color);
    }
  }

  // Process ManualStrokes
  for (final stroke in manualStrokes) {
    final alphaMask = List<double>.filled(width * height, 0.0);
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
    if (!stroke.isEraser) {
      applyColorToMask(alphaMask, stroke.color);
    } else {
      // Eraser logic would mean restoring the original pixel.
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          if (alphaMask[y * width + x] > 0.05) {
            final p = image.getPixel(x, y);
            result.setPixelRgb(x, y, p.r, p.g, p.b);
          }
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
