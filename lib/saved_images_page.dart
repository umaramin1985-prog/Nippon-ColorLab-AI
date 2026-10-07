import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class SavedImagesPage extends StatefulWidget {
  const SavedImagesPage({super.key});

  @override
  State<SavedImagesPage> createState() => _SavedImagesPageState();
}

class _SavedImagesPageState extends State<SavedImagesPage> {
  List<File> _images = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final savedDir = Directory('${docDir.path}/saved_images');
      if (await savedDir.exists()) {
        final files = savedDir.listSync().whereType<File>().where((f) => f.path.endsWith('.png')).toList();
        files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
        setState(() {
          _images = files;
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _deleteImage(File file) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Delete Image', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to delete this saved image?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC8102E)),
            onPressed: () {
              file.deleteSync();
              setState(() {
                _images.remove(file);
              });
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
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Saved Projects', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        backgroundColor: const Color(0xFFC8102E),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFC8102E)))
          : _images.isEmpty
              ? const Center(
                  child: Text(
                    'No saved images yet.',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.8,
                  ),
                  itemCount: _images.length,
                  itemBuilder: (context, index) {
                    final file = _images[index];
                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.5),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(file, fit: BoxFit.cover),
                            Positioned(
                              top: 8,
                              right: 8,
                              child: Row(
                                children: [
                                  GestureDetector(
                                    onTap: () {
                                      Share.shareXFiles([XFile(file.path)], text: 'Check out my new room color!');
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.6),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.share, size: 18, color: Colors.white),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: () => _deleteImage(file),
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.6),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.delete, size: 18, color: Colors.white),
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
    );
  }
}
