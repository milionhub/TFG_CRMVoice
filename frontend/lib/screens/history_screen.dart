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
  int? selectedClientId;
  int? selectedActionId;
  String? selectedDateFrom;
  String? selectedDateTo;
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
      final data = await ApiService.getActivities(
        clientId: selectedClientId,
        actionId: selectedActionId,
        dateFrom: selectedDateFrom,
        dateTo: selectedDateTo,
      );

      setState(() {
        items = List<Map<String, dynamic>>.from(data);
      });
    } catch (e) {
      setState(() => error = "Error cargando histórico: $e");
    } finally {
      setState(() => loading = false);
    }
  }

  Color _statusColor(String? status) {
    switch (status) {
      case "exact":
        return Colors.green.shade700;
      case "high":
        return Colors.green;
      case "medium":
        return const Color(0xFF1E88E5);
      case "low":
        return Colors.orange;
      default:
        return Colors.red;
    }
  }

  bool _hasActiveFilters() {
    return selectedClientId != null ||
        selectedActionId != null ||
        selectedDateFrom != null ||
        selectedDateTo != null;
  }

  List<Widget> _buildActiveChips() {
    final List<Widget> chips = [];

    if (selectedClientId != null) {
      chips.add(
        Chip(
          label: Text("Cliente: $selectedClientId"),
          onDeleted: () {
            setState(() {
              selectedClientId = null;
            });
            _load();
          },
        ),
      );
    }

    if (selectedActionId != null) {
      chips.add(
        Chip(
          label: Text("Acción: $selectedActionId"),
          onDeleted: () {
            setState(() {
              selectedActionId = null;
            });
            _load();
          },
        ),
      );
    }

    if (selectedDateFrom != null &&
        selectedDateTo != null) {
      chips.add(
        Chip(
          label:
              Text("$selectedDateFrom → $selectedDateTo"),
          onDeleted: () {
            setState(() {
              selectedDateFrom = null;
              selectedDateTo = null;
            });
            _load();
          },
        ),
      );
    }

    return chips;
  }

  void _openFilters() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _FilterModal(
        selectedClientId: selectedClientId,
        selectedActionId: selectedActionId,
        selectedDateFrom: selectedDateFrom,
        selectedDateTo: selectedDateTo,
        onApply: (clientId, actionId, dateFrom, dateTo) {
          setState(() {
            selectedClientId = clientId;
            selectedActionId = actionId;
            selectedDateFrom = dateFrom;
            selectedDateTo = dateTo;
          });

          _load();
        },
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        title: const Text("Histórico CRM"),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_alt_outlined),
            tooltip: "Filtrar",
            onPressed: _openFilters,
          ),
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
     body: loading
        ? const Center(child: CircularProgressIndicator())
        : error.isNotEmpty
            ? Center(child: Text(error))
            : Column(
                children: [

                  /// 🔵 CHIPS ACTIVOS
                  if (_hasActiveFilters())
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _buildActiveChips(),
                      ),
                    ),

                  /// 🔵 LISTADO
                  Expanded(
                    child: items.isEmpty
                        ? const Center(
                            child: Text(
                              "No hay actividades registradas.",
                              style: TextStyle(fontSize: 16),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 20),
                            itemCount: items.length,
                            itemBuilder: (_, i) {
                              final a = items[i];
                              final status = a["resolution_status"];
                              final statusColor = _statusColor(status);

                              return Container(
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                padding: const EdgeInsets.all(18),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(18),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.05),
                                      blurRadius: 12,
                                      offset: const Offset(0, 6),
                                    )
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [

                                    /// Header
                                    Row(
                                      children: [
                                        Container(
                                          padding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 4),
                                          decoration: BoxDecoration(
                                            color: statusColor
                                                .withOpacity(0.15),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                          ),
                                          child: Text(
                                            status?.toUpperCase() ??
                                                "UNKNOWN",
                                            style: TextStyle(
                                              color: statusColor,
                                              fontWeight:
                                                  FontWeight.bold,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        const Spacer(),
                                        Text(
                                          a["fecha"] ?? "-",
                                          style:
                                              const TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey,
                                          ),
                                        )
                                      ],
                                    ),

                                    const SizedBox(height: 14),

                                    /// Cliente
                                    Text(
                                      a["cliente"] ?? "-",
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight:
                                            FontWeight.w600,
                                      ),
                                    ),

                                    const SizedBox(height: 4),

                                    /// Acción
                                    Text(
                                      a["accion"] ?? "-",
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: Colors.black54,
                                      ),
                                    ),

                                    const SizedBox(height: 12),

                                    /// Comentario
                                    Text(
                                      a["comentario"] ?? "",
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
    );
  }
}

