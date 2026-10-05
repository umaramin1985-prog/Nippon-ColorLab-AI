import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'image_processor.dart';
import 'models.dart';

enum EditType { tap, aiMask }

class EditorPage extends StatefulWidget {
  final String imagePath;
  final XFile? imageFile;
  final Uint8List? imageBytes;

  const EditorPage({
    super.key,
    required this.imagePath,
    this.imageFile,
    this.imageBytes,
  });

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  img.Image? _originalImage;
  img.Image? _editedImage;
  Uint8List? _originalBytes;
  Uint8List? _editedBytes;

  bool _isLoading = true;
  bool _isProcessing = false;

  Color _targetColor = globalFandeckColors.isNotEmpty ? globalFandeckColors.first.color : Colors.white;
  double _tolerance = 0.1;
  List<math.Point<int>> _taps = [];
  List<AIMask> _aiMasks = [];
  List<EditType> _editHistory = [];

  double _sliderPosition = 0.0;

  bool _showMask = false;
  String? _dragEdge;
  math.Rectangle<int>? _globalSelectionBox;

  late final SubjectSegmenter _segmenter;
  SubjectSegmentationResult? _segmentationResult;
  final TextEditingController _aiPromptController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _segmenter = SubjectSegmenter(
      options: SubjectSegmenterOptions(
        enableForegroundConfidenceMask: false,
        enableForegroundBitmap: false,
        enableMultipleSubjects: SubjectResultOptions(
          enableConfidenceMask: true,
          enableSubjectBitmap: false,
        ),
      ),
    );
    _loadImage();
  }

  @override
  void dispose() {
    _segmenter.close();
    _aiPromptController.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    Uint8List? bytes;
    try {
      if (widget.imageBytes != null) {
        bytes = widget.imageBytes;
      } else if (widget.imageFile != null) {
        bytes = await widget.imageFile!.readAsBytes();
      } else if (kIsWeb) {
        bytes = await XFile(widget.imagePath).readAsBytes();
      } else {
        bytes = await io.File(widget.imagePath).readAsBytes();
      }
    } catch (e) {
      debugPrint("Error reading image bytes: $e");
    }

    if (bytes == null) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    final decoded = img.decodeImage(bytes);

    try {
      if (!kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS)) {
        final inputImage = InputImage.fromFilePath(widget.imagePath);
        _segmentationResult = await _segmenter.processImage(inputImage);
      }
    } catch (e) {
      debugPrint("ML Kit not supported or failed: $e");
    }

    if (decoded != null) {
      setState(() {
        _originalImage = decoded;
        _originalBytes = img.encodeJpg(decoded);
        _editedImage = decoded.clone();
        _editedBytes = _originalBytes;
        
        if (_segmentationResult != null && _segmentationResult!.subjects.isNotEmpty) {
          final s = _segmentationResult!.subjects[0];
          _globalSelectionBox = math.Rectangle(s.startX, s.startY, s.width, s.height);
        } else {
          _globalSelectionBox = math.Rectangle(0, 0, decoded.width, decoded.height);
        }
        
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

  void _onImageTapped(TapUpDetails details, BoxConstraints constraints) {
    if (_showMask) return; // Prevent tapping while adjusting mask

    final pt = _getPointFromLocalPosition(details.localPosition, constraints);
    if (pt == null) return;

    bool foundAISubject = false;

    if (_segmentationResult != null) {
      for (var subject in _segmentationResult!.subjects) {
        if (pt.x >= subject.startX &&
            pt.x < subject.startX + subject.width &&
            pt.y >= subject.startY &&
            pt.y < subject.startY + subject.height) {
          int localX = pt.x - subject.startX;
          int localY = pt.y - subject.startY;
          int idx = localY * subject.width + localX;

          if (subject.confidenceMask != null &&
              subject.confidenceMask![idx] > 0.5) {
            setState(() {
              _aiMasks.add(
                AIMask(
                  subject.confidenceMask!,
                  subject.startX,
                  subject.startY,
                  subject.width,
                  subject.height,
                ),
              );
              _editHistory.add(EditType.aiMask);
            });
            foundAISubject = true;
            break;
          }
        }
      }
    }

    if (!foundAISubject) {
      setState(() {
        _taps.add(pt);
        _editHistory.add(EditType.tap);
      });
    }

    _suggestColors(pt);
    _processImage();
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
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }


  void _onMaskPanDown(DragDownDetails details, BoxConstraints constraints) {
    if (!_showMask || _globalSelectionBox == null) return;
    final pt = _getPointFromLocalPosition(details.localPosition, constraints);
    if (pt == null) return;
    
    int edgeTol = 40;
    if ((pt.x - _globalSelectionBox!.left).abs() < edgeTol) _dragEdge = 'L';
    else if ((pt.x - _globalSelectionBox!.right).abs() < edgeTol) _dragEdge = 'R';
    else if ((pt.y - _globalSelectionBox!.top).abs() < edgeTol) _dragEdge = 'T';
    else if ((pt.y - _globalSelectionBox!.bottom).abs() < edgeTol) _dragEdge = 'B';
    else _dragEdge = 'C';
  }

  void _onMaskPanUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (!_showMask || _globalSelectionBox == null || _dragEdge == null) return;
    final pt = _getPointFromLocalPosition(details.localPosition, constraints);
    if (pt == null) return;

    int newL = _globalSelectionBox!.left;
    int newR = _globalSelectionBox!.right;
    int newT = _globalSelectionBox!.top;
    int newB = _globalSelectionBox!.bottom;

    if (_dragEdge == 'L') newL = pt.x;
    if (_dragEdge == 'R') newR = pt.x;
    if (_dragEdge == 'T') newT = pt.y;
    if (_dragEdge == 'B') newB = pt.y;

    int snapDist = 40;
    if (_segmentationResult != null) {
      for (var s in _segmentationResult!.subjects) {
        if (_dragEdge == 'L' && (newL - s.startX).abs() < snapDist) newL = s.startX;
        if (_dragEdge == 'R' && (newR - (s.startX + s.width)).abs() < snapDist) newR = s.startX + s.width;
        if (_dragEdge == 'T' && (newT - s.startY).abs() < snapDist) newT = s.startY;
        if (_dragEdge == 'B' && (newB - (s.startY + s.height)).abs() < snapDist) newB = s.startY + s.height;
      }
    }

    if (newL >= newR) {
      if (_dragEdge == 'L') newL = newR - 1;
      else newR = newL + 1;
    }
    if (newT >= newB) {
      if (_dragEdge == 'T') newT = newB - 1;
      else newB = newT + 1;
    }

    setState(() {
      _globalSelectionBox = math.Rectangle(newL, newT, newR - newL, newB - newT);
    });
  }

  void _onMaskPanEnd(DragEndDetails details) {
    _dragEdge = null;
    if (_showMask) {
      _processImage();
    }
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

  Future<void> _processImage() async {
    if (_originalImage == null) return;
    if (_taps.isEmpty && _aiMasks.isEmpty) {
      setState(() {
        _editedImage = _originalImage?.clone();
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
      boundingBox: _globalSelectionBox,
    );

    final result = await processImage(params);
    final resultBytes = img.encodeJpg(result);

    setState(() {
      _editedImage = result;
      _editedBytes = resultBytes;
      _isProcessing = false;
    });
  }

  void _showColorPicker() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Fandeck Colors'),
          content: SizedBox(
            width: double.maxFinite,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: globalFandeckColors.length,
              itemBuilder: (context, index) {
                final c = globalFandeckColors[index];
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _targetColor = c.color;
                      if (_taps.isEmpty && _aiMasks.isEmpty && _originalImage != null) {
                        _taps.add(math.Point(_originalImage!.width ~/ 2, _originalImage!.height ~/ 2));
                        _editHistory.add(EditType.tap);
                      }
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
          actions: <Widget>[
            TextButton(
              child: const Text('Close'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _handleAIPrompt(String prompt) {
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

    if (matchedColors.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not understand the color from your prompt.')),
      );
      return;
    }

    dynamic selectedSubject;
    if (_segmentationResult != null && _segmentationResult!.subjects.isNotEmpty) {
      selectedSubject = _segmentationResult!.subjects[0];
      
      if (lowerPrompt.contains('ceiling') || lowerPrompt.contains('roof') || lowerPrompt.contains('top')) {
        int minStartY = selectedSubject.startY;
        for (var s in _segmentationResult!.subjects) {
          if (s.startY < minStartY) {
            minStartY = s.startY;
            selectedSubject = s;
          }
        }
      } else if (lowerPrompt.contains('floor') || lowerPrompt.contains('ground') || lowerPrompt.contains('bottom') || lowerPrompt.contains('carpet')) {
        int maxBottomY = selectedSubject.startY + selectedSubject.height;
        for (var s in _segmentationResult!.subjects) {
          int bottomY = s.startY + s.height;
          if (bottomY > maxBottomY) {
            maxBottomY = bottomY;
            selectedSubject = s;
          }
        }
      } else if (lowerPrompt.contains('left')) {
        int minStartX = selectedSubject.startX;
        for (var s in _segmentationResult!.subjects) {
          if (s.startX < minStartX) {
            minStartX = s.startX;
            selectedSubject = s;
          }
        }
      } else if (lowerPrompt.contains('right')) {
        int maxRightX = selectedSubject.startX + selectedSubject.width;
        for (var s in _segmentationResult!.subjects) {
          int rightX = s.startX + s.width;
          if (rightX > maxRightX) {
            maxRightX = rightX;
            selectedSubject = s;
          }
        }
      } else {
        var maxArea = selectedSubject.width * selectedSubject.height;
        for (var s in _segmentationResult!.subjects) {
          var area = s.width * s.height;
          if (area > maxArea) {
            maxArea = area;
            selectedSubject = s;
          }
        }
      }
    }
    
    _showAIColorSelectionSheet(matchedColors, selectedSubject);
  }

  void _showAIColorSelectionSheet(List<FandeckColor> colors, dynamic subject) {
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
                          setState(() {
                            _targetColor = c.color;
                          });
                          Navigator.pop(context);
                          
                          if (subject != null) {
                            setState(() {
                              _aiMasks.add(
                                AIMask(
                                  subject.confidenceMask!,
                                  subject.startX,
                                  subject.startY,
                                  subject.width,
                                  subject.height,
                                ),
                              );
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
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.auto_awesome, color: Color(0xFFC8102E)),
              SizedBox(width: 8),
              Text('AI Assistant'),
            ],
          ),
          content: TextField(
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
      },
    );
  }

  void _showPaintCalculatorDialog() {
    final widthController = TextEditingController(text: '12');
    final heightController = TextEditingController(text: '10');
    double totalSqFt = 120;
    double litersNeeded = 1.7;
    int estimatedCostPkr = 3400;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void calculate() {
              final w = double.tryParse(widthController.text) ?? 0;
              final h = double.tryParse(heightController.text) ?? 0;
              final area = w * h;
              // 1 Liter covers ~70 sq ft with 2 coats
              final liters = area > 0 ? (area / 70.0) : 0.0;
              // Avg cost PKR 2000 per liter
              final cost = (liters * 2000).round();

              setDialogState(() {
                totalSqFt = area;
                litersNeeded = double.parse(liters.toStringAsFixed(1));
                estimatedCostPkr = cost;
              });
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.calculate, color: Color(0xFFC8102E)),
                  SizedBox(width: 10),
                  Text('Paint Calculator', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Enter Wall Dimensions (Feet):', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: widthController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          onChanged: (_) => calculate(),
                          decoration: InputDecoration(
                            labelText: 'Width (ft)',
                            labelStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.white.withOpacity(0.08),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: heightController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          onChanged: (_) => calculate(),
                          decoration: InputDecoration(
                            labelText: 'Height (ft)',
                            labelStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.white.withOpacity(0.08),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFC8102E).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFC8102E).withOpacity(0.4)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Total Wall Area:', style: TextStyle(color: Colors.white70)),
                            Text('${totalSqFt.toStringAsFixed(0)} sq ft', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Nippon Paint Required:', style: TextStyle(color: Colors.white70)),
                            Text('$litersNeeded Liters (2 coats)', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Est. Paint Cost:', style: TextStyle(color: Colors.white70)),
                            Text('PKR $estimatedCostPkr', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close', style: TextStyle(color: Colors.white70)),
                ),
              ],
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
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text(
          'Visualize',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        backgroundColor: const Color(0xFFC8102E),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.calculate, color: Colors.cyanAccent),
            onPressed: _showPaintCalculatorDialog,
            tooltip: 'Paint Calculator',
          ),
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: Colors.amber),
            onPressed: _showAIPromptDialog,
            tooltip: 'AI Assistant',
          ),
          IconButton(
            icon: Icon(
              _showMask ? Icons.visibility : Icons.visibility_off,
              color: _showMask ? Colors.greenAccent : Colors.white,
            ),
            onPressed: () {
              setState(() {
                _showMask = !_showMask;
              });
              _processImage();
            },
            tooltip: 'Toggle Mask View',
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
        ],
      ),
      body: Column(
        children: [
          // Persistent Always-Visible AI Conversation Bar at the top
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF1E1E1E),
              border: Border(bottom: BorderSide(color: Colors.white12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, color: Colors.amber, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _aiPromptController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: '✨ Talk to AI: "Change ceiling to blue" or "Paint wall red"...',
                      hintStyle: TextStyle(color: Colors.white54, fontSize: 12),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (val) {
                      if (val.trim().isNotEmpty) {
                        _handleAIPrompt(val);
                      }
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send_rounded, color: Color(0xFFC8102E), size: 20),
                  onPressed: () {
                    if (_aiPromptController.text.trim().isNotEmpty) {
                      _handleAIPrompt(_aiPromptController.text);
                    }
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: Colors.black,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return InteractiveViewer(
                    maxScale: 10.0,
                    panEnabled: !_showMask,
                    child: GestureDetector(
                      onTapUp: (details) =>
                          _onImageTapped(details, constraints),
                      onPanDown: (details) =>
                          _onMaskPanDown(details, constraints),
                      onPanUpdate: (details) =>
                          _onMaskPanUpdate(details, constraints),
                      onPanEnd: _onMaskPanEnd,
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
                          if (_showMask && _originalImage != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: ObjectBoundsPainter(
                                    _segmentationResult,
                                    _originalImage!.width,
                                    _originalImage!.height,
                                    _globalSelectionBox,
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

class ObjectBoundsPainter extends CustomPainter {
  final SubjectSegmentationResult? segmentationResult;
  final int imageWidth;
  final int imageHeight;
  final math.Rectangle<int>? selectionBox;

  ObjectBoundsPainter(this.segmentationResult, this.imageWidth, this.imageHeight, this.selectionBox);

  @override
  void paint(Canvas canvas, Size size) {
    final imageRatio = imageWidth / imageHeight;
    final widgetRatio = size.width / size.height;

    double renderWidth, renderHeight;
    double offsetX = 0, offsetY = 0;

    if (imageRatio > widgetRatio) {
      renderWidth = size.width;
      renderHeight = renderWidth / imageRatio;
      offsetY = (size.height - renderHeight) / 2;
    } else {
      renderHeight = size.height;
      renderWidth = renderHeight * imageRatio;
      offsetX = (size.width - renderWidth) / 2;
    }

    final scaleX = renderWidth / imageWidth;
    final scaleY = renderHeight / imageHeight;

    if (segmentationResult != null) {
      final subjectPaint = Paint()
        ..color = Colors.white38
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
        
      for (var subject in segmentationResult!.subjects) {
        final rect = Rect.fromLTWH(
          offsetX + subject.startX * scaleX,
          offsetY + subject.startY * scaleY,
          subject.width * scaleX,
          subject.height * scaleY,
        );
        canvas.drawRect(rect, subjectPaint);
      }
    }

    if (selectionBox != null) {
      final rect = Rect.fromLTWH(
        offsetX + selectionBox!.left * scaleX,
        offsetY + selectionBox!.top * scaleY,
        selectionBox!.width * scaleX,
        selectionBox!.height * scaleY,
      );
      
      final activePaint = Paint()
        ..color = Colors.greenAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;

      final bgPaint = Paint()
        ..color = Colors.greenAccent.withOpacity(0.2)
        ..style = PaintingStyle.fill;
        
      canvas.drawRect(rect, bgPaint);
      canvas.drawRect(rect, activePaint);
      
      final handlePaint = Paint()..color = Colors.white..style = PaintingStyle.fill;
      canvas.drawCircle(rect.centerLeft, 6, handlePaint);
      canvas.drawCircle(rect.centerRight, 6, handlePaint);
      canvas.drawCircle(rect.topCenter, 6, handlePaint);
      canvas.drawCircle(rect.bottomCenter, 6, handlePaint);
      
      final textSpan = const TextSpan(
        text: 'Selection Bounds',
        style: TextStyle(color: Colors.white, fontSize: 10, backgroundColor: Colors.black54),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(rect.left, rect.top - 14));
    }
  }

  @override
  bool shouldRepaint(covariant ObjectBoundsPainter oldDelegate) => true;
}
