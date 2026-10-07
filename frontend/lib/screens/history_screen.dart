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
import '../core/design/cv_theme.dart';
import '../core/design/cv_tokens.dart';
import 'home_screen.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../models/crm.dart';
import '../widgets/crm/activity_form.dart';
import '../widgets/crm/activity_list.dart';
import '../widgets/crm/crm_ui.dart';
import '../widgets/crm/form_shell.dart';
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

  /// Filtros avanzados (I.6.2): mismo contenedor que los formularios —
  /// diálogo compacto en escritorio y panel inferior en móvil. La lógica es
  /// la de siempre: «Aplicar filtros» fija los valores y recarga; «Limpiar»
  /// los quita y recarga sin cerrar.
  void _openFilters() {

    int? client = selectedClientId;
    int? action = selectedActionId;
    int? contact = selectedContactId;
    int? product = selectedProductId;
    DateTimeRange? range = selectedRange;
    // «Limpiar» vuelve a crear los campos para que se vean vacíos
    var generation = 0;

    String rangeLabel(DateTimeRange r) =>
        "${r.start.day}/${r.start.month}/${r.start.year} – ${r.end.day}/${r.end.month}/${r.end.year}";

    openCrmForm<void>(
      context,
      sheetOnMobile: true,
      StatefulBuilder(
        builder: (context, setModalState) {
          return CrmFormShell(
            title: "Filtrar actividades",
            maxWidth: 520,
            leading: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: CvColors.textSecondary,
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: CvSpace.sm),
              ),
              onPressed: () {

                setModalState(() {

                  client = null;
                  action = null;
                  contact = null;
                  product = null;
                  range = null;
                  contacts = [];
                  generation++;

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
              child: const Text("Limpiar"),
            ),
            actions: [
              CvPrimaryButton(
                label: "Aplicar filtros",
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
              ),
            ],
            body: FormSections(
              key: ValueKey('filters-$generation'),
              children: [
                FormSection(
                  title: "Cliente y contacto",
                  children: [
                    /// CLIENTE
                    DropdownButtonFormField<int>(
                      initialValue: client,
                      isExpanded: true,
                      icon: cvSelectChevron,
                      decoration: const InputDecoration(
                        labelText: "Cliente",
                        prefixIcon: Icon(Icons.business_outlined),
                      ),
                      items: clients.map<DropdownMenuItem<int>>((c) {
                        return DropdownMenuItem(
                          value: c["id"],
                          child: Text(c["name"], overflow: TextOverflow.ellipsis),
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

                    /// CONTACTO
                    DropdownButtonFormField<int>(
                      key: ValueKey('filter-contact-$client-${contacts.length}'),
                      initialValue: contact,
                      isExpanded: true,
                      icon: cvSelectChevron,
                      decoration: InputDecoration(
                        labelText: "Contacto",
                        prefixIcon: const Icon(Icons.person_outline),
                        helperText: client == null ? "Elige antes el cliente" : null,
                      ),
                      items: contacts.map<DropdownMenuItem<int>>((c) {
                        return DropdownMenuItem(
                          value: c["id"],
                          child: Text(c["name"], overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: client == null ? null : (v) {
                        setModalState(() {
                          contact = v;
                        });
                      },
                    ),
                  ],
                ),
                FormSection(
                  title: "Actividad",
                  children: [
                    /// ACCIÓN
                    DropdownButtonFormField<int>(
                      initialValue: action,
                      isExpanded: true,
                      icon: cvSelectChevron,
                      decoration: const InputDecoration(
                        labelText: "Acción",
                        prefixIcon: Icon(Icons.flash_on_outlined),
                      ),
                      items: actions.map<DropdownMenuItem<int>>((a) {
                        return DropdownMenuItem(
                          value: a["id"],
                          child: Text(a["name"], overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (v) {
                        action = v;
                      },
                    ),

                    /// PRODUCTO
                    DropdownButtonFormField<int>(
                      initialValue: product,
                      isExpanded: true,
                      icon: cvSelectChevron,
                      decoration: const InputDecoration(
                        labelText: "Producto",
                        prefixIcon: Icon(Icons.inventory_2_outlined),
                      ),
                      items: products.map<DropdownMenuItem<int>>((p) {
                        return DropdownMenuItem(
                          value: p["id"],
                          child: Text(p["name"], overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (v) {
                        product = v;
                      },
                    ),

                    /// FECHAS
                    TapField(
                      key: const Key('filter-range-field'),
                      label: "Rango de fechas",
                      value: range == null ? null : rangeLabel(range!),
                      placeholder: "Cualquier fecha",
                      icon: Icons.date_range_outlined,
                      onTap: () async {

                        final r = await showDateRangePicker(
                          context: context,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                          initialDateRange: range,
                        );

                        if (r != null) {
                          setModalState(() => range = r);
                        }

                      },
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
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
