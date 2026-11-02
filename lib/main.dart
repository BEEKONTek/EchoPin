import 'package:echo_pin/screens/home_screen.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const EchoPinApp());
}

class EchoPinApp extends StatelessWidget {
  const EchoPinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EchoPin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
