import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'image_processor.dart';
import 'models.dart';
import 'models/ai_mode.dart';
import 'models/ai_mask.dart';
import 'services/ai_segmentation_service.dart';
import 'services/lite_segmentation_service.dart';
import 'services/pro_segmentation_service.dart';
import 'services/lite_prompt_parser.dart';

enum EditType { tap, aiMask }

class EditorPage extends StatefulWidget {
  final String imagePath;
  final String? originalImagePath;
  const EditorPage({super.key, required this.imagePath, this.originalImagePath});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

// Top-level function to avoid capturing `this` (the Flutter State) in Isolate.
List<dynamic>? _normalizeAndEncodeImage(Uint8List bytes) {
  try {
    var decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    // 1. Bake EXIF orientation (essential for smartphone photos taken in portrait orientation!)
    decoded = img.bakeOrientation(decoded);

    // 2. Downscale to max dimension of 1280 preserving aspect ratio
    const int maxDim = 1280;
    if (decoded.width > maxDim || decoded.height > maxDim) {
      int newW, newH;
      if (decoded.width > decoded.height) {
        newW = maxDim;
        newH = (maxDim * decoded.height / decoded.width).round();
      } else {
        newH = maxDim;
        newW = (maxDim * decoded.width / decoded.height).round();
      }
      decoded = img.copyResize(decoded, width: newW, height: newH, interpolation: img.Interpolation.linear);
    }

    // 3. Fast, memory-efficient JPEG encoding
    final encoded = Uint8List.fromList(img.encodeJpg(decoded, quality: 92));
    return [decoded, encoded];
  } catch (e) {
    debugPrint("Normalization error: $e");
    return null;
  }
}

class _EditorPageState extends State<EditorPage> {
  img.Image? _originalImage;
  Uint8List? _originalBytes;
  Uint8List? _referenceOriginalBytes;
  Uint8List? get _beforeBytes => _referenceOriginalBytes ?? _originalBytes;
  Uint8List? _editedBytes;
  String _workingImagePath = '';

  bool _isLoading = true;
  bool _isProcessing = false;
  double _processProgress = 0.0;
  String _processMessage = 'Processing image...';
  bool _showSlider = false;
  int _recolorJobId = 0;

  FandeckColor? _targetFandeckColor;
  Color get _targetColor => _targetFandeckColor?.color ?? Colors.white;
  final List<FandeckColor> _appliedColors = [];

  void _recordAppliedColor(FandeckColor c) {
    _appliedColors.removeWhere((col) => col.name == c.name);
    _appliedColors.insert(0, c);
  }

  FandeckColor? _findMatchingFandeckColor(Color color) {
    for (final c in globalFandeckColors) {
      if (c.r == color.red && c.g == color.green && c.b == color.blue) {
        return c;
      }
    }
    FandeckColor? best;
    int minD = 999999;
    for (final c in globalFandeckColors) {
      final dr = c.r - color.red;
      final dg = c.g - color.green;
      final db = c.b - color.blue;
      final d = dr * dr + dg * dg + db * db;
      if (d < minD) {
        minD = d;
        best = c;
      }
    }
    if (minD < 100) return best;
    return null;
  }

  List<FandeckColor> get allAppliedColors {
    final list = <FandeckColor>[];
    if (_targetFandeckColor != null) {
      list.add(_targetFandeckColor!);
    }
    for (final c in _appliedColors) {
      if (!list.any((item) => item.name == c.name)) {
        list.add(c);
      }
    }
    for (final edit in _maskEdits.reversed) {
      final match = _findMatchingFandeckColor(edit.color);
      if (match != null && !list.any((c) => c.name == match.name)) {
        list.add(match);
      }
    }
    for (final edit in _tapEdits.reversed) {
      final match = _findMatchingFandeckColor(edit.color);
      if (match != null && !list.any((c) => c.name == match.name)) {
        list.add(match);
      }
    }
    return list;
  }

  double _tolerance = 0.1;
  List<TapEdit> _tapEdits = [];
  List<MaskEdit> _maskEdits = [];
  List<EditType> _editHistory = [];

  void _updateLastEditColor(Color color) {
    if (_editHistory.isEmpty) return;
    final last = _editHistory.last;
    if (last == EditType.tap && _tapEdits.isNotEmpty) {
      final lastEdit = _tapEdits.last;
      _tapEdits[_tapEdits.length - 1] = TapEdit(lastEdit.point, color, lastEdit.tolerance);
    } else if (last == EditType.aiMask && _maskEdits.isNotEmpty) {
      final lastEdit = _maskEdits.last;
      _maskEdits[_maskEdits.length - 1] = MaskEdit(lastEdit.mask, color);
    }
  }

  void _updateLastEditTolerance(double tol) {
    if (_editHistory.isEmpty) return;
    final last = _editHistory.last;
    if (last == EditType.tap && _tapEdits.isNotEmpty) {
      final lastEdit = _tapEdits.last;
      _tapEdits[_tapEdits.length - 1] = TapEdit(lastEdit.point, lastEdit.color, tol);
    }
  }

  double _sliderPosition = 0.25; // Show a quarter of the original image

  bool _isProAvailable = false;
  AIMode _currentAIMode = AIMode.lite;
  late final LiteSegmentationService _liteSegmentationService;
  late final ProSegmentationService _proSegmentationService;

