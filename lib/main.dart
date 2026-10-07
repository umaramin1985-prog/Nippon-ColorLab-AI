import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:google_fonts/google_fonts.dart';
import 'login_page.dart';
import 'models.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    final jsonStr = await rootBundle.loadString('assets/colors.json');
    final List<dynamic> jsonList = jsonDecode(jsonStr);
    globalFandeckColors = jsonList
        .map((e) => FandeckColor.fromJson(e))
        .toList();
  } catch (e) {
    debugPrint("Failed to load fandeck colors: $e");
  }

  runApp(const RoomColorApp());
}

class RoomColorApp extends StatelessWidget {
  const RoomColorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nippon ColorLab AI',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFFFF204E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF204E),
          secondary: Color(0xFFFF204E),
          surface: Color(0xFF1E1E2C),
          background: Color(0xFF0B0C10),
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0C10),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
        ),
        useMaterial3: true,
      ),
      home: const LoginPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
