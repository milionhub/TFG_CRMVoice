import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../core/app_colors.dart';
import 'home_screen.dart'; 


class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 800;

    if (isMobile) {
      return const _MobileLayoutCalendar();
    } else {
      return const _DesktopLayoutCalendar();
    }
  }
}

class _DesktopLayoutCalendar extends StatelessWidget {
  const _DesktopLayoutCalendar();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        children: [
          const Sidebar(currentIndex: 2),   // reutilizamos el sidebar del home
          const Expanded(
            child: SafeArea(
              child: CalendarContent(),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileLayoutCalendar extends StatelessWidget {
  const _MobileLayoutCalendar();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      drawer: const MobileDrawer(),  // mismo drawer del home
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: const Text("Calendario"),
      ),
      body: const SafeArea(
        child: CalendarContent(),
      ),
    );
  }
}

class CalendarContent extends StatefulWidget {
  const CalendarContent({super.key});

  @override
  State<CalendarContent> createState() => _CalendarContentState();
}

class _CalendarContentState extends State<CalendarContent> {
  DateTime _currentWeekStart = DateTime.now();
  List<dynamic> _activities = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _currentWeekStart = _getStartOfWeek(DateTime.now());
    _loadActivities();
  }

  DateTime _getStartOfWeek(DateTime date) {
    final weekday = date.weekday; // 1 = lunes
    return date.subtract(Duration(days: weekday - 1));
  }

  Future<void> _loadActivities() async {
    final api = context.read<ApiService>();

    final monday = _currentWeekStart;
    final sunday = monday.add(const Duration(days: 6));

    final data = await api.getActivities(
      dateFrom: monday.toIso8601String().split("T")[0],
      dateTo: sunday.toIso8601String().split("T")[0],
    );

    print("ACTIVIDADES SEMANA:");
    print(data);

    setState(() {
      _activities = data;
      _isLoading = false;
    });
  }

  void _previousWeek() {
    setState(() {
      _currentWeekStart =
          _currentWeekStart.subtract(const Duration(days: 7));
      _isLoading = true;
    });
    _loadActivities();
  }

  void _nextWeek() {
    setState(() {
      _currentWeekStart =
          _currentWeekStart.add(const Duration(days: 7));
      _isLoading = true;
    });
    _loadActivities();
  }

