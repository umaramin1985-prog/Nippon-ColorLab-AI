import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'editor_page.dart';

class SavedImagesPage extends StatefulWidget {
  const SavedImagesPage({super.key});

  @override
  State<SavedImagesPage> createState() => _SavedImagesPageState();
}

class _SavedImagesPageState extends State<SavedImagesPage> {
  List<File> _images = [];
  String _searchQuery = '';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    if (kIsWeb) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final savedDir = Directory('${docDir.path}/saved_images');
      if (await savedDir.exists()) {
        final files = savedDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.png') && !f.path.toLowerCase().endsWith('_orig.png'))
            .toList();
        files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
        setState(() {
          _images = files;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  void _deleteImage(File file) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111111),
        title: const Text('Delete Image', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to delete this saved project?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC8102E)),
            onPressed: () {
              try {
                final origFile = File(file.path.replaceAll(RegExp(r'\.png$', caseSensitive: false), '_orig.png'));
                if (origFile.existsSync()) {
                  origFile.deleteSync();
                }
              } catch (_) {}
              file.deleteSync();
              setState(() => _images.remove(file));
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredImages = _images.where((f) {
      final name = f.path.split(Platform.pathSeparator).last.toLowerCase();
      return name.contains(_searchQuery.toLowerCase());
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        title: const Text('Saved Projects', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        backgroundColor: const Color(0xFFC8102E),
        elevation: 0,
      ),
      body: Column(
        children: [
          if (!_isLoading && !kIsWeb && _images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search projects...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  prefixIcon: const Icon(Icons.search, color: Colors.white54),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (val) {
                  setState(() {
                    _searchQuery = val;
                  });
                },
              ),
            ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFFC8102E)))
                : _images.isEmpty
                    ? Center(
                        child: Text(
                          kIsWeb ? 'Saved projects are not supported on Web.' : 'No saved projects yet.',
                          style: const TextStyle(color: Colors.white70, fontSize: 16),
                        ),
                      )
                    : filteredImages.isEmpty
                        ? const Center(
                            child: Text('No projects match your search.', style: TextStyle(color: Colors.white70)),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                              childAspectRatio: 0.65,
                            ),
                            itemCount: filteredImages.length,
                            itemBuilder: (context, index) {
                              final file = filteredImages[index];
                              final fileName = file.path.split(Platform.pathSeparator).last.replaceAll('.png', '');
                              final date = file.lastModifiedSync();
                              final dateStr = '${date.day}/${date.month}/${date.year}';

                              return GestureDetector(
                                onTap: () {
                                  final origPath = file.path.replaceAll(RegExp(r'\.png$', caseSensitive: false), '_orig.png');
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => EditorPage(
                                        imagePath: file.path,
                                        originalImagePath: File(origPath).existsSync() ? origPath : null,
                                      ),
                                    ),
                                  );
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.05),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.white12),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(
                                        child: ClipRRect(
                                          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              Image.file(file, fit: BoxFit.cover),
                                              Positioned(
                                                top: 4,
                                                right: 4,
                                                child: Row(
                                                  children: [
                                                    GestureDetector(
                                                      onTap: () => Share.shareXFiles([XFile(file.path)], text: 'Check out my new room color!'),
                                                      child: Container(
                                                        padding: const EdgeInsets.all(4),
                                                        decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
                                                        child: const Icon(Icons.share, size: 14, color: Colors.white),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 4),
                                                    GestureDetector(
                                                      onTap: () => _deleteImage(file),
                                                      child: Container(
                                                        padding: const EdgeInsets.all(4),
                                                        decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
                                                        child: const Icon(Icons.delete, size: 14, color: Colors.white),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.all(8.0),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              fileName,
                                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              dateStr,
                                              style: const TextStyle(color: Colors.white54, fontSize: 10),
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
        ],
      ),
    );
  }
}
