import 'package:flutter/material.dart';
import '../services/api_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryScreen> {
  bool loading = true;
  String error = "";
  List<Map<String, dynamic>> items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = "";
    });

    try {
      final data = await ApiService.getActivities();
      setState(() {
        items = List<Map<String, dynamic>>.from(data);
      });
    } catch (e) {
      setState(() => error = "Error cargando histórico: $e");
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Histórico CRM"),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          )
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error.isNotEmpty
              ? Center(child: Text(error))
              : items.isEmpty
                  ? const Center(child: Text("No hay actividades todavía."))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final a = items[i];
                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: ListTile(
                            title: Text("${a["cliente"] ?? "-"} • ${a["accion"] ?? "-"}"),
                            subtitle: Text(
                              "Fecha: ${a["fecha"] ?? "-"}\n${a["comentario"] ?? ""}",
                            ),
                            trailing: Text("#${a["id"] ?? "-"}"),
                          ),
                        );
                      },
                    ),
    );
  }
}
