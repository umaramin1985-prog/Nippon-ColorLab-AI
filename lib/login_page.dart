import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'home_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with TickerProviderStateMixin {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  late AnimationController _animController;
  late Animation<double> _bgFadeAnimation;
  late Animation<double> _logoScaleAnimation;
  late Animation<Offset> _formSlideAnimation;
  late Animation<double> _formFadeAnimation;
  
  late AnimationController _bgFloatController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );

    _bgFloatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _bgFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: const Interval(0.0, 0.5, curve: Curves.easeIn)),
    );

    _logoScaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: const Interval(0.2, 0.7, curve: Curves.elasticOut)),
    );

    _formFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: const Interval(0.5, 1.0, curve: Curves.easeIn)),
    );

    _formSlideAnimation = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero).animate(
      CurvedAnimation(parent: _animController, curve: const Interval(0.5, 1.0, curve: Curves.easeOutCubic)),
    );

    _animController.forward();
  }

  @override
  void dispose() {
    _bgFloatController.dispose();
    _animController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _login() {
    final user = _usernameController.text;
    final pass = _passwordController.text;
    if (user == 'admin' && pass == 'umar18123') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid credentials')),
      );
    }
  }

  void _showSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final currentToken = prefs.getString('replicate_api_token') ?? '';
    final tokenController = TextEditingController(text: currentToken);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Developer Settings', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: tokenController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter Replicate API Token',
              hintStyle: const TextStyle(color: Colors.white54),
              filled: true,
              fillColor: Colors.white.withOpacity(0.1),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC8102E)),
              onPressed: () async {
                await prefs.setString('replicate_api_token', tokenController.text);
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('API Token saved successfully')),
                  );
                }
              },
              child: const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(color: const Color(0xFF0B0C10)),
          AnimatedBuilder(
            animation: _bgFloatController,
            builder: (context, child) {
              return SizedBox.expand(
                child: CustomPaint(
                  painter: PaintStrokePainter(_bgFloatController.value),
                ),
              );
            },
          ),
          BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(color: Colors.transparent),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32.0),
                child: FadeTransition(
                  opacity: _bgFadeAnimation,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      child: Container(
                        padding: const EdgeInsets.all(32.0),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E2C).withOpacity(0.6),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: Colors.white.withOpacity(0.1), width: 1.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.5),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                          ScaleTransition(
                            scale: _logoScaleAnimation,
                            child: GestureDetector(
                              onLongPress: _showSettingsDialog,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 10,
                                      offset: const Offset(0, 5),
                                    ),
                                  ],
                                ),
                                child: Image.asset(
                                  'assets/nippon_paint_logo.png',
                                  height: 60,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          ),
                          FadeTransition(
                            opacity: _formFadeAnimation,
                            child: SlideTransition(
                              position: _formSlideAnimation,
                              child: Column(
                                children: [
                                  const SizedBox(height: 16),
                                  const Text(
                                    'Nippon Paint',
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.white,
                                      letterSpacing: 1.5,
                                    ),
                                  ),
                                  const Text(
                                    'PAKISTAN',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                      color: Color(0xFFFF204E),
                                      letterSpacing: 5,
                                    ),
                                  ),
                                  const SizedBox(height: 48),
                                  TextField(
                                    controller: _usernameController,
                                    style: const TextStyle(color: Colors.white),
                                    decoration: InputDecoration(
                                      hintText: 'Username',
                                      hintStyle: const TextStyle(color: Colors.white38),
                                      prefixIcon: const Icon(Icons.person, color: Colors.white54),
                                      filled: true,
                                      fillColor: Colors.black.withOpacity(0.2),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(16),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  TextField(
                                    controller: _passwordController,
                                    style: const TextStyle(color: Colors.white),
                                    obscureText: true,
                                    decoration: InputDecoration(
                                      hintText: 'Password',
                                      hintStyle: const TextStyle(color: Colors.white38),
                                      prefixIcon: const Icon(Icons.lock, color: Colors.white54),
                                      filled: true,
                                      fillColor: Colors.black.withOpacity(0.2),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(16),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 32),
                                  SizedBox(
                                    width: double.infinity,
                                    height: 55,
                                    child: ElevatedButton(
                                      onPressed: _login,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFFF204E),
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(16),
                                        ),
                                        elevation: 8,
                                        shadowColor: const Color(0xFFFF204E).withOpacity(0.5),
                                      ),
                                      child: const Text(
                                        'LOGIN',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 1.5,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ), // closes ClipRRect
                ), // closes FadeTransition
              ), // closes SingleChildScrollView
            ), // closes Center
          ), // closes SafeArea
          const Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Powered by prynivo.com',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
          ],
        ),
    );
  }
}

class PaintStrokePainter extends CustomPainter {
  final double progress;
  PaintStrokePainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width == 0 || size.height == 0) return;

    final paint1 = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(size.width, size.height),
        [const Color(0xFFFF204E).withOpacity(0.6), const Color(0xFFC8102E).withOpacity(0.8)],
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 120.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path1 = Path();
    path1.moveTo(size.width * -0.1, size.height * 0.2);
    path1.quadraticBezierTo(size.width * 0.8, size.height * 0.1, size.width * 0.5, size.height * 0.5);
    path1.quadraticBezierTo(size.width * 0.1, size.height * 0.8, size.width * 1.1, size.height * 0.9);

    final metrics1 = path1.computeMetrics().toList();
    if (metrics1.isNotEmpty) {
      final m = metrics1.first;
      
      // Calculate a continuous sweeping wave (0 -> 1 -> 0)
      double wave = (math.sin(progress * 2 * math.pi - math.pi / 2) + 1) / 2; 
      
      final extract1 = m.extractPath(0.0, m.length * wave);
      canvas.drawPath(extract1, paint1);

      // Draw the Brush Icon at the leading edge
      final tangent = m.getTangentForOffset(m.length * wave);
      if (tangent != null) {
        final icon = Icons.brush;
        TextPainter textPainter = TextPainter(textDirection: TextDirection.ltr);
        textPainter.text = TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontSize: 70.0,
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            color: Colors.white.withOpacity(0.8),
            shadows: [
              Shadow(color: Colors.black.withOpacity(0.5), blurRadius: 10, offset: const Offset(0, 5)),
            ],
          ),
        );
        textPainter.layout();
        
        canvas.save();
        canvas.translate(tangent.position.dx, tangent.position.dy);
        
        // Rotate the brush slightly to match the stroke direction
        final angle = math.atan2(tangent.vector.dy, tangent.vector.dx);
        canvas.rotate(angle + math.pi / 4); // offset so brush points forward
        
        textPainter.paint(canvas, Offset(-textPainter.width / 2, -textPainter.height));
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant PaintStrokePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
