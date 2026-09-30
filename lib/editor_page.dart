import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'image_processor.dart';

enum EditType { tap, aiMask, stroke }
enum EditMode { magic, brush, eraser }

class EditorPage extends StatefulWidget {
  final String imagePath;
  const EditorPage({super.key, required this.imagePath});

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
  
  Color _targetColor = Colors.red;
  double _tolerance = 0.1;
  double _brushSize = 20.0;
  
  List<math.Point<int>> _taps = [];
  List<AIMask> _aiMasks = [];
  List<Stroke> _manualStrokes = [];
  List<EditType> _editHistory = [];

  double _sliderPosition = 0.5;
  
  EditMode _currentMode = EditMode.magic;
  bool _showMask = false;
  
  Stroke? _currentStroke;

  late final SubjectSegmenter _segmenter;
  SubjectSegmentationResult? _segmentationResult;

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
    super.dispose();
  }

  Future<void> _loadImage() async {
    final bytes = await File(widget.imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    
    try {
      if (Platform.isAndroid || Platform.isIOS) {
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
        _isLoading = false;
      });
    }
  }
  
  math.Point<int>? _getPointFromLocalPosition(Offset localPosition, BoxConstraints constraints) {
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
    
    if (localPosition.dx < offsetX || localPosition.dx > offsetX + renderWidth ||
        localPosition.dy < offsetY || localPosition.dy > offsetY + renderHeight) {
      return null;
    }

    final x = ((localPosition.dx - offsetX) / renderWidth * _originalImage!.width).toInt();
    final y = ((localPosition.dy - offsetY) / renderHeight * _originalImage!.height).toInt();
    
    return math.Point(x, y);
  }

  void _onImageTapped(TapUpDetails details, BoxConstraints constraints) {
    if (_currentMode != EditMode.magic) return;
    
    final pt = _getPointFromLocalPosition(details.localPosition, constraints);
    if (pt == null) return;

    bool foundAISubject = false;

    if (_segmentationResult != null) {
      for (var subject in _segmentationResult!.subjects) {
        if (pt.x >= subject.startX && pt.x < subject.startX + subject.width &&
            pt.y >= subject.startY && pt.y < subject.startY + subject.height) {
          
          int localX = pt.x - subject.startX;
          int localY = pt.y - subject.startY;
          int idx = localY * subject.width + localX;
          
          if (subject.confidenceMask != null && subject.confidenceMask![idx] > 0.5) {
            setState(() {
              _aiMasks.add(AIMask(
                subject.confidenceMask!,
                subject.startX,
                subject.startY,
                subject.width,
                subject.height,
              ));
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

    _processImage();
  }
  
  void _onPanStart(DragStartDetails details, BoxConstraints constraints) {
    if (_currentMode == EditMode.magic) return;
    final pt = _getPointFromLocalPosition(details.localPosition, constraints);
    if (pt != null) {
      _currentStroke = Stroke([pt], _brushSize, _currentMode == EditMode.eraser);
    }
  }
  
  void _onPanUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (_currentMode == EditMode.magic || _currentStroke == null) return;
    final pt = _getPointFromLocalPosition(details.localPosition, constraints);
    if (pt != null) {
      _currentStroke!.points.add(pt);
    }
  }
  
  void _onPanEnd(DragEndDetails details) {
    if (_currentMode == EditMode.magic || _currentStroke == null) return;
    setState(() {
      _manualStrokes.add(_currentStroke!);
      _editHistory.add(EditType.stroke);
      _currentStroke = null;
    });
    _processImage();
  }

  void _undoLast() {
    if (_editHistory.isEmpty) return;
    
    setState(() {
      final last = _editHistory.removeLast();
      if (last == EditType.tap) {
        if (_taps.isNotEmpty) _taps.removeLast();
      } else if (last == EditType.aiMask) {
        if (_aiMasks.isNotEmpty) _aiMasks.removeLast();
      } else if (last == EditType.stroke) {
        if (_manualStrokes.isNotEmpty) _manualStrokes.removeLast();
      }
    });
    
    _processImage();
  }

  Future<void> _processImage() async {
    if (_originalImage == null) return;
    if (_taps.isEmpty && _aiMasks.isEmpty && _manualStrokes.isEmpty) {
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
      manualStrokes: _manualStrokes,
      targetColor: _targetColor,
      tolerance: _tolerance,
      showMaskOverlay: _showMask,
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
          title: const Text('Pick a color'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: _targetColor,
              onColorChanged: (color) {
                _targetColor = color;
              },
              pickerAreaHeightPercent: 0.8,
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Got it'),
              onPressed: () {
                Navigator.of(context).pop();
                _processImage();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Editor'),
        actions: [
          IconButton(
            icon: Icon(_showMask ? Icons.visibility : Icons.visibility_off, 
              color: _showMask ? Colors.greenAccent : Colors.white),
            onPressed: () {
              setState(() {
                _showMask = !_showMask;
              });
              _processImage();
            },
            tooltip: 'Toggle Mask View (Neon Green)',
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
                _manualStrokes.clear();
                _editHistory.clear();
              });
              _processImage();
            },
            tooltip: 'Clear Selection',
          ),
          IconButton(
            icon: const Icon(Icons.color_lens),
            onPressed: _showColorPicker,
            tooltip: 'Pick Color',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: SegmentedButton<EditMode>(
              segments: const [
                ButtonSegment(value: EditMode.magic, icon: Icon(Icons.auto_fix_high), label: Text('Magic')),
                ButtonSegment(value: EditMode.brush, icon: Icon(Icons.brush), label: Text('Brush')),
                ButtonSegment(value: EditMode.eraser, icon: Icon(Icons.dry_cleaning), label: Text('Eraser')),
              ],
              selected: {_currentMode},
              onSelectionChanged: (Set<EditMode> selection) {
                setState(() {
                  _currentMode = selection.first;
                });
              },
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return InteractiveViewer(
                  maxScale: 10.0,
                  panEnabled: _currentMode == EditMode.magic,
                  child: GestureDetector(
                    onTapUp: (details) => _onImageTapped(details, constraints),
                    onPanStart: (details) => _onPanStart(details, constraints),
                    onPanUpdate: (details) => _onPanUpdate(details, constraints),
                    onPanEnd: _onPanEnd,
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
                              _sliderPosition += details.delta.dx / constraints.maxWidth;
                              _sliderPosition = _sliderPosition.clamp(0.0, 1.0);
                            });
                          },
                          child: Container(
                            width: 30,
                            color: Colors.transparent,
                            child: Center(
                              child: Container(
                                width: 2,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: constraints.maxWidth * _sliderPosition - 12,
                        top: constraints.maxHeight / 2 - 12,
                        child: IgnorePointer(
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(color: Colors.black26, blurRadius: 4)
                              ]
                            ),
                            child: const Icon(Icons.code, size: 16, color: Colors.black),
                          ),
                        ),
                      ),
                      if (_isProcessing)
                        const Center(
                          child: CircularProgressIndicator(),
                        ),
                    ],
                  ),
                ));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_currentMode == EditMode.magic) ...[
                  Row(
                    children: [
                      const Text('Tolerance:'),
                      Expanded(
                        child: Slider(
                          value: _tolerance,
                          min: 0.01,
                          max: 1.0,
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
                      Text((_tolerance * 100).toStringAsFixed(0) + '%'),
                    ],
                  ),
                ] else ...[
                  Row(
                    children: [
                      const Text('Brush Size:'),
                      Expanded(
                        child: Slider(
                          value: _brushSize,
                          min: 5.0,
                          max: 100.0,
                          onChanged: (value) {
                            setState(() {
                              _brushSize = value;
                            });
                          },
                        ),
                      ),
                      Text(_brushSize.toStringAsFixed(0) + 'px'),
                    ],
                  ),
                ]
              ],
            ),
          ),
        ],
      ),
    );
  }
}
