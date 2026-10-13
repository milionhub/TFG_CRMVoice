// Ficha de cliente (H.3): datos, contactos, actividades del comercial,
// ventas del comercial y resumen comercial (GET /clients/{id}).
//
// I.3.2: vive dentro del AppShell como subpágina de Clientes. Cabecera con
// el propio cliente, Información | Contactos, Resumen comercial, Actividad
// reciente (5 y «Ver todas») y Ventas. La lógica y los formularios no cambian.
// Por densidad, la ficha no muestra los productos tratados ni el comentario
// de cada actividad: los datos no cambian (el comentario se ve al abrirla).
//
// Las actividades se piden con GET /activities?client_id= (trae todo lo
// necesario para editarlas; recent_activities de la ficha no lo trae).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/design/cv_theme.dart';
import '../core/design/cv_tokens.dart';
import '../core/money.dart';
import '../models/crm.dart';
import '../services/api_service.dart';
import '../widgets/crm/activity_actions.dart';
import '../widgets/crm/activity_form.dart';
import '../widgets/crm/client_form.dart';
import '../widgets/crm/crm_ui.dart';
import '../widgets/crm/sale_form.dart';
import '../widgets/shell/app_shell.dart';
import '../widgets/ui/cv_components.dart';
import '../widgets/ui/cv_feedback.dart';

class ClientDetailScreen extends StatefulWidget {
  final int clientId;

  /// Nombre de la ruta cuando la ficha se abre desde el listado de Clientes
  /// («← Clientes» vuelve entonces con pop, sin recrear el listado).
  static const fromClientsRoute = 'client-detail-from-clients';

  const ClientDetailScreen({super.key, required this.clientId});

  @override
  State<ClientDetailScreen> createState() => _ClientDetailScreenState();
}

class _ClientDetailScreenState extends State<ClientDetailScreen> {
  static const _collapsedActivities = 5;

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

  /// «← Clientes»: si la ficha se abrió desde el listado, vuelve a él (que se
  /// recarga); si se abrió desde Inicio o Voz, abre la sección Clientes.
  void _backToClients() {
    final navigator = Navigator.of(context);
    final fromList = ModalRoute.of(context)?.settings.name == ClientDetailScreen.fromClientsRoute;
    if (fromList && navigator.canPop()) {
      navigator.pop();
    } else {
      replaceWithSection(navigator, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Subpágina de Clientes dentro del shell: Clientes sigue activo.
    // CrmTheme se mantiene: los formularios y menús (fuera de I.3.2) lo heredan.
    // En móvil la vuelta va en la cabecera («Atrás»), no en el contenido.
    return AppShell(
      currentIndex: 1,
      title: 'Clientes',
      sectionRoot: false,
      onBack: _backToClients,
      body: CrmTheme(child: _page()),
    );
  }

  Widget _page() {
    final detail = _detail;
    if (detail == null) {
      return CvPageBody(
        children: [
          if (!AppShell.isMobile(context)) ...[_backLink(), const SizedBox(height: CvSpace.lg)],
          _error != null
              ? CvStatePanel(
                  icon: const Icon(Icons.cloud_off_outlined),
                  title: 'No se pudo cargar la ficha.',
                  message: _error,
                  action: CvSecondaryButton(label: 'Reintentar', icon: Icons.refresh_rounded, onPressed: _load),
                )
              : const CvStatePanel(
                  icon: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: CvColors.primaryDark),
                  ),
                  title: 'Cargando ficha…',
                ),
        ],
      );
    }
    return _content(detail);
  }

