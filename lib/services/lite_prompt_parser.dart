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

  // Common verbs to ignore
  static final List<String> _ignoreWords = [
    'make', 'change', 'turn', 'recolor', 'paint', 'the', 'to', 'into', 'a', 'an'
  ];

  static ImageEditCommand? parse(String prompt) {
    final lowerPrompt = prompt.toLowerCase();
    
    // 1. Find the target color
    String? foundColorName;
    Color? foundColor;

    for (var entry in _colorDict.entries) {
      if (lowerPrompt.contains(entry.key)) {
        foundColorName = entry.key;
        foundColor = entry.value;
        break; // Match the first color found
      }
    }

    if (foundColorName == null || foundColor == null) {
      return null; // Could not determine color
    }

    // 2. Extract the object name
    // We remove the color word and common ignore words to find the object
    String remainingText = lowerPrompt.replaceAll(foundColorName, '').trim();
    for (var word in _ignoreWords) {
      // Use regex to remove whole words only
      remainingText = remainingText.replaceAll(RegExp(r'\b' + word + r'\b'), '').trim();
    }

    // Clean up multiple spaces
    remainingText = remainingText.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (remainingText.isEmpty) {
      remainingText = 'wall'; // Fallback if no specific object is mentioned
    }

    return ImageEditCommand(remainingText, foundColor);
  }
}