class _FilterModal extends StatefulWidget {
  final int? selectedClientId;
  final int? selectedActionId;
  final String? selectedDateFrom;
  final String? selectedDateTo;
  final Function(int?, int?, String?, String?) onApply;

  const _FilterModal({
    required this.selectedClientId,
    required this.selectedActionId,
    required this.selectedDateFrom,
    required this.selectedDateTo,
    required this.onApply,
  });

  @override
  State<_FilterModal> createState() => _FilterModalState();
}

class _FilterModalState extends State<_FilterModal> {

  int? clientId;
  int? actionId;
  String? dateFrom;
  String? dateTo;
  List<dynamic> clients = [];
  List<dynamic> actions = [];

  bool loadingClients = true;
  bool loadingActions = true;

  @override
  void initState() {
    super.initState();

    clientId = widget.selectedClientId;
    actionId = widget.selectedActionId;
    dateFrom = widget.selectedDateFrom;
    dateTo = widget.selectedDateTo;

    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final c = await ApiService.getClients();
      final a = await ApiService.getActivityTypes();

      setState(() {
        clients = c;
        actions = a;
        loadingClients = false;
        loadingActions = false;
      });
    } catch (_) {
      setState(() {
        loadingClients = false;
        loadingActions = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            const Text(
              "Filtrar actividades",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 20),

            loadingClients
              ? const CircularProgressIndicator()
              : DropdownButtonFormField<int>(
                  value: clientId,
                  decoration: const InputDecoration(
                    labelText: "Cliente",
                  ),
                  items: clients
                      .map<DropdownMenuItem<int>>(
                        (c) => DropdownMenuItem<int>(
                          value: c["id"],
                          child: Text(c["name"]),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    setState(() {
                      clientId = value;
                    });
                  },
                ),
                const SizedBox(height: 16),

                loadingActions
                    ? const CircularProgressIndicator()
                    : DropdownButtonFormField<int>(
                        value: actionId,
                        decoration: const InputDecoration(
                          labelText: "Acción",
                        ),
                        items: actions
                            .map<DropdownMenuItem<int>>(
                              (a) => DropdownMenuItem<int>(
                                value: a["id"],
                                child: Text(a["name"]),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          setState(() {
                            actionId = value;
                          });
                        },
                      ),
                const SizedBox(height: 16),

                ElevatedButton.icon(
                  icon: const Icon(Icons.date_range),
                  label: const Text("Seleccionar rango de fechas"),
                  onPressed: () async {
                    final range = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2030),
                    );

                    if (range != null) {
                      setState(() {
                        dateFrom = range.start.toIso8601String().split("T").first;
                        dateTo = range.end.toIso8601String().split("T").first;
                      });
                    }
                  },
                ),

                if (dateFrom != null && dateTo != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      "$dateFrom → $dateTo",
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () {
                    widget.onApply(null, null, null, null);
                    Navigator.pop(context);
                  },
                  child: const Text("Limpiar"),
                ),
                ElevatedButton(
                  onPressed: () {
                    widget.onApply(clientId, actionId, dateFrom, dateTo);
                    Navigator.pop(context);
                  },
                  child: const Text("Aplicar"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}