  void _openMonthPicker() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _currentWeekStart,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: AppColors.primary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _currentWeekStart = _getStartOfWeek(picked);
        _isLoading = true;
      });
      _loadActivities();
    }
  }

  String _monthName(int month) {
    const months = [
      "Enero",
      "Febrero",
      "Marzo",
      "Abril",
      "Mayo",
      "Junio",
      "Julio",
      "Agosto",
      "Septiembre",
      "Octubre",
      "Noviembre",
      "Diciembre"
    ];
    return months[month - 1];
  }

  Future<void> _openEditDialog(Map activity) async {

    final result = await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Editar actividad",
      barrierColor: Colors.black.withOpacity(0.25),
      transitionDuration: const Duration(milliseconds: 220),

      pageBuilder: (context, animation, secondaryAnimation) {
        return Center(
          child: EditActivityDialog(activity: activity),
        );
      },

      transitionBuilder: (context, animation, secondaryAnimation, child) {

        final curve = Curves.easeOutCubic;

        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: curve,
          ),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(
              CurvedAnimation(
                parent: animation,
                curve: curve,
              ),
            ),
            child: child,
          ),
        );

      },
    );

    if (result == true) {
      _loadActivities();
    }

  }


  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      child: Column(
        children: [

          /// HEADER PROPIO DEL CALENDARIO
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [

                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Calendario",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Vista semanal organizada por hora",
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),

                Row(
                  children: [

                    /// SELECTOR MES
                    GestureDetector(
                      onTap: _openMonthPicker,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.grey.withOpacity(0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.calendar_today,
                              size: 16,
                              color: AppColors.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "${_monthName(_currentWeekStart.month)} ${_currentWeekStart.year}",
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.expand_more, size: 18),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(width: 24),

                    IconButton(
                      icon: Icon(
                        Icons.chevron_left,
                        color: AppColors.primary,
                      ),
                      onPressed: _previousWeek,
                    ),

                    IconButton(
                      icon: Icon(
                        Icons.chevron_right,
                        color: AppColors.primary,
                      ),
                      onPressed: _nextWeek,
                    ),
                  ],
                ),
              ],
            ),
          ),

          /// CONTENIDO
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildWeekView(),
          ),
        ],
      ),
    );
  }

  Widget _buildWeekView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            padding: const EdgeInsets.all(24),
            width: constraints.maxWidth,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: List.generate(7, (index) {
                final day = _currentWeekStart.add(
                  Duration(days: index),
                );

                return Expanded(
                  child: _buildDayColumn(day),
                );
              }),
            ),
          ),
        );
      },
    );
  }


  Widget _buildDayColumn(DateTime day) {
    final dayActivities = _activities.where((a) {
      final iso = a["fecha"];
      if (iso == null) return false;

      final date = DateTime.tryParse(iso);
      if (date == null) return false;

      return date.year == day.year &&
          date.month == day.month &&
          date.day == day.day;
    }).toList()
      ..sort((a, b) {
        final da = DateTime.tryParse(a["fecha"] ?? "");
        final db = DateTime.tryParse(b["fecha"] ?? "");

        if (da == null || db == null) return 0;
        return da.compareTo(db);
      });

    final isToday =
        DateTime.now().year == day.year &&
        DateTime.now().month == day.month &&
        DateTime.now().day == day.day;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isToday
            ? AppColors.primary.withOpacity(0.04)
            : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: isToday
            ? Border.all(
                color: AppColors.primary,
                width: 1.5,
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: isToday
                ? AppColors.primary.withOpacity(0.08)
                : Colors.black.withOpacity(0.04),
            blurRadius: isToday ? 18 : 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          /// HEADER (NO SCROLLEA)
          _buildDayHeader(day, isToday),
          const SizedBox(height: 12),

          /// LINEA SEPARADORA (si ya la añadiste)
          Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  Colors.grey.withOpacity(0.3),
                  Colors.transparent,
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          /// 🔥 ACTIVIDADES SCROLLABLES
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (dayActivities.isEmpty)
                    const Text(
                      "Sin actividades",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),

                  ...dayActivities.map(
                    (activity) => _buildActivityCard(activity),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDayHeader(DateTime day, bool isToday) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          ["LUN", "MAR", "MIÉ", "JUE", "VIE", "SÁB", "DOM"]
              [day.weekday - 1],
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isToday
                ? const Color(0xFF1565C0)
                : Colors.grey,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          "${day.day}",
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: isToday
                ? const Color(0xFF1565C0)
                : Colors.black,
          ),
        ),
      ],
    );
  }

  

  Widget _buildActivityCard(Map activity) {
    final iso = activity["fecha"];
    final date = iso != null ? DateTime.tryParse(iso) : null;

    final time = date != null
        ? "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}"
        : "--:--";

    final activityType = activity["accion"] ?? "Actividad";
    final client = activity["cliente"] ?? "";
    final contact = activity["contacto"] ?? "";

    final color = getActivityColor(activityType);

    return StatefulBuilder(
      builder: (context, setState) {
        bool isHovering = false;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => isHovering = true),
          onExit: (_) => setState(() => isHovering = false),
          child: GestureDetector(
            onTap: () => _openActivityDetail(activity),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isHovering
                      ? color.withOpacity(0.4)
                      : Colors.transparent,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(
                      isHovering ? 0.08 : 0.04,
                    ),
                    blurRadius: isHovering ? 18 : 10,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [

                  /// BARRA LATERAL
                  Container(
                    width: 4,
                    height: 80,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                      ),
                    ),
                  ),

                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [

                          /// HORA
                          Text(
                            time,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: color,
                            ),
                          ),

                          const SizedBox(height: 6),

                          /// TIPO ACTIVIDAD
                          Text(
                            activityType,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: AppColors.primary,
                            ),
                          ),

                          const SizedBox(height: 6),

                          /// CLIENTE
                          if (client.isNotEmpty)
                            Text(
                              client,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.black87,
                              ),
                            ),

                          /// CONTACTO
                          if (contact.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                contact,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
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
        );
      },
    );
  }

 void _openActivityDetail(Map activity) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) {
        final iso = activity["fecha"];
        final date = iso != null ? DateTime.tryParse(iso) : null;
        final type = activity["accion"] ?? "Actividad";
        final color = getActivityColor(type);

        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: 540,
            padding: const EdgeInsets.all(30),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.18),
                  blurRadius: 45,
                  offset: const Offset(0, 25),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  /// HEADER
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 6,
                        height: 40,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      const SizedBox(width: 16),

                      Expanded(
                        child: Text(
                          type,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary,
                          ),
                        ),
                      ),

                      /// EDITAR
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () {
                          Future.microtask(() {
                          Navigator.pop(context);
                          _openEditDialog(activity);
                          });
                        },
                      ),

                      /// BORRAR
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (_) {
                              return Dialog(
                                backgroundColor: Colors.transparent,
                                child: Container(
                                  width: 420,
                                  padding: const EdgeInsets.all(26),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(24),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.18),
                                        blurRadius: 40,
                                        offset: const Offset(0, 20),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [

                                      /// TITULO
                                      const Text(
                                        "Eliminar actividad",
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.primary,
                                        ),
                                      ),

                                      const SizedBox(height: 14),

                                      /// TEXTO
                                      const Text(
                                        "¿Seguro que quieres eliminar esta actividad?",
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Colors.black87,
                                        ),
                                      ),

                                      const SizedBox(height: 26),

                                      /// BOTONES
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [

                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text(
                                              "Cancelar",
                                              style: TextStyle(
                                                color: AppColors.primary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),

                                          const SizedBox(width: 16),

                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.red,
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 20, vertical: 12),
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(14),
                                              ),
                                            ),
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text("Eliminar"),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }
                                                      );

                          if (confirm == true) {
                            final api = context.read<ApiService>();
                            await api.deleteActivity(activity["id"]);
                            Navigator.pop(context);
                            _loadActivities();
                          }
                        },
                      ),

                      /// CERRAR
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  /// FECHA
                  if (date != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.schedule,
                            size: 18,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "${date.day}/${date.month}/${date.year} · "
                            "${date.hour.toString().padLeft(2, '0')}:"
                            "${date.minute.toString().padLeft(2, '0')}",
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 26),

                  /// CLIENTE
                  _DetailBlock(
                    icon: Icons.business,
                    label: "Cliente",
                    value: activity["cliente"] ?? "-",
                  ),

                  const SizedBox(height: 18),

                  /// CONTACTO
                  _DetailBlock(
                    icon: Icons.person,
                    label: "Contacto",
                    value: activity["contacto"] ?? "-",
                  ),

                  const SizedBox(height: 26),

                  /// PRODUCTOS
                  if (activity["products"] != null &&
                      activity["products"].isNotEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Productos asociados",
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: activity["products"]
                              .map<Widget>(
                                (p) => Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(22),
                                  ),
                                  child: Text(
                                    p["product_raw"],
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DetailBlock extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailBlock({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Colors.grey[600]),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class EditActivityDialog extends StatefulWidget {
  final Map activity;

  const EditActivityDialog({super.key, required this.activity});

  @override
  State<EditActivityDialog> createState() => _EditActivityDialogState();
}

class _EditActivityDialogState extends State<EditActivityDialog> {

  DateTime? _date;

  int? _clientId;
  int? _contactId;
  int? _typeId;

  List<dynamic> _clients = [];
  List<dynamic> _contacts = [];
  List<dynamic> _types = [];
  List<dynamic> _products = [];

  List<Map<String, dynamic>> _selectedProducts = [];

  bool _loading = true;

  @override
  void initState() {
    super.initState();

    _date = DateTime.parse(widget.activity["fecha"]);
    _clientId = widget.activity["client_id"];
    _contactId = widget.activity["contact_id"];
    _typeId = widget.activity["activity_type_id"];

    final products = widget.activity["products"] ?? [];

    _selectedProducts = products.map<Map<String,dynamic>>((p) {
      return {
        "id": p["id"] ?? p["product_id"],
        "name": p["name"] ?? p["product_raw"]
      };
    }).toList();

    _loadData();
  }

  Future<void> _loadData() async {

    final api = context.read<ApiService>();

    final clients = await api.getClients();
    final contacts = await api.getContacts(clientId: _clientId);
    final types = await api.getActivityTypes();
    final products = await api.getProducts();

    setState(() {
      _clients = clients;
      _contacts = contacts;
      _types = types;
      _products = products;
      _loading = false;
    });

  }

  void _openProductSelector() {

    String search = "";

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(24),
        ),
      ),
      builder: (_) {

        return StatefulBuilder(
          builder: (context, setModalState) {

            final filtered = _products.where((p) {

              final name = p["name"].toLowerCase();
              return name.contains(search.toLowerCase());

            }).toList();

            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [

                  TextField(
                    decoration: InputDecoration(
                      hintText: "Buscar producto...",
                      prefixIcon: const Icon(Icons.search, color: AppColors.primary),
                      filled: true,
                      fillColor: AppColors.primary.withOpacity(0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                    onChanged: (v) {
                      setModalState(() {
                        search = v;
                      });
                    },
                  ),

                  const SizedBox(height: 16),

                  SizedBox(
                    height: 400,
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {

                        final p = filtered[i];

                        final exists = _selectedProducts
                            .any((sp) => sp["id"] == p["id"]);

                        return ListTile(
                          title: Text(
                            p["name"],
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          trailing: exists
                              ? const Icon(Icons.check, color: AppColors.primary)
                              : null,
                          onTap: () {

                            if (!exists) {

                              setState(() {

                                _selectedProducts.add({
                                  "id": p["id"],
                                  "name": p["name"]
                                });

                              });

                            }

                            Navigator.pop(context);

                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {

    final api = context.read<ApiService>();

    final type = _types
        .firstWhere((t) => t["id"] == _typeId,
        orElse: () => {"name": "Actividad"})["name"];

    final color = getActivityColor(type);

    if (_loading) {
      return const Dialog(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 540,
        padding: const EdgeInsets.all(30),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: 45,
              offset: const Offset(0, 25),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              /// HEADER
              Row(
                children: [

                  Container(
                    width: 6,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),

                  const SizedBox(width: 16),

                  Expanded(
                    child: Text(
                      type,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                  ),

                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  )
                ],
              ),

              const SizedBox(height: 24),

              /// FECHA + HORA
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [

                    Icon(Icons.schedule,
                        size: 18,
                        color: AppColors.primary),

                    const SizedBox(width: 8),

                    TextButton(
                      onPressed: () async {

                        final picked = await showDatePicker(
                          context: context,
                          builder: (context, child) {
                            return Theme(
                              data: Theme.of(context).copyWith(
                                colorScheme: ColorScheme.light(
                                  primary: AppColors.primary,
                                  onPrimary: Colors.white,
                                  onSurface: AppColors.primary,
                                ),
                              ),
                              child: child!,
                            );
                          },
                          initialDate: _date!,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                        );

                        if (picked != null) {

                          setState(() {

                            _date = DateTime(
                                picked.year,
                                picked.month,
                                picked.day,
                                _date!.hour,
                                _date!.minute);

                          });

                        }

                      },
                      child: Text(
                        "${_date!.day}/${_date!.month}/${_date!.year}",
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),

                    const Text(" · "),

                    TextButton(
                      onPressed: () async {

                        final picked = await showTimePicker(
                          context: context,
                          builder: (context, child) {
                            return Theme(
                              data: Theme.of(context).copyWith(
                                colorScheme: ColorScheme.light(
                                  primary: AppColors.primary,
                                  onPrimary: Colors.white,
                                  onSurface: AppColors.primary,
                                ),
                              ),
                              child: child!,
                            );
                          },
                          initialTime:
                          TimeOfDay.fromDateTime(_date!),
                        );

                        if (picked != null) {

                          setState(() {

                            _date = DateTime(
                                _date!.year,
                                _date!.month,
                                _date!.day,
                                picked.hour,
                                picked.minute);

                          });

                        }

                      },
                       child: Text(
                        "${_date!.hour.toString().padLeft(2,'0')}:${_date!.minute.toString().padLeft(2,'0')}",
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 26),

              /// CLIENTE
              _EditBlock(
                icon: Icons.business,
                label: "Cliente",
                child: DropdownButtonFormField<int>(
                  value: _clientId,
                  dropdownColor: Colors.white,
                  iconEnabledColor: AppColors.primary,
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                    items: _clients.map<DropdownMenuItem<int>>((c) {
                    return DropdownMenuItem(
                      value: c["id"],
                      child: Text(c["name"]),
                    );
                  }).toList(),
                  onChanged: (v) async {

                    setState(() {
                      _clientId = v;
                      _contactId = null;
                      _contacts = [];
                    });

                    final contacts =
                    await api.getContacts(clientId: _clientId);

                    setState(() {
                      _contacts = contacts;
                    });

                  },
                ),
              ),

              const SizedBox(height: 18),

              /// CONTACTO
              _EditBlock(
                icon: Icons.person,
                label: "Contacto",
                child: DropdownButtonFormField<int>(
                  value: _contacts.any((c) => c["id"] == _contactId)
                      ? _contactId
                      : null,
                  dropdownColor: Colors.white,
                  iconEnabledColor: AppColors.primary,
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  items: _contacts.map<DropdownMenuItem<int>>((c) {
                    return DropdownMenuItem(
                      value: c["id"],
                      child: Text(c["name"]),
                    );
                  }).toList(),
                  onChanged: (v) {

                    setState(() {
                      _contactId = v;
                    });

                  },
                ),
              ),

              const SizedBox(height: 18),

              /// TIPO ACTIVIDAD
              _EditBlock(
                icon: Icons.flash_on,
                label: "Tipo actividad",
                child: DropdownButtonFormField<int>(
                  value: _typeId,
                  dropdownColor: Colors.white,
                  iconEnabledColor: AppColors.primary,
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  items: _types.map<DropdownMenuItem<int>>((t) {
                    return DropdownMenuItem(
                      value: t["id"],
                      child: Text(t["name"]),
                    );
                  }).toList(),
                  onChanged: (v) {

                    setState(() {
                      _typeId = v;
                    });

                  },
                ),
              ),

              const SizedBox(height: 26),

              /// PRODUCTOS
              const Text(
                "Productos asociados",
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87),
              ),

              const SizedBox(height: 12),

              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _selectedProducts.map((p) {

                  return Chip(
                    label: Text(
                      p["name"],
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    backgroundColor: AppColors.primary,
                    deleteIcon: const Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.white,
                    ),
                    onDeleted: () {

                      setState(() {

                        _selectedProducts.removeWhere(
                                (e) => e["id"] == p["id"]);

                      });

                    },
                  );

                }).toList(),
              ),

              const SizedBox(height: 10),

              TextButton.icon(
                icon: Icon(Icons.add, color: AppColors.primary),
                label: Text(
                  "Añadir producto",
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: _openProductSelector,
              ),

              const SizedBox(height: 28),

              /// GUARDAR
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding:
                    const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  onPressed: () async {

                    final products = _selectedProducts.map((p) {
                      return {
                        "id": p["id"],
                        "name": p["name"]
                      };
                    }).toList();

                    final ok = await api.updateActivity(
                      widget.activity["id"],
                      {
                        "fecha": _date?.toIso8601String(),
                        "client_id": _clientId,
                        "contact_id": _contactId,
                        "activity_type_id": _typeId,
                        "products": products
                      },
                    );

                    if (ok) {

                      Navigator.pop(context, true);

                    }

                  },
                  child: const Text(
                    "Guardar cambios",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              )

            ],
          ),
        ),
      ),
    );
  }
}

class _EditBlock extends StatelessWidget {

  final IconData icon;
  final String label;
  final Widget child;

  const _EditBlock({
    required this.icon,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        Icon(icon, size: 18, color: Colors.grey[600]),

        const SizedBox(width: 12),

        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),

              const SizedBox(height: 4),

              child,
            ],
          ),
        ),
      ],
    );

  }
}

Color getActivityColor(String type) {
    switch (type.toLowerCase()) {

      case "concertar reunión":
        return const Color(0xFF3B82F6); // Azul moderno

      case "enviar presupuesto":
        return const Color(0xFFEC4899); // Rosa elegante

      case "enviar oferta":
        return const Color(0xFFF97316); // Naranja moderno

      case "registrar visita comercial":
        return const Color(0xFFEAB308); // Amarillo sofisticado

      case "realizar llamada de seguimiento":
        return const Color(0xFF22C55E); // Verde limpio

      default:
        return AppColors.primary;
    }
  }