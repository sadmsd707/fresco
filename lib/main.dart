import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'connection_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock to landscape
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  // Full-screen immersive
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const RobotControllerApp());
}

class RobotControllerApp extends StatelessWidget {
  const RobotControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Robot Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF00E5FF),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0A0E21),
        cardTheme: CardTheme(
          color: const Color(0xFF1A1F36),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 8,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00E5FF),
            foregroundColor: const Color(0xFF0A0E21),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xFF1A1F36),
          contentTextStyle: TextStyle(color: Colors.white70),
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const ConnectionPage(),
    );
  }
}
