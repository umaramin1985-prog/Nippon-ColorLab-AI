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
  const EditorPage({super.key, required this.imagePath});

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
  Uint8List? _editedBytes;
  String _workingImagePath = '';

  bool _isLoading = true;
  bool _isProcessing = false;
  bool _showSlider = false;

  FandeckColor? _targetFandeckColor;
  Color get _targetColor => _targetFandeckColor?.color ?? Colors.white;
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

  bool _isSkyPoint(math.Point<int> pt) {
    if (_originalImage == null) return false;
    final h = _originalImage!.height;
    if (pt.y > h * 0.65) return false;

    final safeX = pt.x.clamp(0, _originalImage!.width - 1);
    final safeY = pt.y.clamp(0, _originalImage!.height - 1);
    final p = _originalImage!.getPixel(safeX, safeY);
    final r = p.r;
    final g = p.g;
    final b = p.b;

    final isBlueSky = b > 160 && b > r + 50 && b >= g && (r + g + b) > 380;
    final isOvercastSky = pt.y < h * 0.40 && r > 235 && g > 235 && b > 235 &&
        (r - g).abs() < 6 && (g - b).abs() < 6 && (r - b).abs() < 6;

    return isBlueSky || isOvercastSky;
  }

  Future<void> _onImageTapped(TapUpDetails details, BoxConstraints constraints) async {
    final pt = _getPointFromLocalPosition(details.localPosition, constraints);
    if (pt == null) return;

    if (_isSkyPoint(pt)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sky cannot be painted. Please tap on walls, ceilings, doors, or furniture.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    setState(() {
      _isProcessing = true;
    });
    
    // Give UI a moment to show the loader
    await Future.delayed(const Duration(milliseconds: 50));

    final effectivePath = _workingImagePath.isNotEmpty ? _workingImagePath : widget.imagePath;
    AISegmentationService service = _currentAIMode == AIMode.pro ? _proSegmentationService : _liteSegmentationService;
    AIMask? mask;
    try {
      mask = await service.segmentByPoint(imagePath: effectivePath, point: pt);
    } catch (e) {
      debugPrint("Tap segmentation error: $e");
    }
    
    if (mask == null && _currentAIMode == AIMode.pro) {
      // Fallback to lite for tap since pro might not support tap
      try {
        mask = await _liteSegmentationService.segmentByPoint(imagePath: effectivePath, point: pt);
      } catch (e) {
        debugPrint("Fallback segmentation error: $e");
      }
    }

    if (mounted) {
      setState(() {
        _isProcessing = false;
      });
      _suggestColors(pt, mask: mask);
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

    final suggested = <FandeckColor>[];
    if (_targetFandeckColor != null) {
      suggested.add(_targetFandeckColor!);
    }
    for (var c in sortedColors) {
      if (!suggested.any((s) => s.name == c.name)) {
        suggested.add(c);
      }
      if (suggested.length >= 4) break;
    }
    for (var c in globalFandeckColors) {
      if (!suggested.any((s) => s.name == c.name)) {
        suggested.add(c);
      }
      if (suggested.length >= 8) break;
    }

    showModalBottomSheet(
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
                'Paint $surfaceTitle with Nippon Paint',
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
                children: suggested
                    .map(
                      (c) => GestureDetector(
                        onTap: () {
                          setState(() {
                            _targetFandeckColor = c;
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
                          children: [
                            Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                color: c.color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              width: 60,
                              child: Text(
                                c.name,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white70,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
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
                    _showColorPicker(onColorSelected: (c) {
                      setState(() {
                        _targetFandeckColor = c;
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
      var file = File('${savedDir.path}/$safeName.png');
      
      // If file exists, append timestamp to avoid overwriting
      if (await file.exists()) {
         file = File('${savedDir.path}/${safeName}_${DateTime.now().millisecondsSinceEpoch}.png');
      }

      await file.writeAsBytes(_editedBytes!);
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

    setState(() {
      _isProcessing = true;
    });

    try {
      final params = ProcessImageParams(
        imageBytes: _originalBytes!,
        tapEdits: _tapEdits,
        maskEdits: _maskEdits,
        manualStrokes: [],
        showMaskOverlay: false,
      );

      final resultBytes = await processImage(params);

      if (!mounted) return;
      setState(() {
        if (resultBytes != null) {
          _editedBytes = resultBytes;
        }
        _isProcessing = false;
      });
    } catch (e) {
      debugPrint("Error processing image: $e");
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to apply color: $e')),
        );
      }
    }
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
                        fillColor: Colors.white.withOpacity(0.05),
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
                          return GestureDetector(
                            onTap: () {
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
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Align(
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
      if (lowerPrompt.contains('sky') || lowerPrompt.contains('cloud')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sky cannot be painted. Please choose an architectural surface like walls, ceilings, doors, or furniture.')),
        );
        return;
      }

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

    if (parsedCommands.any((cmd) => cmd.objectName == 'sky')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sky cannot be painted. Please choose an architectural surface like walls, ceilings, doors, or furniture.')),
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
      });
      
      await Future.delayed(const Duration(milliseconds: 50));

      final effectivePath = _workingImagePath.isNotEmpty ? _workingImagePath : widget.imagePath;
      AIMask? mask;
      try {
        mask = await _liteSegmentationService.segment(
          imagePath: effectivePath,
          object: parsedCommand.objectName,
          position: null,
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

      setState(() {
        _isProcessing = false;
      });

      if (mask == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not confidently detect a '${parsedCommand.objectName}' in this image.")),
        );
        continue;
      }
      
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
                      (c) => GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
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
                            Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                color: c.color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              width: 60,
                              child: Text(
                                c.name,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white70,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
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
                          if (_originalBytes != null && _showSlider)
                            ClipRect(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                widthFactor: _sliderPosition,
                                child: SizedBox(
                                  width: constraints.maxWidth,
                                  height: constraints.maxHeight,
                                  child: Image.memory(
                                    _originalBytes!,
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
                              color: Colors.black45,
                              child: const Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(color: Color(0xFFC8102E)),
                                    SizedBox(height: 16),
                                    Text('Processing image...', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                  ],
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
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 24,
            right: 16,
            child: GestureDetector(
              onTap: _showColorPicker,
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
                        if (_targetFandeckColor != null)
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
                          constraints: const BoxConstraints(maxWidth: 90),
                          child: Text(
                            _targetFandeckColor?.name ?? 'Manual',
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

