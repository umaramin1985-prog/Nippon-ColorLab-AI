import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'image_processor.dart';
import 'models.dart';
import 'login_page.dart';

class GeneratedVariation {
  final FandeckColor fandeckColor;
  final Uint8List imageBytes;
  final img.Image imageObj;

  GeneratedVariation({
    required this.fandeckColor,
    required this.imageBytes,
    required this.imageObj,
  });
}

class AutoShowcasePage extends StatefulWidget {
  const AutoShowcasePage({super.key});

  @override
  State<AutoShowcasePage> createState() => _AutoShowcasePageState();
}

class _AutoShowcasePageState extends State<AutoShowcasePage> {
  XFile? _selectedFile;
  img.Image? _originalImage;
  Uint8List? _originalBytes;
  bool _isLoadingImage = false;
  int _currentIndex = 0;
  final PageController _pageController = PageController();

  List<FandeckColor> _colorsList = [];
  final Map<int, GeneratedVariation> _variationCache = {};
  final Set<int> _generatingIndices = {};

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source);
    if (picked != null) {
      setState(() {
        _selectedFile = picked;
        _isLoadingImage = true;
        _variationCache.clear();
        _generatingIndices.clear();
        _currentIndex = 0;
      });

      await _initImageAndColors();
    }
  }

  Future<void> _loadSampleRoomDemo() async {
    setState(() {
      _isLoadingImage = true;
      _variationCache.clear();
      _generatingIndices.clear();
      _currentIndex = 0;
    });

    final sampleImg = img.Image(width: 600, height: 400);
    // Wall background
    for (int y = 0; y < 280; y++) {
      for (int x = 0; x < 600; x++) {
        sampleImg.setPixelRgb(x, y, 220, 220, 220);
      }
    }
    // Wooden Floor
    for (int y = 280; y < 400; y++) {
      for (int x = 0; x < 600; x++) {
        sampleImg.setPixelRgb(x, y, 110, 75, 45);
      }
    }
    // Navy Sofa
    for (int y = 220; y < 330; y++) {
      for (int x = 180; x < 420; x++) {
        sampleImg.setPixelRgb(x, y, 40, 40, 80);
      }
    }

    _originalImage = sampleImg;
    _originalBytes = img.encodeJpg(sampleImg);
    _selectedFile = XFile.fromData(_originalBytes!, name: 'sample_room.jpg');

    _colorsList = globalFandeckColors.isNotEmpty
        ? globalFandeckColors
        : [
            FandeckColor(name: 'Nippon Crimson', r: 200, g: 16, b: 46, hex: 'C8102E'),
            FandeckColor(name: 'Royal Ocean Blue', r: 0, g: 51, b: 102, hex: '003366'),
            FandeckColor(name: 'Nordic Sage Green', r: 108, g: 122, b: 137, hex: '6C7A89'),
            FandeckColor(name: 'Pearl Warm White', r: 245, g: 245, b: 220, hex: 'F5F5DC'),
            FandeckColor(name: 'Sunset Terracotta', r: 211, g: 84, b: 0, hex: 'D35400'),
          ];

    setState(() {
      _isLoadingImage = false;
    });

    _generateVariationForIndex(0);
  }

  Future<void> _initImageAndColors() async {
    if (_selectedFile == null) return;
    try {
      final bytes = await _selectedFile!.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return;

      _originalImage = decoded;
      _originalBytes = bytes;

      _colorsList = globalFandeckColors.isNotEmpty
          ? globalFandeckColors
          : [
              FandeckColor(name: 'Nippon Crimson', r: 200, g: 16, b: 46, hex: 'C8102E'),
              FandeckColor(name: 'Royal Ocean Blue', r: 0, g: 51, b: 102, hex: '003366'),
              FandeckColor(name: 'Nordic Sage Green', r: 108, g: 122, b: 137, hex: '6C7A89'),
              FandeckColor(name: 'Pearl Warm White', r: 245, g: 245, b: 220, hex: 'F5F5DC'),
              FandeckColor(name: 'Sunset Terracotta', r: 211, g: 84, b: 0, hex: 'D35400'),
              FandeckColor(name: 'Golden Yellow', r: 255, g: 215, b: 0, hex: 'FFD700'),
              FandeckColor(name: 'Charcoal Grey', r: 50, g: 50, b: 50, hex: '323232'),
            ];

      setState(() {
        _isLoadingImage = false;
      });

      // Lazy generate index 0 on start
      _generateVariationForIndex(0);
    } catch (e) {
      debugPrint("Error initializing image: $e");
      setState(() {
        _isLoadingImage = false;
      });
    }
  }

  List<math.Point<int>> _detectBackgroundWallSeeds(img.Image image) {
    final w = image.width;
    final h = image.height;
    final candidates = [
      math.Point((w * 0.15).toInt(), (h * 0.15).toInt()),
      math.Point((w * 0.35).toInt(), (h * 0.15).toInt()),
      math.Point((w * 0.50).toInt(), (h * 0.15).toInt()),
      math.Point((w * 0.65).toInt(), (h * 0.15).toInt()),
      math.Point((w * 0.85).toInt(), (h * 0.15).toInt()),
      math.Point((w * 0.25).toInt(), (h * 0.30).toInt()),
      math.Point((w * 0.50).toInt(), (h * 0.30).toInt()),
      math.Point((w * 0.75).toInt(), (h * 0.30).toInt()),
      math.Point((w * 0.50).toInt(), (h * 0.45).toInt()),
    ];

    final validWallSeeds = <math.Point<int>>[];
    for (final pt in candidates) {
      if (pt.x >= 0 && pt.x < w && pt.y >= 0 && pt.y < h) {
        final p = image.getPixel(pt.x, pt.y);
        final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        if (lum > 30 && lum < 245) {
          validWallSeeds.add(pt);
        }
      }
    }

    return validWallSeeds.isNotEmpty ? validWallSeeds : candidates;
  }

  Future<void> _generateVariationForIndex(int index) async {
    if (_originalImage == null || index < 0 || index >= _colorsList.length) return;
    if (_variationCache.containsKey(index) || _generatingIndices.contains(index)) return;

    setState(() {
      _generatingIndices.add(index);
    });

    try {
      final fandeckColor = _colorsList[index];
      final wallSeeds = _detectBackgroundWallSeeds(_originalImage!);

      final params = ProcessImageParams(
        image: _originalImage!,
        taps: wallSeeds,
        targetColor: fandeckColor.color,
        tolerance: 0.28,
      );

      final processed = await processImage(params);
      final resultBytes = img.encodeJpg(processed);

      final variation = GeneratedVariation(
        fandeckColor: fandeckColor,
        imageBytes: resultBytes,
        imageObj: processed,
      );

      if (mounted) {
        setState(() {
          _variationCache[index] = variation;
          _generatingIndices.remove(index);
        });
      }
    } catch (e) {
      debugPrint("Error generating variation for index $index: $e");
      if (mounted) {
        setState(() {
          _generatingIndices.remove(index);
        });
      }
    }
  }

  bool _isFavorite(FandeckColor fandeckColor) {
    final favId = '${_selectedFile?.path}_${fandeckColor.hex}';
    return globalFavoriteRooms.any((fav) => fav.id == favId);
  }

  void _toggleFavorite(int index) {
    final variation = _variationCache[index];
    final fandeckColor = _colorsList[index];
    if (variation == null) return;

    final favId = '${_selectedFile?.path}_${fandeckColor.hex}';
    final existingIndex = globalFavoriteRooms.indexWhere((fav) => fav.id == favId);

    setState(() {
      if (existingIndex >= 0) {
        globalFavoriteRooms.removeAt(existingIndex);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed ${fandeckColor.name} from Favorites ❤️'),
            duration: const Duration(seconds: 1),
          ),
        );
      } else {
        globalFavoriteRooms.add(
          FavoriteRoom(
            id: favId,
            fandeckColor: fandeckColor,
            imageBytes: variation.imageBytes,
            savedAt: DateTime.now(),
          ),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved ${fandeckColor.name} to Favorites ❤️'),
            backgroundColor: const Color(0xFFC8102E),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });
  }

  void _showEnlargedDialog(int index) {
    final variation = _variationCache[index];
    final fandeckColor = _colorsList[index];
    if (variation == null) return;

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(12),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBar(
                  title: Text(
                    fandeckColor.name,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  backgroundColor: const Color(0xFFC8102E),
                  elevation: 0,
                  automaticallyImplyLeading: false,
                  actions: [
                    IconButton(
                      icon: Icon(
                        _isFavorite(fandeckColor) ? Icons.favorite : Icons.favorite_border,
                        color: _isFavorite(fandeckColor) ? Colors.redAccent : Colors.white,
                      ),
                      onPressed: () {
                        _toggleFavorite(index);
                        Navigator.pop(context);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                ClipRRect(
                  child: Image.memory(
                    variation.imageBytes,
                    fit: BoxFit.contain,
                    height: 400,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: fandeckColor.color,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            fandeckColor.name,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Text(
                        'HEX: #${fandeckColor.hex}',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text(
          'Auto Colour Showcase',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1),
        ),
        backgroundColor: const Color(0xFFC8102E),
        elevation: 0,
        actions: [
          if (_selectedFile != null)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white),
              tooltip: 'Upload New Image',
              onPressed: () => _pickImage(ImageSource.gallery),
            ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            tooltip: 'Logout',
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const LoginPage()),
              );
            },
          ),
        ],
      ),
      body: _selectedFile == null
          ? Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.05),
                        border: Border.all(
                          color: const Color(0xFFC8102E).withOpacity(0.4),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFC8102E).withOpacity(0.15),
                            blurRadius: 20,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.collections,
                        size: 70,
                        color: Color(0xFFC8102E),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Auto Paint Showcase',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        'Upload a room photo to preview Nippon Paint colors pre-applied on-demand! Swipe left & right to browse shades seamlessly.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ),
                    const SizedBox(height: 36),
                    SizedBox(
                      width: 250,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: () => _pickImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library, color: Colors.white),
                        label: const Text(
                          'Upload Room Photo',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFC8102E),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 6,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: 250,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt, color: Colors.white),
                        label: const Text(
                          'Take Room Photo',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2A2A2A),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(color: Colors.white.withOpacity(0.15)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: _loadSampleRoomDemo,
                      icon: const Icon(Icons.play_circle_fill, color: Colors.amber),
                      label: const Text(
                        'Try Sample Room Demo',
                        style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.amber, width: 1.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : _isLoadingImage
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(color: Color(0xFFC8102E)),
                      SizedBox(height: 20),
                      Text(
                        'Loading Image...',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Top Header Bar with Shade Name & ❤️ Favorite Button
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      color: const Color(0xFF1E1E1E),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: _colorsList[_currentIndex].color,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _colorsList[_currentIndex].name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                  Text(
                                    'HEX: #${_colorsList[_currentIndex].hex} (${_currentIndex + 1}/${_colorsList.length})',
                                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          // Top Header ❤️ Love / Favorite Button
                          IconButton(
                            icon: Icon(
                              _isFavorite(_colorsList[_currentIndex])
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: _isFavorite(_colorsList[_currentIndex])
                                  ? Colors.redAccent
                                  : Colors.white,
                              size: 28,
                            ),
                            tooltip: 'Love / Save to Favorites',
                            onPressed: () => _toggleFavorite(_currentIndex),
                          ),
                        ],
                      ),
                    ),
                    // Swipeable PageView with On-Demand Lazy Generation
                    Expanded(
                      child: PageView.builder(
                        controller: _pageController,
                        itemCount: _colorsList.length,
                        onPageChanged: (idx) {
                          setState(() {
                            _currentIndex = idx;
                          });
                          // Lazy generate current, previous, and next page
                          _generateVariationForIndex(idx);
                          _generateVariationForIndex(idx + 1);
                          if (idx > 0) _generateVariationForIndex(idx - 1);
                        },
                        itemBuilder: (context, index) {
                          final cached = _variationCache[index];
                          final isGenerating = _generatingIndices.contains(index);

                          if (cached != null) {
                            return GestureDetector(
                              onTap: () => _showEnlargedDialog(index),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  InteractiveViewer(
                                    maxScale: 4.0,
                                    child: Image.memory(
                                      cached.imageBytes,
                                      fit: BoxFit.contain,
                                      width: double.infinity,
                                      height: double.infinity,
                                    ),
                                  ),
                                  Positioned(
                                    bottom: 12,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: const Row(
                                        children: [
                                          Icon(Icons.swipe, color: Colors.white70, size: 16),
                                          SizedBox(width: 6),
                                          Text(
                                            'Swipe Left/Right or Tap to Enlarge',
                                            style: TextStyle(color: Colors.white, fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }

                          // Trigger lazy generation if not started yet
                          if (!isGenerating) {
                            _generateVariationForIndex(index);
                          }

                          // Render progress indicator while lazy generating
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const CircularProgressIndicator(color: Color(0xFFC8102E)),
                                const SizedBox(height: 16),
                                Text(
                                  'Applying ${_colorsList[index].name}...',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Preserving 3D lighting & textures',
                                  style: TextStyle(color: Colors.white54, fontSize: 12),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    // Bottom Horizontal Scrollable Color Carousel
                    Container(
                      height: 95,
                      color: const Color(0xFF191919),
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _colorsList.length,
                        itemBuilder: (context, index) {
                          final isSelected = index == _currentIndex;
                          final c = _colorsList[index];
                          final isCached = _variationCache.containsKey(index);

                          return GestureDetector(
                            onTap: () {
                              _pageController.animateToPage(
                                index,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 65,
                              margin: const EdgeInsets.symmetric(horizontal: 5),
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2A2A2A),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected ? const Color(0xFFC8102E) : Colors.white12,
                                  width: isSelected ? 2.5 : 1.0,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: Stack(
                                      alignment: Alignment.topRight,
                                      children: [
                                        Container(
                                          decoration: BoxDecoration(
                                            color: c.color,
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                        ),
                                        if (isCached)
                                          Positioned(
                                            top: 2,
                                            right: 2,
                                            child: Container(
                                              width: 6,
                                              height: 6,
                                              decoration: const BoxDecoration(
                                                color: Colors.greenAccent,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    c.name,
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      color: isSelected ? Colors.white : Colors.white60,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
    );
  }
}
