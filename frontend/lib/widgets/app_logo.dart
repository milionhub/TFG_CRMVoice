import 'package:flutter/material.dart';

class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, this.size = 160});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      "assets/images/logoPNG.png",
      height: size,
      fit: BoxFit.contain,
    );
  }
}