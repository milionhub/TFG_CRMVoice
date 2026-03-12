import 'package:flutter/material.dart';
import '../core/app_colors.dart';
import 'home_screen.dart';
import 'calendar_screen.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 800;

    if (isMobile) {
      return const _MobileLayoutHistory();
    } else {
      return const _DesktopLayoutHistory();
    }
  }
}

class _DesktopLayoutHistory extends StatelessWidget {
  const _DesktopLayoutHistory();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        children: [
          const Sidebar(currentIndex: 1),
          const Expanded(
            child: SafeArea(
              child: HistoryContent(),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileLayoutHistory extends StatelessWidget {
  const _MobileLayoutHistory();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      drawer: const MobileDrawer(),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: const Text("Histórico"),
      ),
      body: const SafeArea(
        child: HistoryContent(),
      ),
    );
  }
}

class HistoryContent extends StatefulWidget {
  const HistoryContent({super.key});

  @override
  State<HistoryContent> createState() => _HistoryContentState();
}

class _HistoryContentState extends State<HistoryContent> {

  bool loading = true;
  List<dynamic> activities = [];

  int? selectedClientId;
  int? selectedActionId;
  int? selectedContactId;
  int? selectedProductId;
  DateTimeRange? selectedRange;

  List<dynamic> clients = [];
  List<dynamic> actions = [];
  List<dynamic> contacts = [];
  List<dynamic> products = [];


  @override
  void initState() {
    super.initState();
    _loadFilters();
    _loadActivities();
  }

  Future<void> _loadActivities() async {

    final api = context.read<ApiService>();

    final data = await api.getActivities(
      clientId: selectedClientId,
      actionId: selectedActionId,
      dateFrom: selectedRange?.start.toIso8601String().split("T").first,
      dateTo: selectedRange?.end.toIso8601String().split("T").first,
    );

    List filtered = data;

    if (selectedContactId != null) {
      filtered = filtered.where((a) =>
          a["contact_id"] == selectedContactId).toList();
    }

    if (selectedProductId != null) {

      final productName = products.firstWhere(
        (p) => p["id"] == selectedProductId
      )["name"];

      filtered = filtered.where((a) {

        final prods = a["products"] ?? [];

        return prods.any((p) =>
            p["product_raw"] == productName);

      }).toList();

    }

    setState(() {
      activities = filtered;
      loading = false;
    });

  }

  Future<void> _loadFilters() async {

    final api = context.read<ApiService>();

    final c = await api.getClients();
    final a = await api.getActivityTypes();
    final p = await api.getProducts();

    setState(() {
      clients = c;
      actions = a;
      products = p;
    });

  }

