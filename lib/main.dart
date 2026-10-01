import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
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
        primaryColor: const Color(0xFFC8102E),
        primarySwatch: Colors.red,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      home: const LoginPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
