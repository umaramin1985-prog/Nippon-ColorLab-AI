import 'package:flutter/material.dart';

class ImageEditCommand {
  final String objectName;
  final Color targetColor;

  ImageEditCommand(this.objectName, this.targetColor);
}

class LitePromptParser {
  // A simple dictionary mapping color words to standard colors
  static final Map<String, Color> _colorDict = {
    'red': Colors.red,
    'blue': Colors.blue,
    'green': Colors.green,
    'yellow': Colors.yellow,
    'orange': Colors.orange,
    'purple': Colors.purple,
    'pink': Colors.pink,
    'black': Colors.black,
    'white': Colors.white,
    'grey': Colors.grey,
    'gray': Colors.grey,
    'brown': Colors.brown,
    'navy': const Color(0xFF000080),
    'cyan': Colors.cyan,
    'magenta': const Color(0xFFFF00FF),
    'teal': Colors.teal,
  };

  // Common verbs and filler words to ignore
  static final List<String> _ignoreWords = [
    'make', 'change', 'turn', 'recolor', 'paint', 'painting', 'the', 'to', 'into', 
    'a', 'an', 'color', 'colour', 'colors', 'colours', 'shade', 'please', 'room', 
    'in', 'with', 'of', 'my', 'our', 'this'
  ];

  static String _normalizeObjectName(String raw) {
    var text = raw.toLowerCase().trim();
    if (text.contains('sky') || text.contains('cloud')) return 'sky';
    if (text.contains('ceiling') || text.contains('roof')) return 'ceiling';
    if (text.contains('wall')) return 'wall';
    if (text.contains('floor') || text.contains('ground')) return 'floor';
    if (text.contains('sofa') || text.contains('couch')) return 'sofa';
    if (text.contains('door')) return 'door';
    if (text.contains('window')) return 'window';
    if (text.endsWith('s') && text.length > 3) {
      text = text.substring(0, text.length - 1);
    }
    return text.isEmpty ? 'wall' : text;
  }

  static List<ImageEditCommand> parse(String prompt) {
    final lowerPrompt = prompt.toLowerCase();
    
    // Split the prompt by conjunctions or punctuation to handle multiple requests
    // e.g. "make the wall red and the ceiling blue" -> ["make the wall red", "the ceiling blue"]
    final chunks = lowerPrompt.split(RegExp(r'\b(and|then|,|&)\b'));
    
    List<ImageEditCommand> commands = [];
    
    for (var chunk in chunks) {
      if (chunk.trim().isEmpty) continue;
      
      String? foundColorName;
      Color? foundColor;

      for (var entry in _colorDict.entries) {
        if (chunk.contains(entry.key)) {
          foundColorName = entry.key;
          foundColor = entry.value;
          break; // Match the first color found in this chunk
        }
      }

      if (foundColorName != null && foundColor != null) {
        String remainingText = chunk.replaceAll(foundColorName, ' ').trim();
        for (var word in _ignoreWords) {
          remainingText = remainingText.replaceAll(RegExp(r'\b' + word + r'\b'), ' ').trim();
        }

        remainingText = remainingText.replaceAll(RegExp(r'\s+'), ' ').trim();
        final normalized = _normalizeObjectName(remainingText);

        commands.add(ImageEditCommand(normalized, foundColor));
      }
    }
    
    // Fallback: If no commands were parsed with splitting, try parsing the whole prompt
    if (commands.isEmpty) {
      String? foundColorName;
      Color? foundColor;

      for (var entry in _colorDict.entries) {
        if (lowerPrompt.contains(entry.key)) {
          foundColorName = entry.key;
          foundColor = entry.value;
          break;
        }
      }
      
      if (foundColorName != null && foundColor != null) {
        String remainingText = lowerPrompt.replaceAll(foundColorName, ' ').trim();
        for (var word in _ignoreWords) {
          remainingText = remainingText.replaceAll(RegExp(r'\b' + word + r'\b'), ' ').trim();
        }
        remainingText = remainingText.replaceAll(RegExp(r'\s+'), ' ').trim();
        final normalized = _normalizeObjectName(remainingText);
        commands.add(ImageEditCommand(normalized, foundColor));
      }
    }

    return commands;
  }
}
