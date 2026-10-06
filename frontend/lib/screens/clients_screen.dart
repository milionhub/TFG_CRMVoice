// Clientes (H.3): listado con búsqueda en el backend (GET /clients?q=),
// alta y acceso a la ficha.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_colors.dart';
import '../models/crm.dart';
import '../services/api_service.dart';
import '../widgets/crm/client_form.dart';
import '../widgets/crm/crm_ui.dart';
import 'client_detail_screen.dart';
import 'home_screen.dart';

class ClientsScreen extends StatelessWidget {
  const ClientsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 800;
    if (isMobile) {
      return Scaffold(
        backgroundColor: AppColors.background,
        drawer: const MobileDrawer(currentIndex: 1),
        appBar: AppBar(backgroundColor: Colors.white, elevation: 1, title: const Text("Clientes")),
        body: const SafeArea(child: CrmTheme(child: ClientsContent())),
      );
    }
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        children: [
          Sidebar(currentIndex: 1),
          Expanded(child: SafeArea(child: CrmTheme(child: ClientsContent()))),
        ],
      ),
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
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ClientDetailScreen(clientId: clientId)));
    if (mounted) _load(); // el nombre puede haber cambiado
  }

  Future<void> _create() async {
    final result = await openClientForm(context);
    if (result == null || !mounted) return;
    showSuccess(context, 'Cliente «${result.client.name}» creado');
    _load();
    _openClient(result.client.id);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 12,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("Clientes",
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.primary)),
                  SizedBox(height: 4),
                  Text("Cartera compartida de clientes",
                      style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                ],
              ),
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add),
                label: const Text('Nuevo cliente'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: TextField(
            controller: _search,
            onChanged: _onSearchChanged,
            onSubmitted: (v) {
              _debounce?.cancel();
              _load(query: v.trim());
            },
            decoration: InputDecoration(
              hintText: 'Buscar por razón social o alias',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Limpiar búsqueda',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _debounce?.cancel();
                        _search.clear();
                        _load(query: '');
                      },
                    ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(message: _error!, onRetry: _load);
    if (_clients.isEmpty) {
      return _query.isEmpty
          ? EmptyView(
              icon: Icons.business_outlined,
              message: 'Todavía no hay clientes.',
              action: FilledButton.icon(
                  onPressed: _create, icon: const Icon(Icons.add), label: const Text('Crear el primero')),
            )
          : EmptyView(
              icon: Icons.search_off,
              message: 'Ningún cliente coincide con «$_query».',
              action: OutlinedButton.icon(
                  onPressed: _create, icon: const Icon(Icons.add), label: const Text('Crear cliente')),
            );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        itemCount: _clients.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final c = _clients[i];
          final subtitle = [
            if (c.alias != null) c.alias!,
            if (c.city != null) c.city!,
            if (c.province != null && c.province != c.city) c.province!,
          ].join(' · ');
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                child: Text(c.name.isEmpty ? '?' : c.name[0].toUpperCase(),
                    style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
              ),
              title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: subtitle.isEmpty ? null : Text(subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openClient(c.id),
            ),
          );
        },
      ),
    );
  }
}
