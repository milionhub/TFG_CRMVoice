// Shell de la aplicación (I.2): barra lateral (completa o compacta), menú
// móvil y cabecera móvil con la identidad CRMVoice.
//
// Navegación (H.5): cada sección SUSTITUYE toda la pila (no se acumulan
// pantallas al usar el menú) y se crea de nuevo, así que carga datos
// actuales del CRM. Elegir la sección en la que ya se está no hace nada (en
// móvil solo cierra el menú).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';
import '../../providers/auth_provider.dart';
import '../../screens/calendar_screen.dart';
import '../../screens/chat_screen.dart';
import '../../screens/clients_screen.dart';
import '../../screens/history_screen.dart';
import '../../screens/home_screen.dart';
import '../brand/crm_voice_brand.dart';

/// Destino de la navegación principal.
class ShellDestination {
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  const ShellDestination(this.label, this.icon, this.selectedIcon);
}

/// Secciones principales, en el orden de la navegación.
const shellDestinations = [
  ShellDestination('Inicio', Icons.home_outlined, Icons.home_rounded),
  ShellDestination('Clientes', Icons.business_outlined, Icons.business_rounded),
  ShellDestination(
    'Calendario',
    Icons.calendar_month_outlined,
    Icons.calendar_month_rounded,
  ),
  ShellDestination(
    'Actividades',
    Icons.event_note_outlined,
    Icons.event_note_rounded,
  ),
  ShellDestination(
    'Chat IA',
    Icons.chat_bubble_outline_rounded,
    Icons.chat_bubble_rounded,
  ),
];

/// Pantalla de cada sección (mismo índice que [shellDestinations]).
Widget sectionScreen(int index) => switch (index) {
  1 => const ClientsScreen(),
  2 => const CalendarScreen(),
  3 => const HistoryScreen(),
  4 => const ChatScreen(),
  _ => const HomeScreen(),
};

/// Abre la sección sustituyendo toda la pila.
void replaceWithSection(NavigatorState navigator, int index) {
  navigator.pushAndRemoveUntil(
    SectionRoute(builder: (_) => sectionScreen(index)),
    (_) => false,
  );
}

/// Ruta entre secciones hermanas (Inicio, Clientes, Calendario, Actividades,
/// Chat IA). Sustituye la transición de página de la plataforma
/// (MaterialPageRoute: zoom con velo del color de superficie en Windows/Linux,
/// deslizamiento lateral en macOS/iOS), que animaba la pantalla completa,
/// barra lateral incluida, como si toda la app entrase de nuevo.
///
/// - Escritorio/tablet: la ruta aparece sin transición (la barra lateral es
///   idéntica en ambas pantallas, así que no se mueve) y solo el contenido
///   hace un fundido corto desde el fondo (ver [AppShell]).
/// - Móvil: el menú lateral empieza a cerrarse y, tras un breve retardo, el
///   destino aparece con un fundido sobre él: una sola transición encadenada.
class SectionRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;

  SectionRoute({required this.builder, super.settings});

  static const duration = Duration(milliseconds: 220);

  /// Fundido del contenido en escritorio/tablet (~165 ms).
  static const contentCurve = Interval(0, 0.75, curve: Curves.easeOut);

  /// Fundido de la pantalla en móvil, tras dejar arrancar el cierre del menú.
  static const mobileCurve = Interval(0.3, 1, curve: Curves.easeOut);

  @override
  Duration get transitionDuration => duration;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation) =>
      builder(context);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (!AppShell.isMobile(context)) return child;
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: mobileCurve),
      child: child,
    );
  }
}

/// Estructura común de las secciones: barra lateral en escritorio/tablet;
/// cabecera + menú lateral en móvil. [body] es el contenido de la sección.
class AppShell extends StatelessWidget {
  final int currentIndex;
  final Widget body;

  /// Título de la cabecera móvil (Inicio muestra el wordmark).
  final String? title;
  final List<Widget>? mobileActions;
  final Color backgroundColor;