  @override
  void initState() {
    super.initState();
    _workingImagePath = widget.imagePath;
    _liteSegmentationService = LiteSegmentationService();
    _proSegmentationService = ProSegmentationService();
    _checkProAvailability();
    _loadImage();
  }

  Future<void> _checkProAvailability() async {
    final available = await _proSegmentationService.isAvailable();
    if (mounted) {
      setState(() {
        _isProAvailable = available;
        if (!_isProAvailable && _currentAIMode == AIMode.pro) {
          _currentAIMode = AIMode.lite;
        }
      });
    }
  }

  @override
  void dispose() {
    _liteSegmentationService.dispose();
    _proSegmentationService.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    try {
      // Check for associated unedited original image (saved project)
      String? origPath = widget.originalImagePath;
      if (origPath == null || origPath.isEmpty) {
        final candidate = widget.imagePath.replaceAll(RegExp(r'\.png$', caseSensitive: false), '_orig.png');
        if (File(candidate).existsSync()) {
          origPath = candidate;
        }
      }

      if (origPath != null && File(origPath).existsSync()) {
        final origBytes = await File(origPath).readAsBytes();
        final editedBytes = await XFile(widget.imagePath).readAsBytes();

        final origResult = await compute(_normalizeAndEncodeImage, origBytes);
        final editedResult = await compute(_normalizeAndEncodeImage, editedBytes);

        if (origResult != null && editedResult != null && mounted) {
          final decodedEditedImg = editedResult[0] as img.Image;
          final editedJpgBytes = editedResult[1] as Uint8List;
          final origJpgBytes = origResult[1] as Uint8List;

          try {
            final tempDir = await getTemporaryDirectory();
            final normFile = File('${tempDir.path}/norm_${DateTime.now().millisecondsSinceEpoch}.jpg');
            await normFile.writeAsBytes(editedJpgBytes);
            _workingImagePath = normFile.path;
          } catch (e) {
            debugPrint("Failed to write normalized temp file: $e");
          }

          setState(() {
            _originalImage = decodedEditedImg;
            _originalBytes = editedJpgBytes;
            _referenceOriginalBytes = origJpgBytes;
            _editedBytes = editedJpgBytes;
            _isLoading = false;
          });
          return;
        }
      }

      final bytes = await XFile(widget.imagePath).readAsBytes();

      // Use compute to bake EXIF orientation and downscale to max 1280px in worker isolate
      final result = await compute(_normalizeAndEncodeImage, bytes);

      if (result != null && mounted) {
        final decodedImg = result[0] as img.Image;
        final jpgBytes = result[1] as Uint8List;

        // Cache the normalized image to disk so segmentation services read this exact clean image
        try {
          final tempDir = await getTemporaryDirectory();
          final normFile = File('${tempDir.path}/norm_${DateTime.now().millisecondsSinceEpoch}.jpg');
          await normFile.writeAsBytes(jpgBytes);
          _workingImagePath = normFile.path;
        } catch (e) {
          debugPrint("Failed to write normalized temp file: $e");
        }

        setState(() {
          _originalImage = decodedImg;
          _originalBytes = jpgBytes;
          _referenceOriginalBytes = jpgBytes;
          _editedBytes = _originalBytes;
          _isLoading = false;
        });
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint("Error loading image: $e");
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Load Error: $e")),
        );
      }
    }
  }

  math.Point<int>? _getPointFromLocalPosition(
    Offset localPosition,
    BoxConstraints constraints,
  ) {
    if (_originalImage == null) return null;

    final imageRatio = _originalImage!.width / _originalImage!.height;
    final widgetRatio = constraints.maxWidth / constraints.maxHeight;

    double renderWidth, renderHeight;
    double offsetX = 0, offsetY = 0;

    if (imageRatio > widgetRatio) {
      renderWidth = constraints.maxWidth;
      renderHeight = renderWidth / imageRatio;
      offsetY = (constraints.maxHeight - renderHeight) / 2;
    } else {
      renderHeight = constraints.maxHeight;
      renderWidth = renderHeight * imageRatio;
      offsetX = (constraints.maxWidth - renderWidth) / 2;
    }

    if (localPosition.dx < offsetX ||
        localPosition.dx > offsetX + renderWidth ||
        localPosition.dy < offsetY ||
        localPosition.dy > offsetY + renderHeight) {
      return null;
    }

    final x =
        ((localPosition.dx - offsetX) / renderWidth * _originalImage!.width)
            .toInt()
            .clamp(0, _originalImage!.width - 1);
    final y =
        ((localPosition.dy - offsetY) / renderHeight * _originalImage!.height)
            .toInt()
            .clamp(0, _originalImage!.height - 1);

    return math.Point(x, y);
  }

