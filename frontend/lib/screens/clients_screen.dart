// Clientes (H.3): listado con búsqueda en el backend (GET /clients?q=),
// alta y acceso a la ficha. I.3.1: cabecera de página, buscador, contador y
// una única superficie de listado con filas (la lógica no cambia).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/design/cv_theme.dart';
import '../core/design/cv_tokens.dart';
import '../models/crm.dart';
import '../services/api_service.dart';
import '../widgets/crm/client_form.dart';
import '../widgets/crm/crm_ui.dart';
import '../widgets/ui/cv_components.dart';
import 'client_detail_screen.dart';
import 'home_screen.dart';

class ClientsScreen extends StatelessWidget {
  const ClientsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Shell común (I.2): barra lateral en escritorio, cabecera + menú en móvil
    // CrmTheme se mantiene: el formulario de alta (fuera de I.3.1) lo hereda
    return const AppShell(
      currentIndex: 1,
      title: "Clientes",
      body: CrmTheme(child: ClientsContent()),
    );
  }
}

class ClientsContent extends StatefulWidget {
  /// Espera antes de buscar mientras se escribe.
  static const debounce = Duration(milliseconds: 350);

  const ClientsContent({super.key});

  @override
  State<ClientsContent> createState() => _ClientsContentState();
}

class _ClientsContentState extends State<ClientsContent> {
  final _search = TextEditingController();
  Timer? _debounce;
  int _request = 0;

  bool _loading = true;
  String? _error;
  List<ClientSummary> _clients = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(ClientsContent.debounce, () {
      if (value.trim() != _query) _load(query: value.trim());
    });
  }

  Future<void> _load({String? query}) async {
    final q = query ?? _query;
    final request = ++_request; // las respuestas antiguas se descartan
    setState(() {
      _loading = true;
      _error = null;
      _query = q;
    });
    try {
      final clients = await context.read<ApiService>().searchClients(query: q);
      if (!mounted || request != _request) return;
      setState(() {
        _clients = clients;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = userMessage(e);
        _loading = false;
      });
    }
  }

  Future<void> _openClient(int clientId) async {
    // Ruta del shell (I.2): la barra lateral no se mueve, solo entra el contenido
    await Navigator.push(
      context,
      SectionRoute(
        settings: const RouteSettings(name: ClientDetailScreen.fromClientsRoute),
        builder: (_) => ClientDetailScreen(clientId: clientId),
      ),
    );
    if (mounted) _load(); // el nombre puede haber cambiado
  }

  Future<void> _create() async {
    final result = await openClientForm(context);
    if (result == null || !mounted) return;
    showSuccess(context, 'Cliente «${result.client.name}» creado');
    _load();
    _openClient(result.client.id);
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    _load(query: '');
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = CvPageBody.insets(constraints.maxWidth);
        final horizontal = EdgeInsets.symmetric(horizontal: insets.left);
        return RefreshIndicator(
          onRefresh: _load,
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
                        title: "Clientes",
                        subtitle: "Gestiona y consulta toda tu cartera de clientes.",
                        action: CvPrimaryButton(
                          label: 'Nuevo cliente',
                          icon: Icons.add_rounded,
                          onPressed: _create,
                        ),
                      ),
                      const SizedBox(height: CvSpace.xl),
                      CvSearchField(
                        controller: _search,
                        hint: 'Buscar por razón social o alias',
                        onChanged: _onSearchChanged,
                        onSubmitted: (v) {
                          _debounce?.cancel();
                          _load(query: v.trim());
                        },
                        onClear: _clearSearch,
                      ),
                      const SizedBox(height: CvSpace.lg),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: horizontal.copyWith(bottom: insets.bottom),
                sliver: _body(),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Estados: carga inicial, error, vacío, búsqueda sin resultados y listado
  /// (durante una nueva búsqueda se mantiene el listado anterior con una
  /// barra de progreso fina).
  Widget _body() {
    if (_loading && _clients.isEmpty) {
      return const SliverToBoxAdapter(
        child: CvStatePanel(
          icon: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: CvColors.primaryDark),
          ),
          title: 'Cargando clientes…',
        ),
      );
    }
    if (_error != null && !_loading) {
      return SliverToBoxAdapter(
        child: CvStatePanel(
          icon: const Icon(Icons.cloud_off_outlined),
          title: 'No se pudieron cargar los clientes.',
          message: _error,
          action: OutlinedButton.icon(
            onPressed: _load,
            style: OutlinedButton.styleFrom(
              foregroundColor: CvColors.textPrimary,
              side: const BorderSide(color: CvColors.borderStrong),
              minimumSize: const Size(0, 42),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.control)),
            ),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Reintentar'),
          ),
        ),
      );
    }
    if (_clients.isEmpty) {
      return SliverToBoxAdapter(
        child: _query.isEmpty
            ? CvStatePanel(
                icon: const Icon(Icons.business_outlined),
                title: 'No tienes clientes todavía.',
                message: 'Crea tu primer cliente para empezar a gestionar su actividad.',
                action: CvPrimaryButton(label: 'Crear el primero', icon: Icons.add_rounded, onPressed: _create),
              )
            : CvStatePanel(
                icon: const Icon(Icons.search_off_rounded),
                title: 'No encontramos clientes para esta búsqueda.',
                message: 'Ningún cliente coincide con «$_query». Revisa el texto o prueba con el alias.',
                action: TextButton(
                  onPressed: _clearSearch,
                  style: TextButton.styleFrom(foregroundColor: CvColors.primaryDark),
                  child: const Text('Limpiar búsqueda'),
                ),
              ),
      );
    }

    final n = _clients.length;
    final count = _query.isEmpty
        ? (n == 1 ? '1 cliente' : '$n clientes')
        : (n == 1 ? '1 cliente encontrado' : '$n clientes encontrados');

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(left: 2, bottom: CvSpace.sm),
            child: Row(
              children: [
                Text(count, key: const Key('clients-count'), style: CvText.helper.copyWith(fontSize: 13)),
                if (_loading) ...[
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
            final c = _clients[i];
            final subtitle = [
              if (c.alias != null) c.alias!,
              if (c.city != null) c.city!,
              if (c.province != null && c.province != c.city) c.province!,
            ].join(' · ');
            return CvEntityRow(
              key: ValueKey('client-${c.id}'),
              leading: CvInitialAvatar(name: c.name),
              title: c.name,
              subtitle: subtitle.isEmpty ? null : subtitle,
              onTap: () => _openClient(c.id),
            );
          },
        ),
      ],
    );
  }
}