  /// false en subpáginas de una sección (p. ej. la ficha de un cliente
  /// dentro de Clientes): su destino sigue activo en la navegación y
  /// pulsarlo vuelve a la raíz de la sección.
  final bool sectionRoot;

  /// Subpáginas en móvil: la cabecera muestra «Atrás» (con esta acción) en
  /// lugar del menú, como una pantalla de detalle nativa.
  final VoidCallback? onBack;

  const AppShell({
    super.key,
    required this.currentIndex,
    required this.body,
    this.title,
    this.mobileActions,
    this.backgroundColor = CvColors.background,
    this.sectionRoot = true,
    this.onBack,
  });

  static bool isMobile(BuildContext context) =>
      MediaQuery.sizeOf(context).width < CvBreakpoints.shellMobile;

  @override
  Widget build(BuildContext context) {
    if (isMobile(context)) {
      return Scaffold(
        backgroundColor: backgroundColor,
        appBar: ShellAppBar(title: title, actions: mobileActions, onBack: onBack),
        drawer: MobileDrawer(currentIndex: currentIndex, reselectNavigates: !sectionRoot),
        body: SafeArea(child: body),
      );
    }
    return Scaffold(
      backgroundColor: backgroundColor,
      body: Row(
        children: [
          Sidebar(currentIndex: currentIndex, reselectNavigates: !sectionRoot),
          Expanded(child: SafeArea(child: _SectionContentTransition(child: body))),
        ],
      ),
    );
  }
}

/// Entrada del contenido al cambiar de sección en escritorio/tablet: fundido
/// desde el fondo con una subida de 4 px. Solo en [SectionRoute]: el resto de
/// rutas (p. ej. Actividades abierta desde Voz) conservan su transición.
class _SectionContentTransition extends StatelessWidget {
  final Widget child;

  const _SectionContentTransition({required this.child});

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    if (route is! SectionRoute) return child;
    final t = CurvedAnimation(
      parent: route.animation!,
      curve: SectionRoute.contentCurve,
    );
    return FadeTransition(
      opacity: t,
      child: AnimatedBuilder(
        animation: t,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, 4 * (1 - t.value)),
          child: child,
        ),
        child: child,
      ),
    );
  }
}

// =====================================================================
// Barra lateral (escritorio y tablet)
// =====================================================================

class Sidebar extends StatefulWidget {
  final int currentIndex;

  /// Pulsar el destino activo también navega (desde una subpágina).
  final bool reselectNavigates;

  const Sidebar({super.key, required this.currentIndex, this.reselectNavigates = false});

  @override
  State<Sidebar> createState() => SidebarState();
}

class SidebarState extends State<Sidebar> {
  late int selectedIndex;

  @override
  void initState() {
    super.initState();
    selectedIndex = widget.currentIndex;
  }

  void _navigate(int index, BuildContext context) {
    if (index == selectedIndex && !widget.reselectNavigates) return;

    setState(() {
      selectedIndex = index;
    });

    // La sección sustituye TODA la pila (como el menú móvil): si había algo
    // apilado sobre Home (p. ej. Actividades abierta desde Voice V2), no queda
    // una Home antigua debajo
    replaceWithSection(Navigator.of(context), index);
  }

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < CvBreakpoints.shellExpanded;