  Future<void> _onImageTapped(TapUpDetails details, BoxConstraints constraints) async {
    final pt = _getPointFromLocalPosition(details.localPosition, constraints);
    if (pt == null) return;

    setState(() {
      _isProcessing = true;
      _processProgress = 0.0;
      _processMessage = 'Detecting surface...';
    });
    
    // Give UI a moment to show the loader
    await Future.delayed(const Duration(milliseconds: 50));

    final effectivePath = _workingImagePath.isNotEmpty ? _workingImagePath : widget.imagePath;
    AISegmentationService service = _currentAIMode == AIMode.pro ? _proSegmentationService : _liteSegmentationService;
    AIMask? mask;
    try {
      mask = await service.segmentByPoint(
        imagePath: effectivePath,
        point: pt,
        onProgress: (p, msg) {
          if (mounted) setState(() { _processProgress = p; _processMessage = msg; });
        },
      );
    } catch (e) {
      debugPrint("Tap segmentation error: $e");
    }
    
    if (mask == null && _currentAIMode == AIMode.pro) {
      // Fallback to lite for tap since pro might not support tap
      try {
        mask = await _liteSegmentationService.segmentByPoint(
          imagePath: effectivePath,
          point: pt,
          onProgress: (p, msg) {
            if (mounted) setState(() { _processProgress = p; _processMessage = msg; });
          },
        );
      } catch (e) {
        debugPrint("Fallback segmentation error: $e");
      }
    }

    if (mounted) {
      if (mask != null) {
        setState(() {
          _processProgress = 1.0;
          _processMessage = 'Complete!';
        });
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
        _suggestColors(pt, mask: mask);
      }
    }
  }

  void _suggestColors(math.Point<int> pt, {AIMask? mask}) {
    if (_originalImage == null || globalFandeckColors.isEmpty) return;

    final safeX = pt.x.clamp(0, _originalImage!.width - 1);
    final safeY = pt.y.clamp(0, _originalImage!.height - 1);
    final pixel = _originalImage!.getPixel(safeX, safeY);
    final r = pixel.r;
    final g = pixel.g;
    final b = pixel.b;

    final isCeiling = pt.y < (_originalImage!.height * 0.22);
    final surfaceTitle = isCeiling ? 'Ceiling' : 'Wall';

    final sortedColors = List<FandeckColor>.from(globalFandeckColors);
    sortedColors.sort((c1, c2) {
      final dr1 = c1.r - r;
      final dg1 = c1.g - g;
      final db1 = c1.b - b;
      final d1 = dr1 * dr1 + dg1 * dg1 + db1 * db1;

      final dr2 = c2.r - r;
      final dg2 = c2.g - g;
      final db2 = c2.b - b;
      final d2 = dr2 * dr2 + dg2 * dg2 + db2 * db2;
      return d1.compareTo(d2);
    });

    final appliedColors = allAppliedColors;
    final similarColors = <FandeckColor>[];
    for (var c in sortedColors) {
      if (appliedColors.any((a) => a.name == c.name)) continue;
      if (!similarColors.any((s) => s.name == c.name)) {
        similarColors.add(c);
      }
      if (similarColors.length >= 7) break;
    }

    int activeFilter = 0; // 0: All, 1: Similar Colors, 2: Applied Colors

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Widget buildSwatch(FandeckColor c, {required bool isApplied, required bool isLatest}) {
              return GestureDetector(
                onTap: () {
                  setState(() {
                    _targetFandeckColor = c;
                    _recordAppliedColor(c);
                    if (mask != null) {
                      _maskEdits.add(MaskEdit(mask, c.color));
                      _editHistory.add(EditType.aiMask);
                    } else {
                      _tapEdits.add(TapEdit(pt, c.color, _tolerance));
                      _editHistory.add(EditType.tap);
                    }
                  });
                  Navigator.pop(context);
                  _processImage();
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: c.color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isApplied ? const Color(0xFFC8102E) : Colors.white,
                              width: isApplied ? 2.5 : 2.0,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: isApplied
                                    ? const Color(0xFFC8102E).withValues(alpha: 0.5)
                                    : Colors.black45,
                                blurRadius: isApplied ? 8 : 4,
                                spreadRadius: isApplied ? 1 : 0,
                              ),
                            ],
                          ),
                        ),
                        if (isApplied)
                          Container(
                            width: 20,
                            height: 20,
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              isLatest ? Icons.history : Icons.check,
                              size: 13,
                              color: Colors.white,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: 68,
                      child: Text(
                        c.name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white70,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: isApplied ? const Color(0xFFC8102E) : Colors.white12,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isLatest ? 'Last Applied' : (isApplied ? 'Applied' : 'Similar'),
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: isApplied ? FontWeight.bold : FontWeight.normal,
                          color: isApplied ? Colors.white : Colors.white60,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            Widget buildFilterChip(String label, int index, int count) {
              final isSelected = activeFilter == index;
              return GestureDetector(
                onTap: () => setSheetState(() => activeFilter = index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFFC8102E) : Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected ? const Color(0xFFC8102E) : Colors.white12,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected ? Colors.white : Colors.white70,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: isSelected ? Colors.white24 : Colors.white10,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$count',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: isSelected ? Colors.white : Colors.white54,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF111111),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Center(
                    child: Text(
                      'Paint $surfaceTitle with Nippon Paint',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  if (appliedColors.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Center(
                      child: Wrap(
                        spacing: 8,
                        children: [
                          buildFilterChip('All', 0, appliedColors.length + similarColors.length),
                          buildFilterChip('Similar Colors', 1, similarColors.length),
                          buildFilterChip('Applied Colors', 2, appliedColors.length),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (appliedColors.isNotEmpty && (activeFilter == 0 || activeFilter == 2)) ...[
                    Row(
                      children: [
                        const Icon(Icons.history, size: 14, color: Color(0xFFC8102E)),
                        const SizedBox(width: 6),
                        Text(
                          'APPLIED COLOURS (${appliedColors.length})',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: appliedColors.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final c = entry.value;
                        return buildSwatch(c, isApplied: true, isLatest: idx == 0);
                      }).toList(),
                    ),
                    if (activeFilter == 0 && similarColors.isNotEmpty) const SizedBox(height: 16),
                  ],
                  if (activeFilter == 0 || activeFilter == 1) ...[
                    if (appliedColors.isNotEmpty)
                      Row(
                        children: [
                          const Icon(Icons.palette_outlined, size: 14, color: Colors.white54),
                          const SizedBox(width: 6),
                          Text(
                            'SIMILAR TO $surfaceTitle',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    if (appliedColors.isNotEmpty) const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: similarColors.map((c) => buildSwatch(c, isApplied: false, isLatest: false)).toList(),
                    ),
                  ],
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _showColorPicker(onColorSelected: (c) {
                          setState(() {
                            _targetFandeckColor = c;
                            _recordAppliedColor(c);
                            if (mask != null) {
                              _maskEdits.add(MaskEdit(mask, c.color));
                              _editHistory.add(EditType.aiMask);
                            } else {
                              _tapEdits.add(TapEdit(pt, c.color, _tolerance));
                              _editHistory.add(EditType.tap);
                            }
                          });
                          _processImage();
                        });
                      },
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('Search & Browse All Colors', style: TextStyle(fontSize: 14)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFC8102E),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }




  void _undoLast() {
    if (_editHistory.isEmpty) return;

    setState(() {
      final last = _editHistory.removeLast();
      if (last == EditType.tap) {
        if (_tapEdits.isNotEmpty) _tapEdits.removeLast();
      } else if (last == EditType.aiMask) {
        if (_maskEdits.isNotEmpty) _maskEdits.removeLast();
      }
    });

    _processImage();
  }

  Future<void> _shareImage() async {
    if (_editedBytes == null) return;
    try {
      final xFile = XFile.fromData(_editedBytes!, mimeType: 'image/png', name: 'recolored_image.png');
      await Share.shareXFiles([xFile], text: 'Check out my new room color!');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to share image.')),
        );
      }
    }
  }

  Future<void> _saveImage() async {
    if (_editedBytes == null) return;
    try {
      if (kIsWeb) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please use the Share button to save/download on Web.')),
          );
        }
        return;
      }
      
      final TextEditingController nameController = TextEditingController();
      final String? fileName = await showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: const Color(0xFF111111),
            title: const Text('Save Project', style: TextStyle(color: Colors.white)),
            content: TextField(
              controller: nameController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Enter project name',
                hintStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white38)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFC8102E))),
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC8102E)),
                onPressed: () {
                  final text = nameController.text.trim();
                  Navigator.pop(context, text.isEmpty ? 'Project_${DateTime.now().millisecondsSinceEpoch}' : text);
                },
                child: const Text('Save', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      );

      if (fileName == null) return; // User cancelled

      final docDir = await getApplicationDocumentsDirectory();
      final savedDir = Directory('${docDir.path}/saved_images');
      if (!await savedDir.exists()) {
        await savedDir.create(recursive: true);
      }
      
      final safeName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-\s]'), '_');
      var baseFileName = safeName;
      var file = File('${savedDir.path}/$baseFileName.png');
      
