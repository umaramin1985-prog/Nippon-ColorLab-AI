import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
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

class _EditorPageState extends State<EditorPage> {
  img.Image? _originalImage;
  Uint8List? _originalBytes;
  Uint8List? _editedBytes;

  bool _isLoading = true;
  bool _isProcessing = false;

  Color _targetColor = globalFandeckColors.isNotEmpty ? globalFandeckColors.first.color : Colors.white;
  double _tolerance = 0.1;
  List<math.Point<int>> _taps = [];
  List<AIMask> _aiMasks = [];
  List<EditType> _editHistory = [];

  double _sliderPosition = 0.5;



  bool _isProAvailable = false;
  AIMode _currentAIMode = AIMode.lite;
  late final LiteSegmentationService _liteSegmentationService;
  late final ProSegmentationService _proSegmentationService;

  @override
  void initState() {
    super.initState();
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
    final bytes = await File(widget.imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);

    if (decoded != null) {
      setState(() {
        _originalImage = decoded;
        _originalBytes = img.encodePng(decoded);
        _editedBytes = _originalBytes;
        
        _isLoading = false;
      });
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
            .toInt();
    final y =
        ((localPosition.dy - offsetY) / renderHeight * _originalImage!.height)
            .toInt();

    return math.Point(x, y);
  }

  Future<void> _onImageTapped(TapUpDetails details, BoxConstraints constraints) async {
    final pt = _getPointFromLocalPosition(details.localPosition, constraints);
    if (pt == null) return;

    bool foundAISubject = false;

    AISegmentationService service = _currentAIMode == AIMode.pro ? _proSegmentationService : _liteSegmentationService;
    AIMask? mask = await service.segmentByPoint(imagePath: widget.imagePath, point: pt);
    
    if (mask == null && _currentAIMode == AIMode.pro) {
      // Fallback to lite for tap since pro might not support tap
      mask = await _liteSegmentationService.segmentByPoint(imagePath: widget.imagePath, point: pt);
    }

    if (mask != null && mounted) {
      setState(() {
        _aiMasks.add(mask!);
        _editHistory.add(EditType.aiMask);
      });
      foundAISubject = true;
    }

    if (!foundAISubject && mounted) {
      setState(() {
        _taps.add(pt);
        _editHistory.add(EditType.tap);
      });
    }

    if (mounted) {
      _suggestColors(pt);
      _processImage();
    }
  }

  void _suggestColors(math.Point<int> pt) {
    if (_originalImage == null || globalFandeckColors.isEmpty) return;

    final pixel = _originalImage!.getPixel(pt.x, pt.y);
    final r = pixel.r;
    final g = pixel.g;
    final b = pixel.b;

    final sortedColors = List<FandeckColor>.from(globalFandeckColors);
    sortedColors.sort((c1, c2) {
      final d1 =
          math.pow(c1.r - r, 2) + math.pow(c1.g - g, 2) + math.pow(c1.b - b, 2);
      final d2 =
          math.pow(c2.r - r, 2) + math.pow(c2.g - g, 2) + math.pow(c2.b - b, 2);
      return d1.compareTo(d2);
    });

    final top5 = sortedColors.take(5).toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Suggested Matching Colors',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: top5
                    .map(
                      (c) => GestureDetector(
                        onTap: () {
                          setState(() {
                            _targetColor = c.color;
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
                    _showColorPicker();
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
        if (_taps.isNotEmpty) _taps.removeLast();
      } else if (last == EditType.aiMask) {
        if (_aiMasks.isNotEmpty) _aiMasks.removeLast();
      }
    });

    _processImage();
  }

  Future<void> _shareImage() async {
    if (_editedBytes == null) return;
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/recolored_image.png');
      await file.writeAsBytes(_editedBytes!);
      await Share.shareXFiles([XFile(file.path)], text: 'Check out my new room color!');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to share image.')),
        );
      }
    }
  }

  Future<void> _processImage() async {
    if (_originalImage == null) return;
    if (_taps.isEmpty && _aiMasks.isEmpty) {
      setState(() {
        _editedBytes = _originalBytes;
      });
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    final params = ProcessImageParams(
      image: _originalImage!,
      taps: _taps,
      aiMasks: _aiMasks,
      manualStrokes: [],
      targetColor: _targetColor,
      tolerance: _tolerance,
      showMaskOverlay: false,
    );

    final result = await processImage(params);
    final resultBytes = img.encodePng(result);

    setState(() {
      _editedBytes = resultBytes;
      _isProcessing = false;
    });
  }

  void _showColorPicker() {
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
                              setState(() {
                                _targetColor = c.color;
                              });
                              Navigator.of(context).pop();
                              _processImage();
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

        final editedBytes = await _proSegmentationService.editImage(
          imagePath: widget.imagePath,
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
    final parsedCommand = LitePromptParser.parse(prompt);
    
    if (parsedCommand == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not understand the color or object from your prompt.')),
      );
      return;
    }
    
    // Find matching Fandeck colors using the color name parsed by LitePromptParser
    List<FandeckColor> liteMatchedColors = globalFandeckColors.where((c) {
      // Find the color word that matched (we know it's in the original prompt if parsedCommand != null)
      // For simplicity, we just use the original matchedColors if it has items, or we can search again.
      // But we can just use the foundColorStr from earlier since it works well for both.
      return c.name.toLowerCase().contains(foundColorStr ?? '');
    }).toList();

    if (liteMatchedColors.isEmpty) {
      // Fallback: match by closest RGB? For now, if no fandeck color matches exactly by name, we just show top colors
      liteMatchedColors = globalFandeckColors.take(10).toList(); 
    }

    setState(() {
      _isProcessing = true;
    });

    // Phase 1: Use ML Kit as a stand-in for SAM segmentation using the parsed objectName
    // (Phase 2 will replace this with MobileSAM + MobileCLIP ONNX inference)
    AIMask? mask;
    try {
      mask = await _liteSegmentationService.segment(
        imagePath: widget.imagePath,
        object: parsedCommand.objectName,
        position: null,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Seg Error: $e"), duration: Duration(seconds: 10)),
        );
      }
      return;
    }

    if (!mounted) return;

    setState(() {
      _isProcessing = false;
    });

    if (mask == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not confidently detect a '${parsedCommand.objectName}' in this image.")),
      );
      return;
    }
    
