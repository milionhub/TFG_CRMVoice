import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
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

  @override
  Widget build(BuildContext context) {
    final monday = _currentWeekStart;
    final sunday = monday.add(const Duration(days: 6));

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      appBar: AppBar(
        title: const Text("Calendario semanal"),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _previousWeek,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _nextWeek,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildWeekView(),
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
    }).toList();

    final isToday =
        DateTime.now().year == day.year &&
        DateTime.now().month == day.month &&
        DateTime.now().day == day.day;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: isToday
            ? Border.all(
                color: const Color(0xFF1565C0),
                width: 2,
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildDayHeader(day, isToday),
          const SizedBox(height: 16),
          if (dayActivities.isEmpty)
            const Text(
              "Sin actividades",
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ...dayActivities.map(
            (activity) =>
                _buildActivityCard(activity),
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

    return GestureDetector(
      onTap: () => _openActivityDetail(activity),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFE3F2FD),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            /// Hora
            Text(
              time,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1565C0),
              ),
            ),
            const SizedBox(height: 6),

            /// Tipo actividad
            Text(
              activityType,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),

            /// Cliente
            if (client.isNotEmpty)
              Text(
                client,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.black87,
                ),
              ),

            /// Contacto
            if (contact.isNotEmpty)
              Text(
                contact,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                ),
              ),
          ],
        ),
      ),
    );
  }

 void _openActivityDetail(Map activity) {
    showDialog(
      context: context,
      builder: (_) {
        final iso = activity["fecha"];
        final date =
            iso != null ? DateTime.tryParse(iso) : null;

        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            padding: const EdgeInsets.all(24),
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activity["accion"] ?? "Actividad",
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),

                if (date != null)
                  Text(
                    "${date.day}/${date.month}/${date.year}  ${date.hour}:${date.minute.toString().padLeft(2, '0')}",
                  ),

                const SizedBox(height: 16),

                if (activity["cliente"] != null)
                  Text("Cliente: ${activity["cliente"]}"),

                if (activity["contacto"] != null)
                  Text("Contacto: ${activity["contacto"]}"),

                const SizedBox(height: 16),

                if (activity["comentario"] != null)
                  Text(activity["comentario"]),

                const SizedBox(height: 20),

                /// FUTURO: productos
                if (activity["products"] != null)
                  Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Productos relacionados:",
                        style:
                            TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      ...activity["products"]
                          .map<Widget>((p) =>
                              Text("- ${p["product_raw"]}"))
                          .toList(),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

}