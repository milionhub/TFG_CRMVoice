import 'package:flutter/material.dart';

import '../widgets/shell/app_shell.dart';
import 'home_content.dart';

// La navegación principal vive en el shell (I.2). Se reexporta aquí porque
// las pantallas de sección y los tests la importan desde home_screen.dart.
export '../widgets/shell/app_shell.dart'
    show AppShell, MobileDrawer, Sidebar, SidebarState, sectionScreen;

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppShell(currentIndex: 0, body: HomeContent());
  }
}
