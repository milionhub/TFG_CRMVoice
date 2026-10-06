// Formulario ÚNICO de actividad (H.3, Activity V2): alta manual y edición
// desde Histórico, Calendario y la ficha de cliente. POST/PUT /activities
// con el cuerpo V2 (ActivityIn); el borrado y los cambios de estado rápidos
// están en activity_actions.dart.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_colors.dart';
import '../../models/crm.dart';
import '../../services/api_service.dart';
import 'activity_actions.dart';
import 'crm_ui.dart';
import 'form_shell.dart';

enum ActivityFormOutcome { saved, deleted }

/// Abre el formulario. [activity] = edición; [client] fija el cliente (ficha);
/// [initialDate] = día propuesto para una actividad nueva (calendario).
Future<ActivityFormOutcome?> openActivityForm(
  BuildContext context, {
  CrmActivity? activity,
  CatalogItem? client,
  DateTime? initialDate,
}) =>
    openCrmForm<ActivityFormOutcome>(
        context, ActivityForm(activity: activity, fixedClient: client, initialDate: initialDate));

class ActivityForm extends StatefulWidget {
  final CrmActivity? activity;
  final CatalogItem? fixedClient;
  final DateTime? initialDate;

  const ActivityForm({super.key, this.activity, this.fixedClient, this.initialDate});

  @override
  State<ActivityForm> createState() => _ActivityFormState();
}

class _ActivityFormState extends State<ActivityForm> {
  static const maxProducts = 10;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _comment = TextEditingController(text: widget.activity?.comment);

  // Catálogos
  bool _loading = true;
  String? _loadError;
  List<CatalogItem> _clients = const [];
  List<CatalogItem> _types = const [];
  List<CatalogItem> _products = const [];
  List<CatalogItem> _contacts = const [];
  bool _loadingContacts = false;
  int _contactsRequest = 0;

  // Valores
  CatalogItem? _client;
  int? _contactId;
  int? _typeId;
  late DateTime _datetime;
  late ActivityStatus _status;
  late List<CatalogItem> _selectedProducts;

  bool _saving = false;
  ApiException? _error;
  bool _submitted = false;

  bool get _isEdit => widget.activity != null;

