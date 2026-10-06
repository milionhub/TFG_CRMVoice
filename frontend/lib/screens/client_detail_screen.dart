// Ficha de cliente (H.3): datos, contactos, actividades del comercial,
// ventas del comercial y resumen comercial (GET /clients/{id}).
//
// Las actividades se piden con GET /activities?client_id= (trae todo lo
// necesario para editarlas; recent_activities de la ficha no lo trae).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_colors.dart';
import '../core/money.dart';
import '../models/crm.dart';
import '../services/api_service.dart';
import '../widgets/crm/activity_actions.dart';
import '../widgets/crm/activity_form.dart';
import '../widgets/crm/client_form.dart';
import '../widgets/crm/crm_ui.dart';
import '../widgets/crm/sale_form.dart';

class ClientDetailScreen extends StatefulWidget {
  final int clientId;

  const ClientDetailScreen({super.key, required this.clientId});

  @override
  State<ClientDetailScreen> createState() => _ClientDetailScreenState();
}

class _ClientDetailScreenState extends State<ClientDetailScreen> {
  static const _collapsedActivities = 8;

  ClientDetail? _detail;
  List<CrmActivity> _activities = const [];
  bool _loading = true;
  String? _error;
  bool _showAllActivities = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<ApiService>();
    try {
      final results = await Future.wait<Object>([
        api.getClientDetail(widget.clientId),
        api.listActivities(clientId: widget.clientId),
      ]);
      if (!mounted || request != _request) return;
      setState(() {
        _detail = results[0] as ClientDetail;
        _activities = results[1] as List<CrmActivity>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = e is ApiException && e.kind == ApiErrorKind.notFound ? 'Cliente no encontrado.' : userMessage(e);
        _loading = false;
      });
    }
  }

  Client get _client => _detail!.client;

  CatalogItem get _clientItem => CatalogItem(_client.id, _client.name);

  Future<void> _editClient() async {
    final result = await openClientForm(context, client: _client);
    if (result == null || !mounted) return;
    showSuccess(context, 'Cliente actualizado');
    _load();
  }

  Future<void> _contactForm([Contact? contact]) async {
    final saved = await openContactForm(context, clientId: _client.id, clientName: _client.name, contact: contact);
    if (saved == null || !mounted) return;
    showSuccess(context, contact == null ? 'Contacto «${saved.name}» creado' : 'Contacto actualizado');
    _load();
  }

  Future<void> _activityForm([CrmActivity? activity]) async {
    final outcome = await openActivityForm(context, activity: activity, client: _clientItem);
    if (outcome != null && mounted) _load();
  }

  Future<void> _saleForm([Sale? sale]) async {
    final saved = await openSaleForm(context, client: _client, contacts: _detail!.contacts, sale: sale);
    if (saved == true && mounted) _load();
  }

  Future<void> _deleteSale(Sale sale) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Eliminar venta',
      message: '¿Eliminar la venta «${sale.label}» de ${formatEuros(sale.amountCents)}? No se puede deshacer.',
    );
    if (!confirmed || !mounted) return;
    try {
      await context.read<ApiService>().deleteSale(sale.id);
      if (!mounted) return;
      showSuccess(context, 'Venta eliminada');
      _load();
    } catch (e) {
      if (mounted) showFailure(context, userMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return CrmTheme(
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.white,
          title: Text(detail?.client.name ?? 'Cliente', overflow: TextOverflow.ellipsis),
          actions: [
            if (detail != null)
              IconButton(tooltip: 'Actualizar', icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
            if (detail != null)
              IconButton(tooltip: 'Editar cliente', icon: const Icon(Icons.edit_outlined), onPressed: _editClient),
          ],
          bottom: detail != null && _loading
              ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
              : null,
        ),
        body: SafeArea(
          child: detail == null
              ? (_error != null ? ErrorView(message: _error!, onRetry: _load) : const LoadingView())
              : _content(detail),
        ),
      ),
    );
  }

  Widget _content(ClientDetail detail) {
    final info = _infoSection(detail.client);
    final summary = _summarySection(detail);
    final contacts = _contactsSection(detail.contacts);
    final activities = _activitiesSection();
    final sales = _salesSection(detail);
    const gap = SizedBox(height: 16);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1000;
        return SingleChildScrollView(
          padding: EdgeInsets.all(wide ? 24 : 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                FormErrorBanner(message: 'No se pudo actualizar la ficha: $_error'),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: Column(children: [info, gap, summary, gap, contacts])),
                    const SizedBox(width: 16),
                    Expanded(flex: 3, child: Column(children: [activities, gap, sales])),
                  ],
                )
              else
                Column(children: [info, gap, summary, gap, contacts, gap, activities, gap, sales]),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- Datos

  Widget _infoSection(Client c) {
    Widget row(IconData icon, String label, String? value) => value == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 8),
                SizedBox(
                    width: 80,
                    child: Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13))),
                Expanded(child: SelectableText(value)),
              ],
            ),
          );
    final hasData = [c.location, c.phone, c.email, c.cif, c.groupName].any((v) => v != null);
    return SectionCard(
      title: 'Datos del cliente',
      icon: Icons.business,
      action: TextButton.icon(onPressed: _editClient, icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Editar')),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          if (c.alias != null)
            Text(c.alias!, style: const TextStyle(color: AppColors.textSecondary)),
          row(Icons.place_outlined, 'Ubicación', c.location),
          row(Icons.phone_outlined, 'Teléfono', c.phone),
          row(Icons.email_outlined, 'Email', c.email),
          row(Icons.badge_outlined, 'CIF', c.cif),
          row(Icons.account_tree_outlined, 'Grupo', c.groupName),
          if (!hasData)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Sin datos de contacto ni ubicación.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------ Resumen comercial

  Widget _summarySection(ClientDetail d) {
    final r = d.revenue;
    Widget figure(String label, String help, int cents, int lines, {bool strong = false}) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: TextStyle(fontWeight: strong ? FontWeight.w700 : FontWeight.w600)),
                    Text(help, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(formatEuros(cents),
                  style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.w600, fontSize: strong ? 16 : 14)),
            ],
          ),
        );
    return SectionCard(
      title: 'Resumen comercial',
      icon: Icons.insights_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          figure('Tus ventas registradas', '${r.mySalesLines} líneas registradas por ti en CRMVoice',
              r.mySalesCents, r.mySalesLines),
          figure('Facturación histórica', '${r.invoiceLines} líneas de factura del cliente (de todos los comerciales)',
              r.invoicesCents, r.invoiceLines),
          const Divider(height: 20),
          figure('Total', 'Facturas históricas + tus ventas', r.totalCents, 0, strong: true),
          if (d.discussedProducts.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Productos tratados en tus actividades',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final p in d.discussedProducts) Chip(label: Text(p), visualDensity: VisualDensity.compact)],
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------- Contactos

  Widget _contactsSection(List<Contact> contacts) {
    return SectionCard(
      title: 'Contactos (${contacts.length})',
      icon: Icons.people_outline,
      action: TextButton.icon(
        onPressed: () => _contactForm(),
        icon: const Icon(Icons.person_add_alt, size: 18),
        label: const Text('Añadir'),
      ),
      child: contacts.isEmpty
          ? const Text('Este cliente no tiene contactos.', style: TextStyle(color: AppColors.textSecondary))
          : Column(
              children: [
                for (final c in contacts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const CircleAvatar(radius: 16, child: Icon(Icons.person, size: 18)),
                    title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      [if (c.role != null) c.role!, if (c.phone != null) c.phone!, if (c.email != null) c.email!]
                          .join(' · ')
                          .ifEmpty('Sin cargo ni datos de contacto'),
                    ),
                    trailing: IconButton(
                      tooltip: 'Editar contacto',
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: () => _contactForm(c),
                    ),
                  ),
              ],
            ),
    );
  }

  // ----------------------------------------------------------- Actividades

  Widget _activitiesSection() {
    final all = _activities;
    final visible = _showAllActivities ? all : all.take(_collapsedActivities).toList();
    final pending = all.where((a) => a.status == ActivityStatus.pending).length;
    return SectionCard(
      title: 'Tus actividades (${all.length})',
      icon: Icons.event_note_outlined,
      action: TextButton.icon(
        onPressed: () => _activityForm(),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Nueva'),
      ),
      child: all.isEmpty
          ? const Text('No tienes actividades con este cliente.', style: TextStyle(color: AppColors.textSecondary))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pending > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('$pending pendiente${pending == 1 ? '' : 's'}',
                        style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                  ),
                for (final a in visible) _activityTile(a),
                if (all.length > _collapsedActivities)
                  TextButton(
                    onPressed: () => setState(() => _showAllActivities = !_showAllActivities),
                    child: Text(_showAllActivities ? 'Ver menos' : 'Ver todas (${all.length})'),
                  ),
              ],
            ),
    );
  }

  Widget _activityTile(CrmActivity a) {
    final color = getActivityColor(a.activityType ?? '');
    return InkWell(
      onTap: () => _activityForm(a),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: color, width: 3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(a.activityType ?? 'Actividad', style: const TextStyle(fontWeight: FontWeight.w700)),
                      StatusBadge(status: a.status, overdue: a.isOverdue),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [formatDateTime(a.datetime), if (a.contactName != null) a.contactName!].join(' · '),
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                  if (a.comment != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(a.comment!, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ),
            ActivityActionsMenu(activity: a, onEdit: () => _activityForm(a), onChanged: _load),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- Ventas

  Widget _salesSection(ClientDetail d) {
    final sales = d.sales;
    return SectionCard(
      title: 'Tus ventas',
      icon: Icons.point_of_sale_outlined,
      action: TextButton.icon(
        onPressed: () => _saleForm(),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Registrar venta'),
      ),
      child: sales.isEmpty
          ? const Text('No has registrado ventas a este cliente.', style: TextStyle(color: AppColors.textSecondary))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in sales)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      s.quantity != null ? '${s.label} × ${s.quantity}' : s.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text([
                      formatIsoDate(s.saleDate),
                      if (s.contactName != null) s.contactName!,
                      if (s.notes != null) s.notes!,
                    ].join(' · ')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(formatEuros(s.amountCents), style: const TextStyle(fontWeight: FontWeight.w700)),
                        PopupMenuButton<String>(
                          tooltip: 'Acciones',
                          onSelected: (v) => v == 'edit' ? _saleForm(s) : _deleteSale(s),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'edit',
                              child: ListTile(dense: true, leading: Icon(Icons.edit_outlined), title: Text('Editar')),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                dense: true,
                                leading: Icon(Icons.delete_outline, color: Color(0xFFB91C1C)),
                                title: Text('Eliminar venta'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (sales.length >= 20)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('Se muestran tus 20 ventas más recientes.',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ),
              ],
            ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
