// Actividades (antes «Histórico»): listado completo con filtro por estado,
// filtros avanzados, alta, edición, cambio de estado y borrado.
//
// I.4.1: cabecera de página, selector de estado segmentado, acceso a
// «Filtros», filtros activos como pastillas y una única superficie con filas
// compactas. La fila muestra los productos asociados como metadato discreto;
// por densidad no muestra el comentario (se ve al editar). El diálogo de
// filtros, el menú «⋮» y los formularios mantienen su estilo hasta la fase
// común de diálogos.
// Internamente se conserva el nombre History*.
import 'package:flutter/material.dart';
import '../core/app_colors.dart';
import '../core/design/cv_theme.dart';
import '../core/design/cv_tokens.dart';
import 'home_screen.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../models/crm.dart';
import '../widgets/crm/activity_form.dart';
import '../widgets/crm/activity_list.dart';
import '../widgets/crm/crm_ui.dart';
import '../widgets/ui/cv_components.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Shell común (I.2): barra lateral en escritorio, cabecera + menú en móvil
    return const AppShell(
      currentIndex: 3,
      title: "Actividades",
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

  int get _activeFilterCount => [
        selectedClientId,
        selectedActionId,
        selectedContactId,
        selectedProductId,
        selectedRange,
      ].where((f) => f != null).length;

  void _selectStatus(ActivityStatus? status) {
    if (selectedStatus == status) return;
    setState(() => selectedStatus = status);
    _loadActivities();
  }

  /// Quita estado y filtros avanzados (lo mismo que «Limpiar» del diálogo).
  void _clearAllFilters() {
    setState(() {
      selectedStatus = null;
      selectedClientId = null;
      selectedActionId = null;
      selectedContactId = null;
      selectedProductId = null;
      selectedRange = null;
    });
    _loadActivities();
  }

  @override
  Widget build(BuildContext context) {
    return CrmTheme(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final insets = CvPageBody.insets(constraints.maxWidth);
          final compact = constraints.maxWidth < CvBreakpoints.tablet;
          return RefreshIndicator(
            onRefresh: _loadActivities,
            color: CvColors.primaryDark,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(insets.left, insets.top, insets.right, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        CvPageHeader(
                          title: "Actividades",
                          subtitle: "Gestiona y consulta toda tu actividad comercial.",
                          action: _headerActions(compact),
                        ),
                        const SizedBox(height: CvSpace.xl),
                        _toolbar(compact),
                        if (_activeFilterCount > 0) ...[
                          const SizedBox(height: CvSpace.sm),
                          _activeFilters(),
                        ],
                        const SizedBox(height: CvSpace.lg),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(insets.left, 0, insets.right, insets.bottom),
                  sliver: _body(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// «Nueva actividad» es la acción principal; «Actualizar» queda discreta
  /// (en móvil basta con deslizar hacia abajo).
  Widget _headerActions(bool compact) {
    final create = CvPrimaryButton(label: "Nueva actividad", icon: Icons.add_rounded, onPressed: _createActivity);
    if (compact) return create;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: "Actualizar",
          onPressed: _loadActivities,
          icon: const Icon(Icons.refresh_rounded, size: 20, color: CvColors.textSecondary),
        ),
        const SizedBox(width: CvSpace.xs),
        create,
      ],
    );
  }

  /// Estado (segmentado) y acceso a los filtros avanzados.
  Widget _toolbar(bool compact) {
    final count = _activeFilterCount;
    final filters = CvSecondaryButton(
      key: const Key('activities-filters'),
      label: count == 0 ? "Filtros" : "Filtros ($count)",
      icon: Icons.tune_rounded,
      tooltip: "Filtrar actividades",
      onPressed: _openFilters,
    );
    final status = ActivityStatusFilter(selected: selectedStatus, onSelected: _selectStatus);

    if (compact) {
      // Móvil: el selector ocupa todo el ancho con las cuatro opciones completas
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ActivityStatusFilter(selected: selectedStatus, onSelected: _selectStatus, expand: true),
          const SizedBox(height: CvSpace.sm),
          filters,
        ],
      );
    }
    return Row(
      children: [
        Flexible(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: status)),
        const SizedBox(width: CvSpace.md),
        filters,
      ],
    );
  }

  Widget _activeFilters() {
    void remove(VoidCallback clear) {
      setState(clear);
      _loadActivities();
    }

    return Wrap(
      key: const Key('active-filters'),
      spacing: CvSpace.xs,
      runSpacing: CvSpace.xs,
      children: [
        if (selectedClientId != null)
          ActiveFilterChip(
            label: _chipLabel(clients, selectedClientId!),
            onRemove: () => remove(() => selectedClientId = null),
          ),
        if (selectedActionId != null)
          ActiveFilterChip(
            label: _chipLabel(actions, selectedActionId!),
            onRemove: () => remove(() => selectedActionId = null),
          ),
        if (selectedRange != null)
          ActiveFilterChip(
            label: "${selectedRange!.start.day}/${selectedRange!.start.month} → "
                "${selectedRange!.end.day}/${selectedRange!.end.month}",
            onRemove: () => remove(() => selectedRange = null),
          ),
        if (selectedContactId != null)
          ActiveFilterChip(
            label: _chipLabel(contacts, selectedContactId!),
            onRemove: () => remove(() => selectedContactId = null),
          ),
        if (selectedProductId != null)
          ActiveFilterChip(
            label: _chipLabel(products, selectedProductId!),
            onRemove: () => remove(() => selectedProductId = null),
          ),
      ],
    );
  }

  /// Estados: carga inicial, error, vacío (con o sin filtros) y listado
  /// (al recargar se mantiene el listado con una barra de progreso fina).
  Widget _body() {
    if (loading && activities.isEmpty) {
      return const SliverToBoxAdapter(
        child: CvStatePanel(
          icon: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: CvColors.primaryDark),
          ),
          title: "Cargando actividades…",
        ),
      );
    }
    if (loadError != null && !loading) {
      return SliverToBoxAdapter(
        child: CvStatePanel(
          icon: const Icon(Icons.cloud_off_outlined),
          title: loadError!,
          message: "Comprueba la conexión e inténtalo de nuevo.",
          action: CvSecondaryButton(label: "Reintentar", icon: Icons.refresh_rounded, onPressed: _loadActivities),
        ),
      );
    }
    if (activities.isEmpty) {
      final filtered = selectedStatus != null || _activeFilterCount > 0;
      return SliverToBoxAdapter(
        child: filtered
            ? CvStatePanel(
                icon: const Icon(Icons.filter_alt_off_outlined),
                title: "No hay actividades con estos filtros.",
                message: "Prueba con otro estado o quita algún filtro.",
                action: TextButton(
                  onPressed: _clearAllFilters,
                  style: TextButton.styleFrom(foregroundColor: CvColors.primaryDark),
                  child: const Text("Quitar filtros"),
                ),
              )
            : const CvStatePanel(
                icon: Icon(Icons.event_note_outlined),
                title: "Aún no tienes actividades.",
                message: "Registra la primera con «Nueva actividad» o por voz desde Inicio.",
              ),
      );
    }

    final n = activities.length;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(left: 2, bottom: CvSpace.sm),
            child: Row(
              children: [
                Text(
                  n == 1 ? "1 actividad" : "$n actividades",
                  key: const Key('activities-count'),
                  style: CvText.helper.copyWith(fontSize: 13),
                ),
                if (loading) ...[
                  const SizedBox(width: CvSpace.sm),
                  const SizedBox(
                    width: 64,
                    child: LinearProgressIndicator(minHeight: 2, color: CvColors.primary),
                  ),
                ],
              ],
            ),
          ),
        ),
        CvSliverListSurface(
          itemCount: n,
          itemBuilder: (context, i) {
            final activity = activities[i];
            return ActivityListRow(
              key: ValueKey('activity-${activity.id}'),
              activity: activity,
              onEdit: () => _openEditDialog(activity),
              onChanged: _loadActivities,
            );
          },
        ),
      ],
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
}
