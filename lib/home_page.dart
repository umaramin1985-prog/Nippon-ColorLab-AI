import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'editor_page.dart';
import 'browse_colors_page.dart';
import 'auto_showcase_page.dart';
import 'favorites_page.dart';
import 'login_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      const _VisualizeTab(),
      const AutoShowcasePage(),
      const FavoritesPage(),
      const BrowseColorsPage(),
      const _InspirationTab(),
    ];

    return Scaffold(
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: pages[_currentIndex],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        backgroundColor: const Color(0xFF1E1E1E),
        selectedItemColor: const Color(0xFFC8102E),
        unselectedItemColor: Colors.white54,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.format_paint),
            label: 'Visualize',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.collections),
            label: 'Auto Paint',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.favorite),
            label: 'Favorites',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.color_lens),
            label: 'Colours',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.lightbulb),
            label: 'Ideas',
          ),
        ],
      ),
    );
  }
}

class _VisualizeTab extends StatelessWidget {
  const _VisualizeTab();

  Future<void> _pickImage(BuildContext context, ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);
    if (pickedFile != null) {
      if (context.mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => EditorPage(
              imagePath: pickedFile.path,
              imageFile: pickedFile,
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Visualize Your Space',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFFC8102E),
        elevation: 10,
        shadowColor: const Color(0xFFC8102E).withOpacity(0.5),
        actions: [
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
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1E1E1E), Color(0xFF121212)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.05),
                border: Border.all(
                  color: const Color(0xFFC8102E).withOpacity(0.3),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFC8102E).withOpacity(0.1),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: const Icon(
                Icons.format_paint,
                size: 80,
                color: Color(0xFFC8102E),
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Select an image to start recoloring',
              style: TextStyle(
                fontSize: 18,
                color: Colors.white70,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 48),
            _buildActionBtn(
              context,
              icon: Icons.photo_library,
              label: 'Pick from Gallery',
              source: ImageSource.gallery,
            ),
            const SizedBox(height: 16),
            _buildActionBtn(
              context,
              icon: Icons.camera_alt,
              label: 'Take a Photo',
              source: ImageSource.camera,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionBtn(
    BuildContext context, {
    required IconData icon,
    required String label,
    required ImageSource source,
  }) {
    return SizedBox(
      width: 250,
      height: 55,
      child: ElevatedButton.icon(
        onPressed: () => _pickImage(context, source),
        icon: Icon(icon, size: 24),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF2A2A2A),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          elevation: 5,
        ),
      ),
    );
  }
}

class _InspirationTab extends StatelessWidget {
  const _InspirationTab();

  @override
  Widget build(BuildContext context) {
    final inspirations = [
      {
        'title': 'Royal Living Room',
        'category': 'Living Room',
        'icon': Icons.weekend,
        'gradient': [const Color(0xFF1E3C72), const Color(0xFF2A5298)],
        'colors': [const Color(0xFF003366), const Color(0xFFD4AF37), const Color(0xFFF5F5DC)],
        'shade': 'Deep Royal Blue & Gold'
      },
      {
        'title': 'Nordic Bedroom',
        'category': 'Bedroom',
        'icon': Icons.bed,
        'gradient': [const Color(0xFF2C3E50), const Color(0xFF4CA1AF)],
        'colors': [const Color(0xFF6C7A89), const Color(0xFFE6E6FA), const Color(0xFFF0F8FF)],
        'shade': 'Muted Sage & Pearl'
      },
      {
        'title': 'Warm Dining Haven',
        'category': 'Dining Room',
        'icon': Icons.restaurant,
        'gradient': [const Color(0xFFD31027), const Color(0xFFEA384D)],
        'colors': [const Color(0xFFC8102E), const Color(0xFFFFF8DC), const Color(0xFF8B4513)],
        'shade': 'Nippon Crimson & Cream'
      },
      {
        'title': 'Executive Office',
        'category': 'Workspace',
        'icon': Icons.business_center,
        'gradient': [const Color(0xFF3A6073), const Color(0xFF3A7BD5)],
        'colors': [const Color(0xFF2F4F4F), const Color(0xFFB0C4DE), const Color(0xFFFFFFFF)],
        'shade': 'Slate Grey & Steel'
      },
      {
        'title': 'Cozy Sunlight Lounge',
        'category': 'Lounge',
        'icon': Icons.wb_sunny,
        'gradient': [const Color(0xFFF7971E), const Color(0xFFFFD200)],
        'colors': [const Color(0xFFFFA500), const Color(0xFFFFFDD0), const Color(0xFF808000)],
        'shade': 'Warm Sunset Gold'
      },
      {
        'title': 'Modern Minimalist Kitchen',
        'category': 'Kitchen',
        'icon': Icons.kitchen,
        'gradient': [const Color(0xFF434343), const Color(0xFF000000)],
        'colors': [const Color(0xFF1F1F1F), const Color(0xFFE0E0E0), const Color(0xFF9E9E9E)],
        'shade': 'Charcoal & Crisp White'
      },
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text(
          'Colour Inspiration',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1),
        ),
        backgroundColor: const Color(0xFFC8102E),
        elevation: 0,
        actions: [
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
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: inspirations.length,
        itemBuilder: (context, index) {
          final item = inspirations[index];
          final List<Color> colors = item['colors'] as List<Color>;
          final List<Color> gradient = item['gradient'] as List<Color>;

          return Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: gradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(item['icon'] as IconData, color: Colors.white, size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['title'] as String,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              item['shade'] as String,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white.withOpacity(0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text(
                        'Palette: ',
                        style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 8),
                      ...colors.map(
                        (c) => Container(
                          margin: const EdgeInsets.only(right: 8),
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(color: Colors.black26, blurRadius: 4),
                            ],
                          ),
                        ),
                      ),
                    ],
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