  @override
  void initState() {
    super.initState();
    final a = widget.activity;
    if (a != null) {
      _client = a.clientId != null ? CatalogItem(a.clientId!, a.clientName ?? 'Cliente #${a.clientId}') : null;
      _contactId = a.contactId;
      _typeId = a.activityTypeId;
      _datetime = a.datetime ?? DateTime.now();
      _status = a.status ?? ActivityStatus.pending;
      _selectedProducts = [...a.products];
    } else {
      _client = widget.fixedClient;
      final now = DateTime.now();
      final day = widget.initialDate ?? now;
      // Próxima hora en punto (o las 9:00 en otro día)
      final sameDay = day.year == now.year && day.month == now.month && day.day == now.day;
      _datetime = sameDay
          ? DateTime(now.year, now.month, now.day, now.hour).add(const Duration(hours: 1))
          : DateTime(day.year, day.month, day.day, 9);
      _status = ActivityStatus.pending;
      _selectedProducts = [];
    }
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final api = context.read<ApiService>();
    try {
      final results = await Future.wait([
        api.activityTypeItems(),
        api.productItems(),
        widget.fixedClient == null ? api.clientItems() : Future.value(const <CatalogItem>[]),
        _client == null ? Future.value(const <CatalogItem>[]) : api.contactItems(_client!.id),
      ]);
      if (!mounted) return;
      setState(() {
        _types = results[0];
        _products = results[1];
        _clients = results[2];
        _contacts = results[3];
        // Un contacto que ya no es del cliente no se conserva en silencio
        if (_contactId != null && !_contacts.any((c) => c.id == _contactId)) _contactId = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = userMessage(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _pickClient() async {
    final picked = await showSearchPicker<CatalogItem>(
      context,
      title: 'Seleccionar cliente',
      items: _clients,
      labelOf: (c) => c.name,
      hint: 'Buscar cliente...',
    );
    if (picked == null || picked.id == _client?.id || !mounted) return;
    final request = ++_contactsRequest;
    setState(() {
      _client = picked;
      _contactId = null; // el contacto siempre es del cliente elegido
      _contacts = const [];
      _loadingContacts = true;
    });
    try {
      final contacts = await context.read<ApiService>().contactItems(picked.id);
      if (mounted && request == _contactsRequest) setState(() => _contacts = contacts);
    } catch (e) {
      if (mounted) showFailure(context, 'No se pudieron cargar los contactos: ${userMessage(e)}');
    } finally {
      if (mounted && request == _contactsRequest) setState(() => _loadingContacts = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _datetime,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _datetime = DateTime(picked.year, picked.month, picked.day, _datetime.hour, _datetime.minute));
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_datetime));
    if (picked != null) {
      setState(() => _datetime = DateTime(_datetime.year, _datetime.month, _datetime.day, picked.hour, picked.minute));
    }
  }

  Future<void> _addProduct() async {
    final available = _products.where((p) => !_selectedProducts.any((s) => s.id == p.id)).toList();
    final picked = await showSearchPicker<CatalogItem>(
      context,
      title: 'Añadir producto',
      items: available,
      labelOf: (p) => p.name,
      hint: 'Buscar producto...',
    );
    if (picked != null && mounted) setState(() => _selectedProducts.add(picked));
  }

  String? get _statusProblem => _status == ActivityStatus.completed && _datetime.isAfter(DateTime.now())
      ? 'Una actividad futura no puede estar completada: márcala como pendiente.'
      : null;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _submitted = true);
    final formOk = _formKey.currentState?.validate() ?? false;
    if (!formOk || _client == null || _typeId == null || _statusProblem != null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    final input = ActivityInput(
      clientId: _client!.id,
      contactId: _contactId,
      activityTypeId: _typeId!,
      datetime: _datetime,
      status: _status,
      productIds: _selectedProducts.map((p) => p.id).toList(),
      comment: _comment.text,
    );
    final api = context.read<ApiService>();
    try {
      if (_isEdit) {
        await api.updateActivityV2(widget.activity!.id, input);
      } else {
        await api.createActivityV2(input);
      }
      if (!mounted) return;
      showSuccess(context, _isEdit ? 'Actividad actualizada' : 'Actividad creada');
      Navigator.pop(context, ActivityFormOutcome.saved);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (_saving) return;
    final deleted = await deleteActivityWithConfirmation(context, widget.activity!);
    if (deleted && mounted) Navigator.pop(context, ActivityFormOutcome.deleted);
  }

  String? _server(String field) => _error?.messageFor(field);

  @override
  Widget build(BuildContext context) {
    return CrmFormShell(
      busy: _saving,
      title: _isEdit ? 'Editar actividad' : 'Nueva actividad',
      actions: [
        if (_isEdit && !_loading)
          TextButton.icon(
            onPressed: _saving ? null : _delete,
            icon: const Icon(Icons.delete_outline, color: Color(0xFFB91C1C)),
            label: const Text('Eliminar', style: TextStyle(color: Color(0xFFB91C1C))),
          ),
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancelar')),
        SaveButton(
          saving: _saving,
          onPressed: _loading || _loadError != null ? null : _save,
          label: _isEdit ? 'Guardar cambios' : 'Crear actividad',
        ),
      ],
      body: _loading
          ? const LoadingView()
          : _loadError != null
              ? ErrorView(message: _loadError!, onRetry: _load)
              : _buildForm(),
    );
  }

  Widget _buildForm() {
    final error = _error;
    final contactItems = [
      const DropdownMenuItem<int?>(value: null, child: Text('Sin contacto')),
      ..._contacts.map((c) => DropdownMenuItem<int?>(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis))),
    ];
    final typeKnown = _typeId == null || _types.any((t) => t.id == _typeId);

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) FormErrorBanner(message: error.message, details: error.issueMessages),

          // CLIENTE
          if (widget.fixedClient != null)
            ReadOnlyField(label: 'Cliente', value: widget.fixedClient!.name, icon: Icons.business)
          else
            InkWell(
              key: const Key('activity-client-field'),
              onTap: _saving ? null : _pickClient,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Cliente *',
                  prefixIcon: const Icon(Icons.business),
                  suffixIcon: const Icon(Icons.search),
                  errorText: _server('client') ??
                      (_submitted && _client == null ? 'Selecciona un cliente' : null),
                ),
                child: Text(_client?.name ?? 'Seleccionar cliente',
                    style: TextStyle(color: _client == null ? AppColors.textSecondary : AppColors.textPrimary)),
              ),
            ),
          const SizedBox(height: 12),

          // CONTACTO (siempre del cliente elegido)
          DropdownButtonFormField<int?>(
            key: ValueKey('contact-${_client?.id}-${_contacts.length}'),
            initialValue: _contactId,
            isExpanded: true,
            items: contactItems,
            onChanged: _client == null || _loadingContacts ? null : (v) => setState(() => _contactId = v),
            decoration: InputDecoration(
              labelText: 'Contacto',
              prefixIcon: const Icon(Icons.person_outline),
              helperText: _client == null
                  ? 'Elige antes el cliente'
                  : _loadingContacts
                      ? 'Cargando contactos...'
                      : (_contacts.isEmpty ? 'Este cliente no tiene contactos' : null),
              errorText: _server('contact'),
            ),
          ),
          const SizedBox(height: 12),

          // TIPO
          DropdownButtonFormField<int>(
            key: const Key('activity-type-field'),
            initialValue: typeKnown ? _typeId : null,
            isExpanded: true,
            items: _types
                .map((t) => DropdownMenuItem<int>(value: t.id, child: Text(t.name, overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (v) => setState(() => _typeId = v),
            validator: (v) => v == null ? 'Selecciona el tipo de actividad' : null,
            decoration: InputDecoration(
              labelText: 'Tipo de actividad *',
              prefixIcon: const Icon(Icons.flash_on_outlined),
              errorText: _server('activity_type'),
            ),
          ),
          const SizedBox(height: 12),

          // FECHA + HORA
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const Key('activity-date-field'),
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Fecha *',
                      prefixIcon: const Icon(Icons.calendar_today, size: 20),
                      errorText: _server('datetime'),
                    ),
                    child: Text(formatDate(_datetime)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  key: const Key('activity-time-field'),
                  onTap: _pickTime,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Hora *',
                      prefixIcon: Icon(Icons.access_time, size: 20),
                    ),
                    child: Text(formatTime(_datetime)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ESTADO
          const Text('Estado', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          SegmentedButton<ActivityStatus>(
            showSelectedIcon: false,
            segments: [
              for (final s in ActivityStatus.values)
                ButtonSegment(value: s, label: Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            selected: {_status},
            onSelectionChanged: (v) => setState(() => _status = v.first),
          ),
          if (_statusProblem != null || _server('status') != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_server('status') ?? _statusProblem!,
                  style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 12.5)),
            )
          else if (_status == ActivityStatus.pending && !_datetime.isAfter(DateTime.now()))
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Fecha pasada: quedará como pendiente vencida.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
            ),
          const SizedBox(height: 16),

          // PRODUCTOS
          Row(
            children: [
              const Expanded(
                child: Text('Productos', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              ),
              TextButton.icon(
                onPressed: _selectedProducts.length >= maxProducts ? null : _addProduct,
                icon: const Icon(Icons.add),
                label: const Text('Añadir producto'),
              ),
            ],
          ),
          if (_selectedProducts.isEmpty)
            const Text('Sin productos', style: TextStyle(color: AppColors.textSecondary, fontSize: 13))
          else
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final p in _selectedProducts)
                  InputChip(
                    label: Text(p.name),
                    onDeleted: () => setState(() => _selectedProducts.removeWhere((s) => s.id == p.id)),
                  ),
              ],
            ),
          if (widget.activity?.unlinkedProducts.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Al guardar se quitarán los productos sin ficha de catálogo: '
                '${widget.activity!.unlinkedProducts.join(', ')}.',
                style: const TextStyle(color: Color(0xFFB45309), fontSize: 12.5),
              ),
            ),
          if (_server('products') != null)
            Text(_server('products')!, style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 12.5)),
          const SizedBox(height: 16),

          // COMENTARIO
          TextFormField(
            controller: _comment,
            minLines: 3,
            maxLines: 6,
            maxLength: 2000,
            decoration: InputDecoration(
              labelText: 'Comentario',
              alignLabelWithHint: true,
              errorText: _server('comment'),
            ),
          ),
        ],
      ),
    );
  }
}