    _showAIColorSelectionSheet(liteMatchedColors, subject: mask);
  }

  void _showAIColorSelectionSheet(List<FandeckColor> colors, {dynamic subject, void Function(FandeckColor)? onColorSelected}) {
    final top10 = colors.take(10).toList();
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Select a Shade',
                style: TextStyle(
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
                            _targetColor = c.color;
                          });
                          
                          if (subject != null) {
                            setState(() {
                              _aiMasks.add(subject);
                              _editHistory.add(EditType.aiMask);
                            });
                          } else {
                            setState(() {
                              _taps.add(math.Point(_originalImage!.width ~/ 2, _originalImage!.height ~/ 2));
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
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showAIPromptDialog() {
    final TextEditingController controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.auto_awesome, color: Color(0xFFC8102E)),
                  SizedBox(width: 8),
                  Text('AI Assistant'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ChoiceChip(
                        label: const Text('AI Lite'),
                        selected: _currentAIMode == AIMode.lite,
                        onSelected: (selected) {
                          if (selected) {
                            setDialogState(() => _currentAIMode = AIMode.lite);
                            setState(() => _currentAIMode = AIMode.lite);
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text('AI Pro'),
                        selected: _currentAIMode == AIMode.pro,
                        onSelected: _isProAvailable ? (selected) {
                          if (selected) {
                            setDialogState(() => _currentAIMode = AIMode.pro);
                            setState(() => _currentAIMode = AIMode.pro);
                          }
                        } : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _currentAIMode == AIMode.lite 
                        ? 'Fast • Offline • Private'
                        : 'Advanced AI Segmentation • Best Accuracy',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'e.g., change colour of wall to red',
                      hintStyle: TextStyle(color: Colors.white54),
                    ),
                    onSubmitted: (val) {
                      Navigator.pop(context);
                      _handleAIPrompt(val);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC8102E)),
                  onPressed: () {
                    Navigator.pop(context);
                    _handleAIPrompt(controller.text);
                  },
                  child: const Text('Apply', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nippon Paint',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
                fontSize: 18,
              ),
            ),
            Text(
              'Visualize Space',
              style: TextStyle(
                fontSize: 10,
                color: Colors.white70,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFFC8102E),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: Colors.amber),
            onPressed: _showAIPromptDialog,
            tooltip: 'AI Assistant',
          ),
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: _editHistory.isEmpty ? null : _undoLast,
            tooltip: 'Undo',
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              setState(() {
                _taps.clear();
                _aiMasks.clear();
                _editHistory.clear();
              });
              _processImage();
            },
            tooltip: 'Clear Selection',
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _editedBytes != null ? _shareImage : null,
            tooltip: 'Share Image',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
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
                          if (_originalBytes != null)
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
                          Positioned(
                            left: constraints.maxWidth * _sliderPosition - 16,
                            top: constraints.maxHeight / 2 - 16,
                            child: IgnorePointer(
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFFC8102E),
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.3),
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.compare_arrows,
                                  size: 20,
                                  color: Color(0xFFC8102E),
                                ),
                              ),
                            ),
                          ),
                          if (_isProcessing)
                            Container(
                              color: Colors.black45,
                              child: const Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFFC8102E),
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

          // Bottom Tool Bar
          if (_taps.isNotEmpty || _aiMasks.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 10,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      // Selected Color Circle
                      GestureDetector(
                        onTap: _showColorPicker,
                        child: Column(
                          children: [
                            Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                color: _targetColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.3),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Colour',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 24),
                      // Tolerance Slider
                      const Text(
                        'Tolerance:',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      Expanded(
                        child: Slider(
                          value: _tolerance,
                          min: 0.01,
                          max: 1.0,
                          activeColor: const Color(0xFFC8102E),
                          onChanged: (value) {
                            setState(() {
                              _tolerance = value;
                            });
                          },
                          onChangeEnd: (value) {
                            _processImage();
                          },
                        ),
                      ),
                      Text(
                        '${(_tolerance * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