    return Theme(
      data: CvTheme.light(),
      child: Container(
        width: compact ? CvLayout.sidebarCompactWidth : CvLayout.sidebarWidth,
        decoration: const BoxDecoration(
          color: CvColors.surface,
          border: Border(right: BorderSide(color: CvColors.border)),
        ),
        child: SafeArea(
          right: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 0 : 22,
                  CvSpace.xl,
                  compact ? 0 : 22,
                  0,
                ),
                child: Align(
                  alignment: compact ? Alignment.center : Alignment.centerLeft,
                  child: compact
                      ? const CrmVoiceMark(size: 32)
                      : const CrmVoiceWordmark(markSize: 30),
                ),
              ),
              const SizedBox(height: CvSpace.xxl),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? CvSpace.sm : CvSpace.sm + 2,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < shellDestinations.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: ShellNavItem(
                            destination: shellDestinations[i],
                            selected: i == selectedIndex,
                            compact: compact,
                            onTap: () => _navigate(i, context),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: CvColors.border),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? CvSpace.xs : CvSpace.sm + 2,
                  vertical: CvSpace.sm,
                ),
                child: _SidebarUser(compact: compact),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Elemento de navegación: activo con fondo primarySoft y texto primaryDark;
/// hover muy suave. En modo compacto solo icono (con tooltip).
class ShellNavItem extends StatelessWidget {
  final ShellDestination destination;
  final bool selected;
  final bool compact;
  final double height;
  final VoidCallback onTap;

  const ShellNavItem({
    super.key,
    required this.destination,
    required this.selected,
    required this.onTap,
    this.compact = false,
    this.height = 42,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? CvColors.primaryDark : CvColors.textSecondary;
    final icon = Icon(
      selected ? destination.selectedIcon : destination.icon,
      size: 20,
      color: color,
    );

    Widget item = Material(
      color: selected ? CvColors.primarySoft : Colors.transparent,
      borderRadius: BorderRadius.circular(CvRadius.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(CvRadius.control),
        hoverColor: CvColors.textPrimary.withValues(alpha: 0.04),
        splashColor: CvColors.primary.withValues(alpha: 0.12),
        highlightColor: CvColors.primary.withValues(alpha: 0.06),
        onTap: onTap,
        child: SizedBox(
          height: compact ? 44 : height,
          child: compact
              ? Center(child: icon)
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: CvSpace.sm),
                  child: Row(
                    children: [
                      icon,
                      const SizedBox(width: CvSpace.sm),
                      Expanded(
                        child: Text(
                          destination.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CvText.label.copyWith(
                            fontSize: 14,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: selected
                                ? CvColors.primaryDark
                                : CvColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );

    if (compact) {
      item = Tooltip(
        message: destination.label,
        preferBelow: false,
        waitDuration: const Duration(milliseconds: 300),
        child: item,
      );
    }

    return Semantics(
      button: true,
      selected: selected,
      label: compact ? destination.label : null,
      child: item,
    );
  }
}

/// Inicial del usuario sobre primarySoft.
class UserAvatar extends StatelessWidget {
  final String name;
  final double size;

  const UserAvatar({super.key, required this.name, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '?';
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CvColors.primarySoft,
          shape: BoxShape.circle,
          border: Border.all(color: CvColors.primary.withValues(alpha: 0.35)),
        ),
        child: Text(
          initial,
          style: CvText.label.copyWith(
            fontSize: size * 0.4,
            color: CvColors.primaryDark,
          ),
        ),
      ),
    );
  }
}

class _LogoutButton extends StatelessWidget {
  const _LogoutButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Cerrar sesión',
      icon: const Icon(Icons.logout, size: 19),
      color: CvColors.textSecondary,
      hoverColor: CvColors.dangerSoft,
      highlightColor: CvColors.dangerSoft,
      onPressed: () => context.read<AuthProvider>().logout(),
    );
  }
}

/// Identidad del usuario al pie de la barra lateral, con cerrar sesión.
class _SidebarUser extends StatelessWidget {
  final bool compact;

  const _SidebarUser({required this.compact});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final name = auth.userName ?? '';
    final email = auth.userEmail ?? '';

    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: [name, email].where((s) => s.isNotEmpty).join('\n'),
            child: Semantics(
              label: 'Sesión de $name',
              child: UserAvatar(name: name),
            ),
          ),
          const SizedBox(height: CvSpace.xxs),
          const _LogoutButton(),
        ],
      );
    }

    return Row(
      children: [
        UserAvatar(name: name),
        const SizedBox(width: CvSpace.sm - 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CvText.label.copyWith(fontSize: 13.5),
              ),
              if (email.isNotEmpty)
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CvText.helper.copyWith(fontSize: 12),
                ),
            ],
          ),
        ),
        const _LogoutButton(),
      ],
    );
  }
}

