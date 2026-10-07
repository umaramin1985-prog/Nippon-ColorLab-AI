import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'models.dart';
import 'login_page.dart';

class BrowseColorsPage extends StatefulWidget {
  final bool isPicker;
  const BrowseColorsPage({super.key, this.isPicker = false});

  @override
  State<BrowseColorsPage> createState() => _BrowseColorsPageState();
}

class _BrowseColorsPageState extends State<BrowseColorsPage> {
  String _searchQuery = '';
  String _selectedGroup = 'All';

  final List<String> _colorGroups = [
    'All',
    'Reds',
    'Oranges',
    'Yellows',
    'Greens',
    'Blues',
    'Purples',
    'Pinks',
    'Neutrals',
  ];

  String _getColorGroup(FandeckColor color) {
    final hsl = HSLColor.fromColor(color.color);
    final h = hsl.hue;
    final s = hsl.saturation;
    final l = hsl.lightness;

    if (l < 0.15 || (l > 0.85 && s < 0.15) || s < 0.15) return 'Neutrals';
    
    if (h >= 0 && h < 15) return 'Reds';
    if (h >= 15 && h < 45) return 'Oranges';
    if (h >= 45 && h < 75) return 'Yellows';
    if (h >= 75 && h < 165) return 'Greens';
    if (h >= 165 && h < 260) return 'Blues';
    if (h >= 260 && h < 315) return 'Purples';
    if (h >= 315 && h < 345) return 'Pinks';
    return 'Reds';
  }

  void _showColorDetails(FandeckColor color) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2C),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 50,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white38,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.color,
                  border: Border.all(color: Colors.white, width: 4),
                  boxShadow: [
                    BoxShadow(
                      color: color.color.withOpacity(0.5),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SelectableText(
                color.name,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: '#${color.hex}'));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('HEX Code copied to clipboard!'),
                      backgroundColor: Color(0xFFFF204E),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectableText(
                        'HEX: #${color.hex}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFFFF204E),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.copy, color: Color(0xFFFF204E), size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildColorValueStat('R', color.r.toString()),
                  _buildColorValueStat('G', color.g.toString()),
                  _buildColorValueStat('B', color.b.toString()),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  Widget _buildColorValueStat(String label, String value) {
    return Column(
      children: [
        SelectableText(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white54,
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Future<void> _shareCatalog() async {
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/Nippon_Colour_Catalogue.csv');
      
      final sb = StringBuffer();
      sb.writeln('Name,HEX,R,G,B');
      for (var c in globalFandeckColors) {
        sb.writeln('"${c.name}",#${c.hex},${c.r},${c.g},${c.b}');
      }
      
      await file.writeAsString(sb.toString());
      
      await Share.shareXFiles(
        [XFile(file.path)], 
        text: '🎨 Nippon Paint Complete Colour Catalogue',
        subject: 'Nippon Paint Colour Catalogue',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sharing catalog: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchQuery.toLowerCase().replaceAll('#', '');
    final filteredColors = globalFandeckColors.where((c) {
      final matchesSearch = c.name.toLowerCase().contains(query) || c.hex.toLowerCase().contains(query);
      final matchesGroup = _selectedGroup == 'All' || _getColorGroup(c) == _selectedGroup;
      return matchesSearch && matchesGroup;
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0B0C10),
      appBar: AppBar(
        title: const Text(
          'Colour Catalogue',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.share, color: Colors.white),
            tooltip: 'Share Catalogue',
            onPressed: _shareCatalog,
          ),
          if (!widget.isPicker)
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
      body: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0B0C10), Color(0xFF1E1E2C)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                TextField(
                  onChanged: (val) {
                    setState(() {
                      _searchQuery = val;
                    });
                  },
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search by name or hex...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.search, color: Colors.white54),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.05),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: const BorderSide(color: Color(0xFFFF204E)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _colorGroups.map((group) {
                      final isSelected = _selectedGroup == group;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: ChoiceChip(
                          label: Text(group),
                          selected: isSelected,
                          onSelected: (selected) {
                            if (selected) {
                              setState(() => _selectedGroup = group);
                            }
                          },
                          backgroundColor: Colors.white.withOpacity(0.05),
                          selectedColor: const Color(0xFFFF204E).withOpacity(0.2),
                          labelStyle: TextStyle(
                            color: isSelected ? const Color(0xFFFF204E) : Colors.white70,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                            side: BorderSide(
                              color: isSelected ? const Color(0xFFFF204E) : Colors.white.withOpacity(0.1),
                            ),
                          ),
                          showCheckmark: false,
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.8,
              ),
              itemCount: filteredColors.length,
              itemBuilder: (context, index) {
                final color = filteredColors[index];
                return _buildColorCard(color);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorCard(FandeckColor fandeckColor) {
    return GestureDetector(
      onTap: widget.isPicker
          ? () => Navigator.pop(context, fandeckColor)
          : () => _showColorDetails(fandeckColor),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2C),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: fandeckColor.color,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fandeckColor.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                      letterSpacing: 0.5,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'HEX: #${fandeckColor.hex}',
                    style: const TextStyle(color: Color(0xFFFF204E), fontSize: 9, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
