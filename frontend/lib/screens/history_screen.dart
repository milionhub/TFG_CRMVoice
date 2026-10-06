import 'package:flutter/material.dart';
import '../core/app_colors.dart';
import 'home_screen.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../models/crm.dart';
import '../widgets/crm/activity_actions.dart';
import '../widgets/crm/activity_form.dart';
import '../widgets/crm/crm_ui.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Shell común (I.2): barra lateral en escritorio, cabecera + menú en móvil
    return const AppShell(
      currentIndex: 3,
      title: "Histórico",
      backgroundColor: AppColors.background,
      body: HistoryContent(),
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
  String? loadError;
  List<CrmActivity> activities = [];
  int _request = 0;

  /// Filtro por estado (Activity V2): lo aplica el backend.
  ActivityStatus? selectedStatus;

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
    final request = ++_request;

    setState(() {
      loading = true;
      loadError = null;
    });

    try {
      final data = await api.getActivities(
        clientId: selectedClientId,
        actionId: selectedActionId,
        dateFrom: selectedRange?.start.toIso8601String().split("T").first,
        dateTo: selectedRange?.end.toIso8601String().split("T").first,
        status: selectedStatus?.api,
      );

      List filtered = data;

      if (selectedContactId != null) {
        filtered = filtered.where((a) =>
            a["contact_id"] == selectedContactId).toList();
      }

      if (selectedProductId != null) {

        final productName = products.firstWhere(
          (p) => p["id"] == selectedProductId,
          orElse: () => {"name": null},
        )["name"];

        filtered = filtered.where((a) {

          final prods = a["products"] ?? [];

          return prods.any((p) =>
              p["product_id"] == selectedProductId ||
              (productName != null && p["product_raw"] == productName));

        }).toList();

      }

      if (!mounted || request != _request) return;
      setState(() {
        activities = CrmActivity.listFrom(filtered);
        loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        loadError = "No se pudieron cargar las actividades.";
        loading = false;
      });
    }

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

  String _chipLabel(List<dynamic> items, int id) {
    final match = items.where((i) => i["id"] == id);
    return match.isEmpty ? "#$id" : "${match.first["name"]}";
  }

  Widget _filterChip(String label, VoidCallback onDeleted) {
    return Chip(
      backgroundColor: AppColors.primary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      label: Text(
        label,
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
      onDeleted: onDeleted,
    );
  }

  @override
  Widget build(BuildContext context) {

    return CrmTheme(
      child: Column(
        children: [

          /// HEADER
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 8,
              children: [

                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Histórico CRM",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      "Registro completo de actividades",
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),

                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [

                    FilledButton.icon(
                      onPressed: _createActivity,
                      icon: const Icon(Icons.add),
                      label: const Text("Nueva actividad"),
                    ),

                    IconButton(
                      icon: const Icon(Icons.filter_alt_outlined),
                      tooltip: "Filtros",
                      onPressed: _openFilters,
                    ),

                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: "Actualizar",
                      onPressed: _loadActivities,
                    ),

                  ],
                ),
              ],
            ),
          ),

          /// FILTRO POR ESTADO
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              children: [
                for (final status in <ActivityStatus?>[null, ...ActivityStatus.values])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(status == null ? "Todas" : "${status.label}s"),
                      selected: selectedStatus == status,
                      onSelected: (_) {
                        if (selectedStatus == status) return;
                        setState(() => selectedStatus = status);
                        _loadActivities();
                      },
                    ),
                  ),
              ],
            ),
          ),

          if (selectedClientId != null ||
              selectedActionId != null ||
              selectedContactId != null ||
              selectedProductId != null ||
              selectedRange != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [

                  if (selectedClientId != null)
                    _filterChip(_chipLabel(clients, selectedClientId!), () {
                      setState(() => selectedClientId = null);
                      _loadActivities();
                    }),

                  if (selectedActionId != null)
                    _filterChip(_chipLabel(actions, selectedActionId!), () {
                      setState(() => selectedActionId = null);
                      _loadActivities();
                    }),

                  if (selectedRange != null)
                    _filterChip(
                      "${selectedRange!.start.day}/${selectedRange!.start.month} → "
                      "${selectedRange!.end.day}/${selectedRange!.end.month}",
                      () {
                        setState(() => selectedRange = null);
                        _loadActivities();
                      },
                    ),

                  if (selectedContactId != null)
                    _filterChip(_chipLabel(contacts, selectedContactId!), () {
                      setState(() => selectedContactId = null);
                      _loadActivities();
                    }),

                  if (selectedProductId != null)
                    _filterChip(_chipLabel(products, selectedProductId!), () {
                      setState(() => selectedProductId = null);
                      _loadActivities();
                    }),
                ],
              ),
            ),

          /// CONTENIDO
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : loadError != null
                    ? ErrorView(message: loadError!, onRetry: _loadActivities)
                    : activities.isEmpty
                        ? const Center(
                            child: Text("No hay actividades registradas"),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 10),
                            itemCount: activities.length,
                            itemBuilder: (_, i) {
                              final activity = activities[i];
                              return ActivityHistoryCard(
                                activity: activity,
                                onEdit: () => _openEditDialog(activity),
                                onDelete: () => _deleteActivity(activity),
                                onChanged: _loadActivities,
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  Future<void> _createActivity() async {
    final outcome = await openActivityForm(context);
    if (outcome != null && mounted) _loadActivities();
  }

  Future<void> _openEditDialog(CrmActivity activity) async {
    final outcome = await openActivityForm(context, activity: activity);
    if (outcome != null && mounted) _loadActivities();
  }

  Future<void> _deleteActivity(CrmActivity activity) async {
    if (await deleteActivityWithConfirmation(context, activity) && mounted) {
      _loadActivities();
    }
  }
}

class ActivityHistoryCard extends StatelessWidget {

  final CrmActivity activity;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onChanged;

  const ActivityHistoryCard({
    super.key,
    required this.activity,
    required this.onEdit,
    required this.onDelete,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {

    final type = activity.activityType ?? "Actividad";
    final color = getActivityColor(type);
    final cancelled = activity.status == ActivityStatus.cancelled;

    final client = activity.clientName ?? "";
    final contact = activity.contactName ?? "";
    final date = activity.datetime;

    final time = date != null
        ? "${date.day}/${date.month}/${date.year} · "
          "${date.hour.toString().padLeft(2,'0')}:"
          "${date.minute.toString().padLeft(2,'0')}"
        : "";

    final products = [
      ...activity.products.map((p) => p.name),
      ...activity.unlinkedProducts,
    ];

    return Opacity(
      opacity: cancelled ? 0.65 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 18),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
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
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        type,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: AppColors.primary,
                          decoration: cancelled ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      StatusBadge(status: activity.status, overdue: activity.isOverdue),
                    ],
                  ),

                  const SizedBox(height: 4),

                  Text(
                    time,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w500,
                    ),
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

                  /// COMENTARIO
                  if (activity.comment != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        activity.comment!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                      ),
                    ),

                  const SizedBox(height: 8),

                  /// PRODUCTOS
                  if (products.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: products.map<Widget>((name) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
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

            const SizedBox(width: 8),

            /// ACCIONES
            Column(
              children: [

                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: "Editar",
                  onPressed: onEdit,
                ),

                PopupMenuButton<ActivityStatus>(
                  tooltip: "Cambiar estado",
                  icon: const Icon(Icons.flag_outlined),
                  onSelected: (status) async {
                    if (await changeActivityStatus(context, activity, status) != null) {
                      onChanged();
                    }
                  },
                  itemBuilder: (_) => [
                    for (final status in activity.allowedTransitions)
                      PopupMenuItem(
                        value: status,
                        child: Text(statusActionLabel(status)),
                      ),
                  ],
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
      ),
    );
  }
}
