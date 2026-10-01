import 'package:flutter/material.dart';

class FandeckColor {
  final String name;
  final int r;
  final int g;
  final int b;
  final String hex;

  FandeckColor({
    required this.name,
    required this.r,
    required this.g,
    required this.b,
    required this.hex,
  });

  factory FandeckColor.fromJson(Map<String, dynamic> json) {
    return FandeckColor(
      name: json['NAME']?.toString() ?? 'Unknown',
      r: int.tryParse(json['R']?.toString() ?? '0') ?? 0,
      g: int.tryParse(json['G']?.toString() ?? '0') ?? 0,
      b: int.tryParse(json['B']?.toString() ?? '0') ?? 0,
      hex: json['Hex']?.toString() ?? '',
    );
  }

  Color get color => Color.fromARGB(255, r, g, b);
}

List<FandeckColor> globalFandeckColors = [];