  void _openFilters() {

    int? client = selectedClientId;
    int? action = selectedActionId;
    int? contact = selectedContactId;
    int? product = selectedProductId;
    DateTimeRange? range = selectedRange;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {

        return Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              const Text(
                "Filtrar actividades",
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),

              const SizedBox(height: 24),

              /// CLIENTE
              DropdownButtonFormField<int>(
                value: client,
                dropdownColor: Colors.white,
                iconEnabledColor: AppColors.primary,
                style: const TextStyle(color: AppColors.primary),
                decoration: const InputDecoration(labelText: "Cliente"),
                items: clients.map<DropdownMenuItem<int>>((c) {
                  return DropdownMenuItem(
                    value: c["id"],
                    child: Text(c["name"]),
                  );
                }).toList(),
                onChanged: (v) async {

                  setModalState(() {
                    client = v;

                    /// borrar contacto anterior si cambia cliente
                    contact = null;

                    /// limpiar lista mientras carga
                    contacts = [];
                  });

                  if (v != null) {

                    final api = context.read<ApiService>();
                    final cs = await api.getContacts(clientId: v);

                    setModalState(() {
                      contacts = cs;
                    });

                  }

                },
            ),

              const SizedBox(height: 16),

              /// CONTACTO
              DropdownButtonFormField<int>(
                value: contact,
                dropdownColor: Colors.white,
                iconEnabledColor: AppColors.primary,
                style: const TextStyle(color: AppColors.primary),
                decoration: const InputDecoration(labelText: "Contacto"),
                items: contacts.map<DropdownMenuItem<int>>((c) {
                  return DropdownMenuItem(
                    value: c["id"],
                    child: Text(c["name"]),
                  );
                }).toList(),
                onChanged: client == null ? null : (v) {
                  setModalState(() {
                    contact = v;
                  });
                },
              ),

              const SizedBox(height: 16),

              /// ACCIÓN
              DropdownButtonFormField<int>(
                value: action,
                dropdownColor: Colors.white,
                iconEnabledColor: AppColors.primary,
                style: const TextStyle(color: AppColors.primary),
                decoration: const InputDecoration(labelText: "Acción"),
                items: actions.map<DropdownMenuItem<int>>((a) {
                  return DropdownMenuItem(
                    value: a["id"],
                    child: Text(a["name"]),
                  );
                }).toList(),
                onChanged: (v) {
                  action = v;
                },
              ),

              const SizedBox(height: 16),

              /// PRODUCTO
              DropdownButtonFormField<int>(
                value: product,
                dropdownColor: Colors.white,
                iconEnabledColor: AppColors.primary,
                style: const TextStyle(color: AppColors.primary),
                decoration: const InputDecoration(labelText: "Producto"),
                items: products.map<DropdownMenuItem<int>>((p) {
                  return DropdownMenuItem(
                    value: p["id"],
                    child: Text(p["name"]),
                  );
                }).toList(),
                onChanged: (v) {
                  product = v;
                },
              ),

              const SizedBox(height: 20),

              /// FECHAS
              ElevatedButton.icon(
                icon: const Icon(Icons.date_range),
                label: const Text("Seleccionar rango de fechas"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {

                  final r = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2030),

                    builder: (context, child) {

                      return Theme(

                        data: ThemeData.light().copyWith(

                          colorScheme: const ColorScheme.light(
                            primary: AppColors.primary,
                            onPrimary: Colors.white,
                            surface: Colors.white,
                            onSurface: Colors.black,
                          ),

                          dialogBackgroundColor: Colors.white,
                          scaffoldBackgroundColor: Colors.white,

                          textTheme: const TextTheme(
                            bodyMedium: TextStyle(color: Colors.black),
                            bodyLarge: TextStyle(color: Colors.black),
                          ),

                          textButtonTheme: TextButtonThemeData(
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.primary,
                            ),
                          ),

                        ),

                        child: child!,

                      );

                    },
                  );

                  if (r != null) {
                    range = r;
                  }

                },
              ),

              const SizedBox(height: 28),

              /// BOTONES
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [

                  TextButton(
                    onPressed: () {

                      setModalState(() {

                        client = null;
                        action = null;
                        contact = null;
                        product = null;
                        range = null;
                        contacts = []; 

                      });

                      setState(() {

                        selectedClientId = null;
                        selectedActionId = null;
                        selectedContactId = null;
                        selectedProductId = null;
                        selectedRange = null;
                      

                      });


                      _loadActivities();

                    },
                    child: const Text(
                      "Limpiar",
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),

                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    onPressed: () {

                      setState(() {
                        selectedClientId = client;
                        selectedActionId = action;
                        selectedContactId = contact;
                        selectedProductId = product;
                        selectedRange = range;
                      });

                      Navigator.pop(context);
                      _loadActivities();

                    },
                    child: const Text("Aplicar"),
                  ),

                ],
              ),