  Widget _backLink() {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _backToClients,
        style: TextButton.styleFrom(
          foregroundColor: CvColors.textSecondary,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.only(left: CvSpace.xs, right: CvSpace.sm),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.sm)),
          textStyle: CvText.label.copyWith(fontSize: 13.5, fontWeight: FontWeight.w500),
          iconSize: 18,
        ),
        icon: const Icon(Icons.arrow_back_rounded),
        label: const Text('Clientes'),
      ),
    );
  }

  Widget _content(ClientDetail detail) {
    const sectionGap = SizedBox(height: 40);

    return LayoutBuilder(
      builder: (context, constraints) {
        final mobile = constraints.maxWidth < CvBreakpoints.tablet;
        final contentWidth = constraints.maxWidth - CvPageBody.insets(constraints.maxWidth).horizontal;
        final twoColumns = contentWidth >= 880;

        final info = _infoSection(detail.client);
        final contacts = _contactsSection(detail.contacts);

        return CvPageBody(
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(bottom: CvSpace.xs),
                child: LinearProgressIndicator(minHeight: 2, color: CvColors.primary),
              ),
            if (_error != null) FormErrorBanner(message: 'No se pudo actualizar la ficha: $_error'),
            _header(detail.client, mobile: mobile),
            sectionGap,
            if (twoColumns)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: info),
                  const SizedBox(width: 40),
                  Expanded(flex: 7, child: contacts),
                ],
              )
            else ...[
              info,
              sectionGap,
              contacts,
            ],
            sectionGap,
            _summarySection(detail),
            sectionGap,
            _activitiesSection(),
            sectionGap,
            _salesSection(detail),
          ],
        );
      },
    );
  }

  // ------------------------------------------------------------- Cabecera

  Widget _header(Client c, {required bool mobile}) {
    final subtitle = [if (c.alias != null) c.alias!, if (c.location != null) c.location!].join(' · ');
    final refresh = IconButton(
      tooltip: 'Actualizar',
      icon: const Icon(Icons.refresh_rounded, size: 20),
      color: CvColors.textSecondary,
      onPressed: _loading ? null : _load,
    );
    final edit = CvSecondaryButton(
      label: 'Editar',
      icon: Icons.edit_outlined,
      tooltip: 'Editar cliente',
      onPressed: _editClient,
    );
    final identity = Row(
      children: [
        CvInitialAvatar(name: c.name, size: mobile ? 44 : 52),
        const SizedBox(width: CvSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  c.name,
                  style: CvText.heading.copyWith(fontSize: mobile ? 22 : 26, letterSpacing: -0.5),
                ),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle, style: CvText.body),
              ],
            ],
          ),
        ),
      ],
    );

    if (mobile) {
      // Acciones en su propia fila (la vuelta está en la cabecera del shell):
      // el nombre usa todo el ancho
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [const Spacer(), refresh, const SizedBox(width: CvSpace.xxs), edit]),
          const SizedBox(height: CvSpace.md),
          identity,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Entre 600 y 800 px el shell ya es móvil: la vuelta va en su cabecera
        if (!AppShell.isMobile(context)) ...[_backLink(), const SizedBox(height: CvSpace.md)],
        Row(
          children: [
            Expanded(child: identity),
            const SizedBox(width: CvSpace.lg),
            refresh,
            const SizedBox(width: CvSpace.xs),
            edit,
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------ Información

  Widget _infoSection(Client c) {
    final items = [
      if (c.location != null) CvInfoItem(icon: Icons.place_outlined, label: 'Ubicación', value: c.location!),
      if (c.phone != null) CvInfoItem(icon: Icons.phone_outlined, label: 'Teléfono', value: c.phone!),
      if (c.email != null) CvInfoItem(icon: Icons.mail_outline, label: 'Email', value: c.email!),
      if (c.cif != null) CvInfoItem(icon: Icons.badge_outlined, label: 'CIF', value: c.cif!),
      if (c.groupName != null) CvInfoItem(icon: Icons.account_tree_outlined, label: 'Grupo', value: c.groupName!),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const CvSectionHeading(title: 'Información'),
        const SizedBox(height: CvSpace.sm),
        if (items.isEmpty)
          const CvEmptyNote(icon: Icons.info_outline, text: 'Sin datos de contacto ni ubicación.')
        else
          LayoutBuilder(
            builder: (context, constraints) {
              // Dos columnas de datos si hay anchura; si no, una
              final columns = constraints.maxWidth >= 520 ? 2 : 1;
              final width = (constraints.maxWidth - CvSpace.xl * (columns - 1)) / columns;
              return Wrap(
                spacing: CvSpace.xl,
                runSpacing: CvSpace.md + 2,
                children: [for (final item in items) SizedBox(width: width, child: item)],
              );
            },
          ),
      ],
    );
  }

  // ------------------------------------------------------------- Contactos

  Widget _contactsSection(List<Contact> contacts) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CvSectionHeading(
          title: 'Contactos (${contacts.length})',
          trailing: CvTextAction(label: 'Añadir', onPressed: () => _contactForm()),
        ),
        const SizedBox(height: CvSpace.sm),
        if (contacts.isEmpty)
          const CvEmptyNote(icon: Icons.people_outline, text: 'Este cliente no tiene contactos.')
        else
          CvListSurface(
            children: [
              for (final c in contacts)
                Padding(
                  padding: const EdgeInsets.fromLTRB(CvSpace.md, CvSpace.sm, CvSpace.xs, CvSpace.sm),
                  child: Row(
                    children: [
                      CvInitialAvatar(name: c.name, size: 34, circle: true),
                      const SizedBox(width: CvSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.name, style: CvText.label.copyWith(fontSize: 14)),
                            const SizedBox(height: 1),
                            Text(
                              [if (c.role != null) c.role!, if (c.phone != null) c.phone!, if (c.email != null) c.email!]
                                  .join(' · ')
                                  .ifEmpty('Sin cargo ni datos de contacto'),
                              style: CvText.helper.copyWith(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      CvRowIconButton(
                        tooltip: 'Editar contacto',
                        icon: Icons.edit_outlined,
                        onPressed: () => _contactForm(c),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }

  // ------------------------------------------------------ Resumen comercial

  static String _lines(int n, [String? participle]) =>
      '$n ${n == 1 ? 'línea' : 'líneas'}${participle == null ? '' : ' ${n == 1 ? participle : '${participle}s'}'}';

  Widget _summarySection(ClientDetail d) {
    final r = d.revenue;
    final figures = [
      _Figure('Tus ventas registradas', '${_lines(r.mySalesLines, 'registrada')} por ti en CRMVoice', r.mySalesCents),
      _Figure('Facturación histórica', '${_lines(r.invoiceLines)} de factura del cliente (de todos los comerciales)',
          r.invoicesCents),
      _Figure('Total', 'Facturas históricas + tus ventas', r.totalCents, strong: true),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const CvSectionHeading(title: 'Resumen comercial'),
        const SizedBox(height: CvSpace.sm),
        Container(
          decoration: BoxDecoration(
            color: CvColors.surface,
            borderRadius: BorderRadius.circular(CvSliverListSurface.radius),
            border: Border.all(color: CvColors.border),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 600) {
                // Tres columnas con separadores verticales suaves
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < figures.length; i++) ...[
                        if (i > 0) const VerticalDivider(width: 1, thickness: 1, color: CvColors.border),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(CvSpace.lg),
                            child: figures[i].column(),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }
              // Móvil: una cifra por fila, sin comprimir importes
              return Column(
                children: [
                  for (var i = 0; i < figures.length; i++) ...[
                    if (i > 0) const Divider(height: 1, thickness: 1, color: CvColors.border),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: CvSpace.md, vertical: CvSpace.md - 2),
                      child: figures[i].row(),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------- Actividades

  Widget _activitiesSection() {
    final all = _activities;
    final visible = _showAllActivities ? all : all.take(_collapsedActivities).toList();
    final pending = all.where((a) => a.status == ActivityStatus.pending).length;
    final meta = [
      '${all.length} actividad${all.length == 1 ? '' : 'es'}',
      if (pending > 0) '$pending pendiente${pending == 1 ? '' : 's'}',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CvSectionHeading(
          title: 'Actividad reciente',
          trailing: CvTextAction(label: 'Nueva', onPressed: () => _activityForm()),
        ),
        if (all.isNotEmpty) Text(meta, key: const Key('activities-meta'), style: CvText.helper.copyWith(fontSize: 13)),
        const SizedBox(height: CvSpace.sm),
        if (all.isEmpty)
          const CvEmptyNote(icon: Icons.event_note_outlined, text: 'No tienes actividades con este cliente.')
        else ...[
          CvListSurface(children: [for (final a in visible) _activityTile(a)]),
          if (all.length > _collapsedActivities)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: CvSpace.xs),
                child: TextButton(
                  onPressed: () => setState(() => _showAllActivities = !_showAllActivities),
                  style: TextButton.styleFrom(
                    foregroundColor: CvColors.primaryDark,
                    minimumSize: const Size(0, 40),
                    textStyle: CvText.label.copyWith(fontSize: 14),
                  ),
                  child: Text(_showAllActivities ? 'Ver menos' : 'Ver todas (${all.length})'),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _activityTile(CrmActivity a) {
    final color = getActivityColor(a.activityType ?? '');
    return InkWell(
      onTap: () => _activityForm(a),
      hoverColor: CvColors.background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(CvSpace.md, CvSpace.sm + 2, CvSpace.xxs, CvSpace.sm + 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Acento por tipo de actividad
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(width: CvSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: CvSpace.xs,
                    runSpacing: CvSpace.xxs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(a.activityType ?? 'Actividad', style: CvText.label.copyWith(fontSize: 14)),
                      StatusBadge(status: a.status, overdue: a.isOverdue),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [formatDateTime(a.datetime), if (a.contactName != null) a.contactName!].join(' · '),
                    style: CvText.helper.copyWith(fontSize: 13),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CvSectionHeading(
          title: 'Ventas',
          trailing: CvTextAction(label: 'Registrar venta', onPressed: () => _saleForm()),
        ),
        const SizedBox(height: CvSpace.sm),
        if (sales.isEmpty)
          const CvEmptyNote(icon: Icons.point_of_sale_outlined, text: 'No has registrado ventas a este cliente.')
        else ...[
          CvListSurface(
            children: [
              for (final s in sales)
                Padding(
                  padding: const EdgeInsets.fromLTRB(CvSpace.md, CvSpace.sm, CvSpace.xxs, CvSpace.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.quantity != null ? '${s.label} × ${s.quantity}' : s.label,
                              style: CvText.label.copyWith(fontSize: 14),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              [
                                formatIsoDate(s.saleDate),
                                if (s.contactName != null) s.contactName!,
                                if (s.notes != null) s.notes!,
                              ].join(' · '),
                              style: CvText.helper.copyWith(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: CvSpace.sm),
                      Text(formatEuros(s.amountCents), style: CvText.label.copyWith(fontSize: 14.5)),
                      CvContextMenu<String>(
                        onSelected: (v) => v == 'edit' ? _saleForm(s) : _deleteSale(s),
                        entries: const [
                          CvMenuEntry(value: 'edit', label: 'Editar', icon: Icons.edit_outlined),
                          CvMenuEntry(
                            value: 'delete',
                            label: 'Eliminar venta',
                            icon: Icons.delete_outline_rounded,
                            danger: true,
                            dividerBefore: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (sales.length >= 20)
            Padding(
              padding: const EdgeInsets.only(top: CvSpace.xs),
              child: Text('Se muestran tus 20 ventas más recientes.', style: CvText.helper),
            ),
        ],
      ],
    );
  }
}

/// Cifra del resumen comercial: etiqueta, importe y explicación (menor peso).
class _Figure {
  final String label;
  final String help;
  final int cents;
  final bool strong;

  const _Figure(this.label, this.help, this.cents, {this.strong = false});

  TextStyle get _valueStyle => CvText.heading.copyWith(
        fontSize: strong ? 24 : 21,
        fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
        letterSpacing: -0.5,
        color: strong ? CvColors.primaryDark : CvColors.textPrimary,
      );

  Widget column() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: CvText.label.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: CvColors.textSecondary)),
          const SizedBox(height: CvSpace.xs - 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(formatEuros(cents), maxLines: 1, style: _valueStyle),
          ),
          const SizedBox(height: CvSpace.xxs),
          Text(help, style: CvText.helper.copyWith(fontSize: 12)),
        ],
      );

  Widget row() => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: CvText.label.copyWith(fontSize: 13.5)),
                const SizedBox(height: 1),
                Text(help, style: CvText.helper.copyWith(fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: CvSpace.sm),
          Text(formatEuros(cents), style: _valueStyle.copyWith(fontSize: strong ? 20 : 17)),
        ],
      );
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