      // If file exists, append timestamp to avoid overwriting
      if (await file.exists()) {
         baseFileName = '${safeName}_${DateTime.now().millisecondsSinceEpoch}';
         file = File('${savedDir.path}/$baseFileName.png');
      }

      await file.writeAsBytes(_editedBytes!);

      // Also save the unedited original image alongside the project for Before/After comparison
      final origToSave = _referenceOriginalBytes ?? _originalBytes;
      if (origToSave != null) {
        final origFile = File('${savedDir.path}/${baseFileName}_orig.png');
        await origFile.writeAsBytes(origToSave);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Project saved successfully! Check the Saved tab.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save image.')),
        );
      }
    }
  }

  Future<void> _processImage() async {
    if (_originalImage == null || _originalBytes == null) return;
    if (_tapEdits.isEmpty && _maskEdits.isEmpty) {
      setState(() {
        _editedBytes = _originalBytes;
      });
      return;
    }

    // Process recoloring in background isolate without displaying progress bar
    final jobId = ++_recolorJobId;

    try {
      final params = ProcessImageParams(
        imageBytes: _originalBytes!,
        tapEdits: List.from(_tapEdits),
        maskEdits: List.from(_maskEdits),
        manualStrokes: [],
        showMaskOverlay: false,
      );

      final resultBytes = await processImage(params);

      if (!mounted || jobId != _recolorJobId) return;
      if (resultBytes != null) {
        setState(() {
          _editedBytes = resultBytes;
        });
      }
    } catch (e) {
      debugPrint("Error processing image: $e");
      if (mounted && jobId == _recolorJobId) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to apply color: $e')),
        );
      }
    }
  }

  void _showAppliedColorsSheet(List<FandeckColor> colors) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final currentApplied = allAppliedColors;
            return Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Color(0xFF141414),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                border: Border(top: BorderSide(color: Colors.white24, width: 1)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFC8102E).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.palette, color: Color(0xFFC8102E), size: 18),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Applied Room Colours',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                '${currentApplied.length} ${currentApplied.length == 1 ? "shade" : "shades"} in current design',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.45,
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: currentApplied.length,
                      separatorBuilder: (context, index) => const Divider(color: Colors.white12, height: 16),
                      itemBuilder: (context, index) {
                        final c = currentApplied[index];
                        final isLatest = index == 0;
                        final isCurrentlySelected = _targetFandeckColor?.name == c.name;
                        return InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            setState(() {
                              _targetFandeckColor = c;
                              _recordAppliedColor(c);
                              _updateLastEditColor(c.color);
                            });
                            Navigator.pop(context);
                            _processImage();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                            child: Row(
                              children: [
                                Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: c.color,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isCurrentlySelected
                                              ? const Color(0xFFC8102E)
                                              : Colors.white38,
                                          width: isCurrentlySelected ? 2.5 : 1.5,
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: isCurrentlySelected
                                                ? const Color(0xFFC8102E).withValues(alpha: 0.4)
                                                : Colors.black38,
                                            blurRadius: 6,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (isCurrentlySelected)
                                      const Icon(Icons.check, size: 18, color: Colors.white),
                                  ],
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        c.name,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'RGB (${c.r}, ${c.g}, ${c.b})',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.white54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isLatest
                                        ? const Color(0xFFC8102E)
                                        : Colors.white.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isLatest ? const Color(0xFFC8102E) : Colors.white24,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        isLatest ? Icons.history : Icons.check_circle_outline,
                                        size: 12,
                                        color: isLatest ? Colors.white : Colors.white70,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        isLatest ? 'Last Applied' : 'Applied',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: isLatest ? FontWeight.bold : FontWeight.normal,
                                          color: isLatest ? Colors.white : Colors.white70,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            _showColorPicker();
                          },
                          icon: const Icon(Icons.palette_outlined, size: 16),
                          label: const Text('Browse Fandeck'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showColorPicker({void Function(FandeckColor)? onColorSelected}) {
    String searchQuery = '';
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            final filteredColors = globalFandeckColors
                .where((c) => c.name.toLowerCase().contains(searchQuery.toLowerCase()))
                .toList();
            final appliedList = allAppliedColors;

            return AlertDialog(
              title: const Text('Fandeck Colors'),
              content: SizedBox(
                width: double.maxFinite,
                height: MediaQuery.of(context).size.height * 0.6,
                child: Column(
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Search colors...',
                        prefixIcon: const Icon(Icons.search, color: Colors.white54),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      style: const TextStyle(color: Colors.white),
                      onChanged: (value) {
                        setStateDialog(() {
                          searchQuery = value;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: GridView.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: filteredColors.length,
                        itemBuilder: (context, index) {
                          final c = filteredColors[index];
                          final isApplied = appliedList.any((a) => a.name == c.name);
                          final isLatest = appliedList.isNotEmpty && appliedList.first.name == c.name;
                          return GestureDetector(
                            onTap: () {
                              _recordAppliedColor(c);
                              if (onColorSelected != null) {
                                Navigator.of(context).pop();
                                onColorSelected(c);
                              } else {
                                setState(() {
                                  _targetFandeckColor = c;
                                  _updateLastEditColor(c.color);
                                });
                                Navigator.of(context).pop();
                                _processImage();
                              }
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                color: c.color,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isApplied ? const Color(0xFFC8102E) : Colors.white24,
                                  width: isApplied ? 2.0 : 1.0,
                                ),
                              ),
                              child: Stack(
                                children: [
                                  if (isApplied)
                                    Positioned(
                                      top: 4,
                                      right: 4,
                                      child: Container(
                                        padding: const EdgeInsets.all(2),
                                        decoration: const BoxDecoration(
                                          color: Colors.black54,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          isLatest ? Icons.history : Icons.check,
                                          size: 12,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  Align(
                                    alignment: Alignment.bottomCenter,
                                    child: Container(
                                      width: double.infinity,
                                      color: Colors.black54,
                                      padding: const EdgeInsets.symmetric(vertical: 2),
                                      child: Text(
                                        c.name,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Colors.white,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('Close'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
              ],
            );
          }
        );
      },
    );
  }

  Future<void> _handleAIPrompt(String prompt) async {
    if (_originalImage == null) return;
    
    final lowerPrompt = prompt.toLowerCase();
    
    final colorsToFind = ['red', 'blue', 'green', 'yellow', 'pink', 'purple', 'orange', 'black', 'white', 'grey', 'gray', 'brown'];
    String? foundColorStr;
    for (var c in colorsToFind) {
      if (lowerPrompt.contains(c)) {
        foundColorStr = c;
        break;
      }
    }
    
    List<FandeckColor> matchedColors = [];
    if (foundColorStr != null && globalFandeckColors.isNotEmpty) {
      matchedColors = globalFandeckColors.where((c) => c.name.toLowerCase().contains(foundColorStr!)).toList();
    }

    // In Pro Mode, we use FLUX to directly edit the image!
    if (_currentAIMode == AIMode.pro) {
      if (foundColorStr == null || matchedColors.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please include a color (e.g., red, blue) in your prompt for Pro Mode.')),
        );
        return;
      }

      _showAIColorSelectionSheet(matchedColors, subject: null, onColorSelected: (selectedColor) async {
        setState(() {
          _isProcessing = true;
        });

        // Convert the Color to a HEX string (e.g., #FF0000)
        String hexCode = '#${selectedColor.color.value.toRadixString(16).substring(2).toUpperCase()}';
        
        // Replace the color word in the prompt with the semantic color name AND the HEX code
        String newPrompt = prompt.replaceFirst(
          RegExp(foundColorStr!, caseSensitive: false), 
          "exact ${selectedColor.name} paint color (hex code $hexCode)"
        );

        final effectivePath = _workingImagePath.isNotEmpty ? _workingImagePath : widget.imagePath;
        final editedBytes = await _proSegmentationService.editImage(
          imagePath: effectivePath,
          prompt: newPrompt,
        );

        if (!mounted) return;

        if (editedBytes != null) {
          setState(() {
            _editedBytes = editedBytes;
            _isProcessing = false;
            _editHistory.add(EditType.aiMask); // Add to history for undo
          });
        } else {
          setState(() {
            _isProcessing = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Failed to edit image with AI Pro.")),
          );
        }
      });
      return;
    }

    // --- LITE MODE (OFFLINE PIPELINE) ---
    final parsedCommands = LitePromptParser.parse(prompt);
    
    if (parsedCommands.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not understand the color or object from your prompt.')),
      );
      return;
    }
    
    for (var parsedCommand in parsedCommands) {
      // Find matching Fandeck colors using the color name parsed by LitePromptParser
      List<FandeckColor> liteMatchedColors = globalFandeckColors.where((c) {
        String colorWord = parsedCommand.targetColor.toString(); // Just a fallback, better to use the found string but LitePromptParser returns Color object.
        // Wait, LitePromptParser matches color names from its internal dict. We can search fandeck colors by matching the closest RGB, or just use the first 10.
        // Actually, let's find the FandeckColors closest to parsedCommand.targetColor
        return true;
      }).toList();

      liteMatchedColors.sort((a, b) {
        final dr1 = a.color.red - parsedCommand.targetColor.red;
        final dg1 = a.color.green - parsedCommand.targetColor.green;
        final db1 = a.color.blue - parsedCommand.targetColor.blue;
        final d1 = dr1 * dr1 + dg1 * dg1 + db1 * db1;
        
        final dr2 = b.color.red - parsedCommand.targetColor.red;
        final dg2 = b.color.green - parsedCommand.targetColor.green;
        final db2 = b.color.blue - parsedCommand.targetColor.blue;
        final d2 = dr2 * dr2 + dg2 * dg2 + db2 * db2;
        return d1.compareTo(d2);
      });

      final topColors = liteMatchedColors.take(10).toList();

      setState(() {
        _isProcessing = true;
        _processProgress = 0.0;
        _processMessage = "Analyzing prompt...";
      });
      
      await Future.delayed(const Duration(milliseconds: 50));

      final effectivePath = _workingImagePath.isNotEmpty ? _workingImagePath : widget.imagePath;
      AIMask? mask;
      try {
        mask = await _liteSegmentationService.segment(
          imagePath: effectivePath,
          object: parsedCommand.objectName,
          position: null,
          onProgress: (p, msg) {
            if (mounted) setState(() { _processProgress = p; _processMessage = msg; });
          },
        );
      } catch (e) {
        if (mounted) {
          setState(() {
            _isProcessing = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Seg Error: $e"), duration: const Duration(seconds: 10)),
          );
        }
        continue;
      }

      if (!mounted) return;

      if (mask == null) {
        setState(() {
          _isProcessing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not confidently detect a '${parsedCommand.objectName}' in this image.")),
        );
        continue;
      }

      setState(() {
        _processProgress = 1.0;
        _processMessage = 'Complete!';
      });
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;

      setState(() {
        _isProcessing = false;
      });
      
      await _showAIColorSelectionSheet(topColors, subject: mask, title: "Select a Shade for ${parsedCommand.objectName}");
    }
  }

  Future<void> _showAIColorSelectionSheet(List<FandeckColor> colors, {dynamic subject, void Function(FandeckColor)? onColorSelected, String title = 'Select a Shade'}) async {
    final top10 = colors.take(10).toList();
    
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: top10
                    .map(
                      (c) {
                        final appliedList = allAppliedColors;
                        final isApplied = appliedList.any((a) => a.name == c.name);
                        final isLatest = appliedList.isNotEmpty && appliedList.first.name == c.name;
                        return GestureDetector(
                          onTap: () {
                            Navigator.pop(context);
                            _recordAppliedColor(c);
                            if (onColorSelected != null) {
                              onColorSelected(c);
                              return;
                            }
                            setState(() {
                              _targetFandeckColor = c;
                            });
                            
                            if (subject != null) {
                              setState(() {
                                _maskEdits.add(MaskEdit(subject, c.color));
                                _editHistory.add(EditType.aiMask);
                              });
                            } else {
                              setState(() {
                                _tapEdits.add(TapEdit(math.Point(_originalImage!.width ~/ 2, _originalImage!.height ~/ 2), c.color, _tolerance));
                                _editHistory.add(EditType.tap);
                              });
                            }
                            _processImage();
                          },
                          child: Column(
                            children: [
                              Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    width: 50,
                                    height: 50,
                                    decoration: BoxDecoration(
                                      color: c.color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isApplied ? const Color(0xFFC8102E) : Colors.white,
                                        width: isApplied ? 2.5 : 2,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: isApplied ? const Color(0xFFC8102E).withValues(alpha: 0.5) : Colors.black45,
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isApplied)
                                    Container(
                                      width: 20,
                                      height: 20,
                                      decoration: const BoxDecoration(
                                        color: Colors.black54,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        isLatest ? Icons.history : Icons.check,
                                        size: 13,
                                        color: Colors.white,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                width: 68,
                                child: Text(
                                  c.name,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Colors.white70,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isApplied) ...[
                                const SizedBox(height: 2),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: isLatest ? const Color(0xFFC8102E) : Colors.white12,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    isLatest ? 'Last Applied' : 'Applied',
                                    style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: isLatest ? FontWeight.bold : FontWeight.normal,
                                      color: isLatest ? Colors.white : Colors.white70,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    )
                    .toList(),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _showColorPicker(onColorSelected: onColorSelected);
                  },
                  icon: const Icon(Icons.search),
                  label: const Text('Search & Browse All Colors'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFC8102E),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showAIPromptDialog() {
    final TextEditingController controller = TextEditingController();
    final suggestedPrompts = [
      'Change wall colour to red',
      'Make the ceiling blue',
      'Paint the door white',
      'Change the sofa to dark grey',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final isLite = _currentAIMode == AIMode.lite;
            return Container(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFF111111),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  border: Border(top: BorderSide(color: Colors.white24, width: 1)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Drag Handle
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      
                      // Heading
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.auto_awesome, color: Color(0xFFC8102E), size: 24),
                          SizedBox(width: 8),
                          Text(
                            'AI Assistant',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // Segmented Control for AI Mode
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  setSheetState(() => _currentAIMode = AIMode.lite);
                                  setState(() => _currentAIMode = AIMode.lite);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  decoration: BoxDecoration(
                                    color: isLite ? const Color(0xFFC8102E) : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'AI Lite',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: isLite ? Colors.white : Colors.white54,
                                      fontWeight: isLite ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: _isProAvailable ? () {
                                  setSheetState(() => _currentAIMode = AIMode.pro);
                                  setState(() => _currentAIMode = AIMode.pro);
                                } : null,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  decoration: BoxDecoration(
                                    color: !isLite ? const Color(0xFFC8102E) : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'AI Pro',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: !_isProAvailable 
                                          ? Colors.white24 
                                          : (!isLite ? Colors.white : Colors.white54),
                                      fontWeight: !isLite ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isLite 
                            ? 'Fast • Offline • Private'
                            : 'Advanced AI Segmentation • Best Accuracy',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: Colors.white54),
                      ),
                      const SizedBox(height: 24),

                      // Prompt Input
                      const Text(
                        'Describe your edit',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: controller,
                        autofocus: false,
                        maxLines: 4,
                        minLines: 3,
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                        decoration: InputDecoration(
                          hintText: 'e.g., Change the wall colour to a bright sunny yellow...',
                          hintStyle: const TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.05),
                          contentPadding: const EdgeInsets.all(16),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: Color(0xFFC8102E)),
                          ),
                        ),
                        onChanged: (val) {
                          setSheetState(() {});
                        },
                      ),
                      const SizedBox(height: 16),

                      // Suggestions
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: suggestedPrompts.map((prompt) {
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ActionChip(
                                label: Text(prompt, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                backgroundColor: Colors.white.withOpacity(0.05),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  side: const BorderSide(color: Colors.white12),
                                ),
                                onPressed: () {
                                  controller.text = prompt;
                                  controller.selection = TextSelection.fromPosition(TextPosition(offset: controller.text.length));
                                  setSheetState(() {});
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Actions
                      Row(
                        children: [
                          Expanded(
                            flex: 1,
                            child: TextButton(
                              onPressed: () => Navigator.pop(context),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Text('Cancel', style: TextStyle(color: Colors.white70, fontSize: 16)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton.icon(
                              onPressed: controller.text.trim().isEmpty ? null : () {
                                Navigator.pop(context);
                                _handleAIPrompt(controller.text);
                              },
                              icon: const Icon(Icons.auto_awesome, size: 18),
                              label: const Text('Apply', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFC8102E),
                                disabledBackgroundColor: const Color(0xFFC8102E).withOpacity(0.3),
                                disabledForegroundColor: Colors.white38,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return InteractiveViewer(
                    maxScale: 10.0,
                    panEnabled: true,
                    child: GestureDetector(
                      onTapUp: (details) =>
                          _onImageTapped(details, constraints),
                      child: Stack(
                        children: [
                          if (_editedBytes != null)
                            SizedBox(
                              width: constraints.maxWidth,
                              height: constraints.maxHeight,
                              child: Image.memory(
                                _editedBytes!,
                                width: constraints.maxWidth,
                                height: constraints.maxHeight,
                                fit: BoxFit.contain,
                              ),
                            ),
                          if (_beforeBytes != null && _showSlider)
                            ClipRect(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                widthFactor: _sliderPosition,
                                child: SizedBox(
                                  width: constraints.maxWidth,
                                  height: constraints.maxHeight,
                                  child: Image.memory(
                                    _beforeBytes!,
                                    width: constraints.maxWidth,
                                    height: constraints.maxHeight,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ),

                          if (_showSlider)
                            Positioned(
                            left: constraints.maxWidth * _sliderPosition - 15,
                            top: 0,
                            bottom: 0,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (_) {},
                              onPanUpdate: (details) {
                                setState(() {
                                  _sliderPosition +=
                                      details.delta.dx / constraints.maxWidth;
                                  _sliderPosition = _sliderPosition.clamp(
                                    0.0,
                                    1.0,
                                  );
                                });
                              },
                              child: Container(
                                width: 30,
                                color: Colors.transparent,
                                child: Center(
                                  child: Container(
                                    width: 4,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.5),
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (_showSlider && _editedBytes != null)
                            Positioned(
                              left: constraints.maxWidth * _sliderPosition - 20,
                              top: constraints.maxHeight / 2 - 20,
                              child: IgnorePointer(
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFFC8102E), width: 2),
                                    boxShadow: [
                                      BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 8),
                                    ],
                                  ),
                                  child: const Icon(Icons.compare_arrows, size: 24, color: Color(0xFFC8102E)),
                                ),
                              ),
                            ),
                          if (_showSlider && _editedBytes != null)
                            Positioned(
                              left: 16,
                              bottom: 16,
                              child: IgnorePointer(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.6),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Text('Before', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                              ),
                            ),
                          if (_showSlider && _editedBytes != null)
                            Positioned(
                              right: 16,
                              bottom: 16,
                              child: IgnorePointer(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.6),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Text('After', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                              ),
                            ),
                          if (_isProcessing)
                            Container(
                              color: Colors.black54,
                              child: Center(
                                child: Container(
                                  width: 270,
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1A1A1A).withValues(alpha: 0.95),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: Colors.white12),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black87,
                                        blurRadius: 24,
                                        spreadRadius: 4,
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          SizedBox(
                                            width: 72,
                                            height: 72,
                                            child: CircularProgressIndicator(
                                              value: _processProgress > 0.0 ? _processProgress.clamp(0.0, 1.0) : null,
                                              color: const Color(0xFFC8102E),
                                              backgroundColor: Colors.white12,
                                              strokeWidth: 5,
                                            ),
                                          ),
                                          Text(
                                            _processProgress > 0.0
                                                ? '${(_processProgress * 100).toInt()}%'
                                                : '',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 20),
                                      Text(
                                        _processMessage,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                      if (_processProgress > 0.0) ...[
                                        const SizedBox(height: 14),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(6),
                                          child: SizedBox(
                                            width: 170,
                                            height: 6,
                                            child: LinearProgressIndicator(
                                              value: _processProgress.clamp(0.0, 1.0),
                                              color: const Color(0xFFC8102E),
                                              backgroundColor: Colors.white10,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),


          // Compact Top Navigation Bar
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            right: 16,
            child: Column(
              children: [
                const Text(
                  'Photo Editor',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24, width: 1),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
                            onPressed: () => Navigator.pop(context),
                          ),
                      IconButton(
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: Icon(Icons.history, size: 20, color: _editHistory.isNotEmpty ? Colors.white : Colors.white38),
                        onPressed: _editHistory.isNotEmpty ? _undoLast : null,
                        tooltip: 'Undo',
                      ),
                      IconButton(
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: const Icon(Icons.auto_awesome, size: 20, color: Colors.white),
                        onPressed: _showAIPromptDialog,
                        tooltip: 'AI Magic',
                      ),
                      if (_editedBytes != null) ...[
                        IconButton(
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          icon: Icon(
                            _showSlider ? Icons.compare : Icons.compare_outlined,
                            size: 20,
                            color: _showSlider ? const Color(0xFFC8102E) : Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              _showSlider = !_showSlider;
                            });
                          },
                          tooltip: 'Compare Before/After',
                        ),
                        IconButton(
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          icon: const Icon(Icons.save_alt, size: 20, color: Colors.white),
                          onPressed: _saveImage,
                          tooltip: 'Save',
                        ),
                        IconButton(
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          icon: const Icon(Icons.share, size: 20, color: Colors.white),
                          onPressed: _shareImage,
                          tooltip: 'Share',
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),

          // Floating Manual Color Picker
          // Floating Manual Color Picker / Applied Colors Palette
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 24,
            right: 16,
            child: GestureDetector(
              onTap: () {
                final applied = allAppliedColors;
                if (applied.isEmpty) {
                  _showColorPicker();
                } else {
                  _showAppliedColorsSheet(applied);
                }
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: Colors.white24, width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (allAppliedColors.isNotEmpty)
                          SizedBox(
                            height: 18,
                            width: math.min(allAppliedColors.length, 3) * 12.0 + 8,
                            child: Stack(
                              children: allAppliedColors.take(3).toList().asMap().entries.map((entry) {
                                final idx = entry.key;
                                final c = entry.value;
                                return Positioned(
                                  left: idx * 12.0,
                                  child: Container(
                                    width: 18,
                                    height: 18,
                                    decoration: BoxDecoration(
                                      color: c.color,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 1.5),
                                      boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 2)],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          )
                        else if (_targetFandeckColor != null)
                          Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: _targetColor,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 1.5),
                            ),
                          )
                        else
                          const Icon(Icons.palette_outlined, color: Colors.white, size: 16),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 110),
                          child: Text(
                            allAppliedColors.length > 1
                                ? '${allAppliedColors.length} Colours'
                                : (_targetFandeckColor?.name ?? 'Manual'),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

