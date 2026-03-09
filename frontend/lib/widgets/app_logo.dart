import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/images/voice_logo.svg',
      height: size,
    );
  }
}