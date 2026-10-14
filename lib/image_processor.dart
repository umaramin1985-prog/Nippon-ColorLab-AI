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

final Float32List _sRgbToLinearTable = Float32List.fromList(List.generate(256, (i) {
  final double v = i / 255.0;
  return ((v > 0.04045 ? math.pow((v + 0.055) / 1.055, 2.4) : v / 12.92) * 100.0).toDouble();
}));

Future<Uint8List?> processImage(ProcessImageParams params) async {
  return await Isolate.run(() {
    final image = img.decodeImage(params.imageBytes);
    if (image == null) return null;
    final result = _floodFillColorize(image, params);
    return Uint8List.fromList(img.encodeJpg(result, quality: 92));
  });
}

img.Image _floodFillColorize(img.Image image, ProcessImageParams params) {
  final tapEdits = params.tapEdits;
  final maskEdits = params.maskEdits;
  final manualStrokes = params.manualStrokes;
  final showMaskOverlay = params.showMaskOverlay;

  if (tapEdits.isEmpty && maskEdits.isEmpty && manualStrokes.isEmpty) {
    return image.clone();
  }

  final result = image.clone();
  final width = result.width;
  final height = result.height;

  void applyColorToMask(List<double> alphaMask, Color color) {
    final tR = color.red;
    final tG = color.green;
    final tB = color.blue;
    final targetLab = _rgbToLab(tR, tG, tB);
    const double strength = 0.85;

    for (int y = 0; y < height; y++) {
      final int rowOffset = y * width;
      for (int x = 0; x < width; x++) {
        final double maskAlpha = alphaMask[rowOffset + x];
        if (maskAlpha <= 0.05) continue;

        final p = image.getPixel(x, y);

        if (showMaskOverlay) {
          result.setPixelRgb(x, y, 0, (255 * maskAlpha).toInt(), 0);
        } else {
          final currentP = result.getPixel(x, y);

          // Fast inline RGB -> LAB for pixel p
          final int pr = p.r.clamp(0, 255).toInt();
          final int pg = p.g.clamp(0, 255).toInt();
          final int pb = p.b.clamp(0, 255).toInt();

          final double varR = _sRgbToLinearTable[pr];
          final double varG = _sRgbToLinearTable[pg];
          final double varB = _sRgbToLinearTable[pb];

          final double cX = varR * 0.4124 + varG * 0.3576 + varB * 0.1805;
          final double cY = varR * 0.2126 + varG * 0.7152 + varB * 0.0722;
          final double cZ = varR * 0.0193 + varG * 0.1192 + varB * 0.9505;

          double fx = cX / 95.047;
          double fy = cY / 100.000;
          double fz = cZ / 108.883;

          fx = fx > 0.008856 ? math.pow(fx, 1.0 / 3.0).toDouble() : (7.787 * fx) + (16.0 / 116.0);
          fy = fy > 0.008856 ? math.pow(fy, 1.0 / 3.0).toDouble() : (7.787 * fy) + (16.0 / 116.0);
          fz = fz > 0.008856 ? math.pow(fz, 1.0 / 3.0).toDouble() : (7.787 * fz) + (16.0 / 116.0);

          final double oL = (116.0 * fy) - 16.0;
          final double oA = 500.0 * (fx - fy);
          final double oB = 200.0 * (fy - fz);

          // Realistic architectural paint lighting modulation:
          final double lumModulation = (oL - 75.0) * 0.45;
          double newL = (targetLab[0] + lumModulation).clamp(8.0, 96.0);

          // Deep shadow protection & highlight protection
          if (oL < 20.0) newL = math.min(newL, oL);
          if (oL > 95.0) newL = math.max(newL, oL);

          // Rich pigment coverage for target color
          final double newA = targetLab[1] * strength + oA * (1.0 - strength);
          final double newB = targetLab[2] * strength + oB * (1.0 - strength);

          // Fast inline LAB -> RGB
          final double labY = (newL + 16.0) / 116.0;
          final double labX = newA / 500.0 + labY;
          final double labZ = labY - newB / 200.0;

          final double y3 = labY * labY * labY;
          final double x3 = labX * labX * labX;
          final double z3 = labZ * labZ * labZ;

          final double refY = y3 > 0.008856 ? y3 : (labY - 16.0 / 116.0) / 7.787;
          final double refX = x3 > 0.008856 ? x3 : (labX - 16.0 / 116.0) / 7.787;
          final double refZ = z3 > 0.008856 ? z3 : (labZ - 16.0 / 116.0) / 7.787;

          final double lX = refX * 95.047;
          final double lY = refY * 100.000;
          final double lZ = refZ * 108.883;

          double nvarR = (lX * 3.2406 + lY * -1.5372 + lZ * -0.4986) / 100.0;
          double nvarG = (lX * -0.9689 + lY * 1.8758 + lZ * 0.0415) / 100.0;
          double nvarB = (lX * 0.0557 + lY * -0.2040 + lZ * 1.0570) / 100.0;

          nvarR = nvarR > 0.0031308 ? 1.055 * math.pow(nvarR, 1 / 2.4) - 0.055 : 12.92 * nvarR;
          nvarG = nvarG > 0.0031308 ? 1.055 * math.pow(nvarG, 1 / 2.4) - 0.055 : 12.92 * nvarG;
          nvarB = nvarB > 0.0031308 ? 1.055 * math.pow(nvarB, 1 / 2.4) - 0.055 : 12.92 * nvarB;

          final int newRgbR = (nvarR * 255.0).round().clamp(0, 255);
          final int newRgbG = (nvarG * 255.0).round().clamp(0, 255);
          final int newRgbB = (nvarB * 255.0).round().clamp(0, 255);

          final blendR = (currentP.r * (1 - maskAlpha) + newRgbR * maskAlpha).toInt().clamp(0, 255);
          final blendG = (currentP.g * (1 - maskAlpha) + newRgbG * maskAlpha).toInt().clamp(0, 255);
          final blendB = (currentP.b * (1 - maskAlpha) + newRgbB * maskAlpha).toInt().clamp(0, 255);

          result.setPixelRgb(x, y, blendR, blendG, blendB);
        }
      }
    }
  }

  // Process MaskEdits
  for (final maskEdit in maskEdits) {
    final alphaMask = Float32List(width * height);
    final aiMask = maskEdit.mask;
    final int maskLen = aiMask.confidenceMask.length;
    for (int my = 0; my < aiMask.height; my++) {
      final int py = aiMask.startY + my;
      if (py < 0 || py >= height) continue;
      final int rowOffset = py * width;
      final int maskRowOffset = my * aiMask.width;

      for (int mx = 0; mx < aiMask.width; mx++) {
        final int cIdx = maskRowOffset + mx;
        if (cIdx >= maskLen) break;
        final confidence = aiMask.confidenceMask[cIdx];
        if (confidence > 0.1) {
          final int px = aiMask.startX + mx;
          if (px >= 0 && px < width) {
            final int aIdx = rowOffset + px;
            if (confidence > alphaMask[aIdx]) {
              alphaMask[aIdx] = confidence;
            }
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
      final int rowOffset = y * width;
      for (int x = 0; x < width; x++) {
        final p = image.getPixel(x, y);
        lum[rowOffset + x] = ((p.r * 299 + p.g * 587 + p.b * 114) ~/ 1000).clamp(0, 255);
      }
    }

    for (final tapEdit in tapEdits) {
      final alphaMask = Float32List(width * height);
      final visited = Uint8List(width * height);
      final queue = <int>[];

      final tap = tapEdit.point;
      if (tap.x < 0 || tap.x >= width || tap.y < 0 || tap.y >= height) continue;

      final p = image.getPixel(tap.x, tap.y);
      final startR = p.r;
      final startG = p.g;
      final startB = p.b;
      final startIdx = tap.y * width + tap.x;
      queue.add(startIdx);
      visited[startIdx] = 1;

      final tolSq = tapEdit.tolerance * tapEdit.tolerance * 255 * 255 * 3;
      final maxStepSq = math.min(tapEdit.tolerance * tapEdit.tolerance * 255 * 255 * 3 * 0.4, 550.0);

      while (queue.isNotEmpty) {
        final idx = queue.removeLast();
        final x = idx % width;
        final y = idx ~/ width;

        final cp = image.getPixel(x, y);

        final dr = cp.r - startR;
        final dg = cp.g - startG;
        final db = cp.b - startB;
        final distFromStartSq = dr * dr + dg * dg + db * db;

        if (distFromStartSq <= tolSq) {
          final ratio = distFromStartSq / tolSq;
          alphaMask[idx] = ratio > 0.85 ? ((1.0 - ratio) / 0.15).clamp(0.2, 1.0) : 1.0;

          final cLum = lum[idx];

          final neighbors = <int>[];
          if (x > 0) neighbors.add(idx - 1);
          if (x < width - 1) neighbors.add(idx + 1);
          if (y > 0) neighbors.add(idx - width);
          if (y < height - 1) neighbors.add(idx + width);

          for (final nidx in neighbors) {
            if (visited[nidx] != 0) continue;
            final nLum = lum[nidx];
            if ((cLum - nLum).abs() > 20) continue;

            final nx = nidx % width;
            final ny = nidx ~/ width;

            int grad = 0;
            if (nx > 0 && nx < width - 1) {
              grad += (lum[ny * width + nx + 1] - lum[ny * width + nx - 1]).abs();
            }
            if (ny > 0 && ny < height - 1) {
              grad += (lum[(ny + 1) * width + nx] - lum[(ny - 1) * width + nx]).abs();
            }
            if (grad > 38) continue;

            final np = image.getPixel(nx, ny);
            if (ny < height * 0.65) {
              final isBlueSky = np.b > 160 && np.b > np.r + 50 && np.b >= np.g && (np.r + np.g + np.b) > 380;
              final isOvercastSky = ny < height * 0.40 && np.r > 235 && np.g > 235 && np.b > 235 &&
                  (np.r - np.g).abs() < 6 && (np.g - np.b).abs() < 6 && (np.r - np.b).abs() < 6;
              if (isBlueSky || isOvercastSky) continue;
            }

            final ndr = cp.r - np.r;
            final ndg = cp.g - np.g;
            final ndb = cp.b - np.b;
            final stepSq = ndr * ndr + ndg * ndg + ndb * ndb;

            if (stepSq <= maxStepSq) {
              queue.add(nidx);
              visited[nidx] = 1;
            }
          }
        }
      }
      applyColorToMask(alphaMask, tapEdit.color);
    }
  }

  // Process ManualStrokes
  for (final stroke in manualStrokes) {
    final alphaMask = Float32List(width * height);
    final r = stroke.brushSize.toInt();
    final rSq = r * r;
    for (final pt in stroke.points) {
      for (int dy = -r; dy <= r; dy++) {
        final py = pt.y + dy;
        if (py < 0 || py >= height) continue;
        final int rowOffset = py * width;
        for (int dx = -r; dx <= r; dx++) {
          if (dx * dx + dy * dy <= rSq) {
            final px = pt.x + dx;
            if (px >= 0 && px < width) {
              alphaMask[rowOffset + px] = stroke.isEraser ? 0.0 : 1.0;
            }
          }
        }
      }
    }
    if (!stroke.isEraser) {
      applyColorToMask(alphaMask, stroke.color);
    } else {
      for (int y = 0; y < height; y++) {
        final int rowOffset = y * width;
        for (int x = 0; x < width; x++) {
          if (alphaMask[rowOffset + x] > 0.05) {
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
  final int ir = r.clamp(0, 255).toInt();
  final int ig = g.clamp(0, 255).toInt();
  final int ib = b.clamp(0, 255).toInt();

  final double varR = _sRgbToLinearTable[ir];
  final double varG = _sRgbToLinearTable[ig];
  final double varB = _sRgbToLinearTable[ib];

  final double x = varR * 0.4124 + varG * 0.3576 + varB * 0.1805;
  final double y = varR * 0.2126 + varG * 0.7152 + varB * 0.0722;
  final double z = varR * 0.0193 + varG * 0.1192 + varB * 0.9505;

  double varX = x / 95.047;
  double varY = y / 100.000;
  double varZ = z / 108.883;

  varX = varX > 0.008856 ? math.pow(varX, 1.0 / 3.0).toDouble() : (7.787 * varX) + (16.0 / 116.0);
  varY = varY > 0.008856 ? math.pow(varY, 1.0 / 3.0).toDouble() : (7.787 * varY) + (16.0 / 116.0);
  varZ = varZ > 0.008856 ? math.pow(varZ, 1.0 / 3.0).toDouble() : (7.787 * varZ) + (16.0 / 116.0);

  final double l = (116.0 * varY) - 16.0;
  final double a = 500.0 * (varX - varY);
  final double bVal = 200.0 * (varY - varZ);

  return [l, a, bVal];
}
