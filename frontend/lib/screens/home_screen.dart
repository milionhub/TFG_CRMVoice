import 'package:flutter/material.dart';
import 'home_content.dart';
import '../widgets/app_logo.dart';
import '../providers/auth_provider.dart';
import 'package:provider/provider.dart';
import 'history_screen.dart';
import 'calendar_screen.dart';
import 'chat_screen.dart';
import '../core/app_colors.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 800;

    if (isMobile) {
      return const _MobileLayout();
    } else {
      return const _DesktopLayout();
    }
  }
}

class _DesktopLayout extends StatelessWidget {
  const _DesktopLayout();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        children: [
          const _Sidebar(),
          const Expanded(
            child: SafeArea(
              child: _DesktopContentWrapper(),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopContentWrapper extends StatelessWidget {
  const _DesktopContentWrapper();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [

        /// HEADER
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          child: Row(
            
            children: [

              const Spacer(),
              
              Consumer<AuthProvider>(
                builder: (context, auth, _) {
                  final email = auth.user?["email"] ?? "";
                  final initial =
                      email.isNotEmpty ? email[0].toUpperCase() : "";

                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: AppColors.primary,
                          child: Text(
                            initial,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          email,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () async {
                            await context.read<AuthProvider>().logout();
                          },
                          child: const Icon(
                            Icons.logout_rounded,
                            size: 18,
                            color: AppColors.textSecondary,
                          ),
                        )
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),

        /// CONTENIDO REAL
        const Expanded(
          child: HomeContent(),
        ),
      ],
    );
  }
}

class _MobileLayout extends StatelessWidget {
  const _MobileLayout();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: const AppLogo(size: 28),
      ),
      drawer: const _MobileDrawer(),
      body: const SafeArea(
        child: HomeContent(),
      ),
    );
  }
}

class _Sidebar extends StatefulWidget {
  const _Sidebar();

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  int selectedIndex = 0;

  void _navigate(int index, BuildContext context) {
    setState(() {
      selectedIndex = index;
    });

    switch (index) {
      case 1:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const HistoryScreen()),
        );
        break;
      case 2:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CalendarScreen()),
        );
        break;
      case 3:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ChatScreen()),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(vertical: 32),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(
            color: Color(0xFFE8EDF3),
          ),
        ),
      ),
      child: Column(
        children: [
          const AppLogo(size: 44),
          const SizedBox(height: 48),

          _PremiumSidebarItem(
            icon: Icons.home_rounded,
            label: "Inicio",
            selected: selectedIndex == 0,
            onTap: () => _navigate(0, context),
          ),
          _PremiumSidebarItem(
            icon: Icons.menu_book_rounded,
            label: "Histórico",
            selected: selectedIndex == 1,
            onTap: () => _navigate(1, context),
          ),
          _PremiumSidebarItem(
            icon: Icons.calendar_month_rounded,
            label: "Calendario",
            selected: selectedIndex == 2,
            onTap: () => _navigate(2, context),
          ),
          _PremiumSidebarItem(
            icon: Icons.chat_bubble_outline_rounded,
            label: "Chat IA",
            selected: selectedIndex == 3,
            onTap: () => _navigate(3, context),
          ),

          const Spacer(),

          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () {
                context.read<AuthProvider>().logout();
              },
            ),
          )
        ],
      ),
    );
  }
}

class _PremiumSidebarItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PremiumSidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_PremiumSidebarItem> createState() => _PremiumSidebarItemState();
}

class _PremiumSidebarItemState extends State<_PremiumSidebarItem> {
  bool isHovering = false;

  @override
  Widget build(BuildContext context) {
    final bool active = widget.selected || isHovering;

    return MouseRegion(
      onEnter: (_) => setState(() => isHovering = true),
      onExit: (_) => setState(() => isHovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: widget.selected
                ? AppColors.primary.withOpacity(0.12)
                : active
                    ? AppColors.primary.withOpacity(0.06)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 20,
                color: widget.selected
                    ? AppColors.primary
                    : AppColors.textPrimary,
              ),
              const SizedBox(width: 12),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w500,
                  color: widget.selected
                      ? const Color(0xFF1E88E5)
                      : Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileDrawer extends StatelessWidget {
  const _MobileDrawer();

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          const SizedBox(height: 60),
          const AppLogo(size: 40),
          const SizedBox(height: 40),

          ListTile(
            leading: const Icon(Icons.home),
            title: const Text("Inicio"),
            onTap: () {
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.menu_book),
            title: const Text("Histórico"),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.calendar_month),
            title: const Text("Calendario"),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CalendarScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text("Chat IA"),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ChatScreen()),
              );
            },
          ),
          const Spacer(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text("Cerrar sesión"),
            onTap: () {
              context.read<AuthProvider>().logout();
            },
          ),
        ],
      ),
    );
  }
}