// =====================================================================
// Móvil: cabecera y menú lateral
// =====================================================================

/// Cabecera móvil compacta: menú, símbolo CRMVoice y título de la sección
/// (Inicio muestra el wordmark completo).
class ShellAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final List<Widget>? actions;

  /// Si se indica, «Atrás» sustituye al botón de menú (subpáginas).
  final VoidCallback? onBack;

  const ShellAppBar({super.key, this.title, this.actions, this.onBack});

  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  Widget build(BuildContext context) {
    final title = this.title;
    return AppBar(
      toolbarHeight: 60,
      backgroundColor: CvColors.surface,
      foregroundColor: CvColors.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: const Border(bottom: BorderSide(color: CvColors.border)),
      titleSpacing: 4,
      leading: onBack != null
          ? BackButton(color: CvColors.textPrimary, onPressed: onBack)
          : Builder(
              builder: (context) => IconButton(
                tooltip: 'Abrir menú',
                icon: const Icon(Icons.menu_rounded, color: CvColors.textPrimary),
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
      title: title == null
          ? const CrmVoiceWordmark(markSize: 26)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CrmVoiceMark(size: 24),
                const SizedBox(width: CvSpace.sm - 2),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CvText.heading.copyWith(
                      fontSize: 17,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ],
            ),
      actions: actions,
      iconTheme: const IconThemeData(color: CvColors.textPrimary),
      actionsIconTheme: const IconThemeData(color: CvColors.textPrimary),
    );
  }
}

/// Menú lateral en móvil: marca, secciones (objetivos táctiles de 48 px) y
/// usuario con cerrar sesión.
class MobileDrawer extends StatelessWidget {
  final int currentIndex;

  /// Pulsar el destino activo también navega (desde una subpágina).
  final bool reselectNavigates;

  const MobileDrawer({super.key, required this.currentIndex, this.reselectNavigates = false});

  void _go(BuildContext context, int index) {
    final navigator = Navigator.of(context);
    navigator.pop(); // cierra el menú
    if (index == currentIndex && !reselectNavigates) return;
    replaceWithSection(navigator, index);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final name = auth.userName ?? '';
    final email = auth.userEmail ?? '';

    return Theme(
      data: CvTheme.light(),
      child: Drawer(
        width: 300,
        backgroundColor: CvColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
            right: Radius.circular(CvRadius.card),
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  CvSpace.lg,
                  CvSpace.lg,
                  CvSpace.lg,
                  0,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: CrmVoiceWordmark(markSize: 30),
                ),
              ),
              const SizedBox(height: CvSpace.xl),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: CvSpace.sm),
                  child: Column(
                    children: [
                      for (var i = 0; i < shellDestinations.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: ShellNavItem(
                            destination: shellDestinations[i],
                            selected: i == currentIndex,
                            height: 48,
                            onTap: () => _go(context, i),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: CvColors.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  CvSpace.lg,
                  CvSpace.md,
                  CvSpace.lg,
                  CvSpace.xs,
                ),
                child: Row(
                  children: [
                    UserAvatar(name: name, size: 40),
                    const SizedBox(width: CvSpace.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CvText.label.copyWith(fontSize: 14),
                          ),
                          if (email.isNotEmpty)
                            Text(
                              email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CvText.helper,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  CvSpace.sm,
                  0,
                  CvSpace.sm,
                  CvSpace.sm,
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(CvRadius.control),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(CvRadius.control),
                    onTap: () => context.read<AuthProvider>().logout(),
                    child: SizedBox(
                      height: 48,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: CvSpace.sm,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.logout,
                              size: 20,
                              color: CvColors.textSecondary,
                            ),
                            const SizedBox(width: CvSpace.sm),
                            Text(
                              'Cerrar sesión',
                              style: CvText.label.copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: CvColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