              const SizedBox(height: 10),

            ],
          ),
        );

      },
        
    );
      
  });
  }

  @override
  Widget build(BuildContext context) {

    return Column(
      children: [

        /// HEADER
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [

              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Histórico CRM",
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Registro completo de actividades",
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),

              Row(
                children: [

                   IconButton(
                      icon: const Icon(Icons.filter_alt_outlined),
                      onPressed: _openFilters,
                    ),

                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () {
                      setState(() {
                        loading = true;
                      });
                      _loadActivities();
                    },
                  ),

                ],
              ),
            ],
          ),
        ),

        if (selectedClientId != null ||
            selectedActionId != null ||
            selectedRange != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Wrap(
              spacing: 8,
              children: [

                if (selectedClientId != null)
                  Chip(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    label: Text(
                      clients.firstWhere(
                        (c) => c["id"] == selectedClientId,
                      )["name"],
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    deleteIcon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 16,
                    ),
                    onDeleted: () {
                      setState(() {
                        selectedClientId = null;
                      });
                      _loadActivities();
                    },
                  ),

                if (selectedActionId != null)
                  Chip(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    label: Text(
                      actions.firstWhere(
                        (a) => a["id"] == selectedActionId,
                      )["name"],
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    deleteIcon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 16,
                    ),
                    onDeleted: () {
                      setState(() {
                        selectedActionId = null;
                      });
                      _loadActivities();
                    },
                  ),

                if (selectedRange != null)
                  Chip(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    label: Text(
                      "${selectedRange!.start.day}/${selectedRange!.start.month} → "
                      "${selectedRange!.end.day}/${selectedRange!.end.month}",
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    deleteIcon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 16,
                    ),
                    onDeleted: () {
                      setState(() {
                        selectedRange = null;
                      });
                      _loadActivities();
                    },
                  ),

                if (selectedContactId != null)
                  Chip(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    label: Text(
                      contacts.firstWhere(
                        (c) => c["id"] == selectedContactId,
                      )["name"],
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    deleteIcon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 16,
                    ),
                    onDeleted: () {
                      setState(() {
                        selectedContactId = null;
                      });
                      _loadActivities();
                    },
                  ),

                if (selectedProductId != null)
                  Chip(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    label: Text(
                      products.firstWhere(
                        (p) => p["id"] == selectedProductId,
                      )["name"],
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    deleteIcon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 16,
                    ),
                    onDeleted: () {
                      setState(() {
                        selectedProductId = null;
                      });
                      _loadActivities();
                    },
                  ),
              ],
            ),
          ),

        /// CONTENIDO
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : activities.isEmpty
                  ? const Center(
                      child: Text("No hay actividades registradas"),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 10),
                      itemCount: activities.length,
                      itemBuilder: (_, i) {
                        final activity = activities[i];
                        return ActivityHistoryCard(
                          activity: activity,

                          onEdit: () => _openEditDialog(activity),

                          onDelete: () => _deleteActivity(activity),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Future<void> _openEditDialog(Map activity) async {

    final result = await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Editar actividad",
      barrierColor: Colors.black.withOpacity(0.25),
      transitionDuration: const Duration(milliseconds: 220),

      pageBuilder: (_, __, ___) {
        return Center(
          child: EditActivityDialog(activity: activity),
        );
      },
    );

    if (result == true) {
      _loadActivities();
    }

  }

 Future<void> _deleteActivity(Map activity) async {

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 420),
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
                      onPressed: () => Navigator.pop(context, false),
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
                      onPressed: () => Navigator.pop(context, true),
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

      _loadActivities();

    }
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

class ActivityHistoryCard extends StatelessWidget {

  final Map activity;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const ActivityHistoryCard({
    super.key,
    required this.activity,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {

    final type = activity["accion"] ?? "Actividad";
    final color = getActivityColor(type);

    final client = activity["cliente"] ?? "";
    final contact = activity["contacto"] ?? "";

    final date = DateTime.tryParse(activity["fecha"] ?? "");

    final time = date != null
        ? "${date.day}/${date.month}/${date.year} · "
          "${date.hour.toString().padLeft(2,'0')}:"
          "${date.minute.toString().padLeft(2,'0')}"
        : "";

    final products = activity["products"] ?? [];

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 14,
            offset: const Offset(0,6),
          )
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          /// BARRA COLOR
          Container(
            width: 4,
            height: 90,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
            ),
          ),

          const SizedBox(width: 16),

          /// CONTENIDO
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                /// HEADER
                Row(
                  children: [

                    Expanded(
                      child: Text(
                        type,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: AppColors.primary,
                        ),
                      ),
                    ),

                    Text(
                      time,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                  ],
                ),

                const SizedBox(height: 6),

                /// CLIENTE
                if (client.isNotEmpty)
                  Text(
                    client,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
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
                        fontSize: 13,
                        color: Colors.grey,
                      ),
                    ),
                  ),

                const SizedBox(height: 8),

                /// PRODUCTOS
                if (products.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: products.map<Widget>((p) {

                      final name =
                          p["product_raw"] ??
                          p["name"] ??
                          "";

                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          name,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                      );

                    }).toList(),
                  ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          /// ACCIONES
          Column(
            children: [

              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: "Editar",
                onPressed: onEdit,
              ),

              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: "Eliminar",
                onPressed: onDelete,
              ),

            ],
          )
        ],
      ),
    );
  }
}