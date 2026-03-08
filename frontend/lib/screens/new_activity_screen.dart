import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'package:provider/provider.dart';

class NewActivityScreen extends StatefulWidget {
  final Map<String, dynamic> result;

  const NewActivityScreen({super.key, required this.result});

  @override
  State<NewActivityScreen> createState() => _NewActivityScreenState();
}

class _NewActivityScreenState extends State<NewActivityScreen> {

  late Map<String, dynamic> editedResult;
  bool isEditing = false;
  List activityTypes = [];
  List clients = [];
  List contacts = [];
  List products = [];

  @override
  void initState() {
    super.initState();
    editedResult = Map<String, dynamic>.from(widget.result);
  }

  Color _statusColor(String? status) {
    switch (status) {
      case "high":
        return const Color(0xFF2E7D32);
      case "medium":
        return const Color(0xFF1565C0);
      case "low":
        return const Color(0xFFF57C00);
      default:
        return const Color(0xFFC62828);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = editedResult["resolution_status"];
    final statusColor = _statusColor(status);
    final overall = (editedResult["overall_confidence"] ?? 0) / 100;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.black87,
        title: const Text("Nueva Actividad"),
        actions: [
          IconButton(
            icon: Icon(isEditing ? Icons.close : Icons.edit),
            onPressed: () async {
              if (!isEditing) {
                final api = context.read<ApiService>();

                activityTypes = await api.getActivityTypes();
                clients = await api.getClients();
                products = await api.getProducts();

                // Si ya hay cliente seleccionado, cargar contactos
                if (editedResult["cliente_id"] != null) {
                  contacts = await api.getContacts(
                    clientId: editedResult["cliente_id"],
                  );
                }
              }

              setState(() {
                isEditing = !isEditing;
              });
            },
        ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [

            /// CARD PRINCIPAL
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  )
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  /// STATUS + CONFIDENCE
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: statusColor,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          (status ?? "UNKNOWN").toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        "${editedResult["overall_confidence"] ?? 0}%",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      )
                    ],
                  ),

                  const SizedBox(height: 12),

                  /// BARRA CONFIDENCE
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: overall,
                      minHeight: 6,
                      backgroundColor: Colors.grey.shade200,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(statusColor),
                    ),
                  ),

                  const SizedBox(height: 24),

                  /// CLIENTE (PROTAGONISTA)
                  isEditing
                      ? _buildEditableClient()
                      : Text(
                          editedResult["cliente_nombre"] ??
                              editedResult["cliente_detectado"] ??
                              "-",
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),

                  const SizedBox(height: 4),

                  /// CONTACTO
                  const SizedBox(height: 8),

                  isEditing
                      ? _buildEditableContact()
                      : Row(
                          children: [
                            const Icon(Icons.person,
                                size: 16, color: Colors.black54),
                            const SizedBox(width: 6),
                            Text(
                              editedResult["contacto_nombre"] ??
                                  editedResult["contacto_detectado"] ??
                                  "-",
                              style: const TextStyle(
                                color: Colors.black54,
                              ),
                            ),
                          ],
                        ),

                  const SizedBox(height: 20),

                  const Divider(),

                  const SizedBox(height: 16),

                  isEditing
                      ? _buildEditableDate()
                      : _infoRow(
                          Icons.calendar_today,
                          "Fecha",
                           _formatDateTime(editedResult["fecha_detectada"]),
                        ),
                  isEditing
                      ? _buildEditableAction()
                      : _infoRow(
                          Icons.flash_on,
                          "Acción",
                          editedResult["accion_detectada"],
                        ),
                  isEditing
                      ? _buildEditableTime()
                      : const SizedBox(),


                  const SizedBox(height: 20),

                  /// TRANSCRIPCIÓN
                  if (editedResult["texto"] != null)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F6F8),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        editedResult["texto"],
                        style: const TextStyle(
                          color: Colors.black87,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            /// PRODUCTOS DETECTADOS
            if (editedResult["products_detected"] != null &&
                editedResult["products_detected"].isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Productos detectados:",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    ...editedResult["products_detected"]
                        .map<Widget>((p) {
                      final product = products.firstWhere(
                        (prod) => prod["id"] == p["product_id"],
                        orElse: () => null,
                      );

                      final price = product != null
                          ? product["price"]
                          : null;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE3F2FD),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.inventory_2,
                                size: 16, color: Colors.blue),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                p["product_raw"],
                                style: const TextStyle(
                                    fontWeight: FontWeight.w500),
                              ),
                            ),
                            if (price != null)
                              Text(
                                "${price.toStringAsFixed(0)}€",
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),

                            if (isEditing)
                              IconButton(
                                icon: const Icon(Icons.close,
                                    size: 18, color: Colors.red),
                                onPressed: () {
                                  setState(() {
                                    editedResult["products_detected"].remove(p);
                                  });
                                },
                              ),
                          ],
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),

              if (isEditing)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextButton.icon(
                    onPressed: () {
                      _showAddProductDialog();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text("Añadir producto"),
                  ),
                ),

            /// BOTÓN
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 6,
                ),
                onPressed: () async {
                  final api = context.read<ApiService>();
                  final response = await api.createActivity(editedResult);

                  if (response["success"] == true) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("Actividad guardada correctamente"),
                        backgroundColor: Colors.green,
                      ),
                    );

                    Navigator.pop(context);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(response["error"] ?? "Error guardando actividad"),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                },
                child: const Text(
                  "Confirmar y guardar actividad",
                  style: TextStyle(fontSize: 16),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  void _showAddProductDialog() {
    showDialog(
      context: context,
      builder: (_) {
        int? selectedId;

        return AlertDialog(
          title: const Text("Añadir producto"),
          content: DropdownButtonFormField<int>(
            items: products
                .map<DropdownMenuItem<int>>((p) {
              return DropdownMenuItem(
                value: p["id"],
                child: Text(p["name"]),
              );
            }).toList(),
            onChanged: (value) {
              selectedId = value;
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancelar"),
            ),
            ElevatedButton(
              onPressed: () {
                if (selectedId != null) {
                  final product = products
                      .firstWhere((p) =>
                          p["id"] == selectedId);

                  setState(() {
                    editedResult["products_detected"]
                        .add({
                      "product_id": product["id"],
                      "product_raw": product["name"],
                      "confidence": 100
                    });
                  });
                }
                Navigator.pop(context);
              },
              child: const Text("Añadir"),
            ),
          ],
        );
      },
    );
  }

  String _formatDateTime(String? iso) {
    if (iso == null) return "-";

    final date = DateTime.tryParse(iso);
    if (date == null) return "-";

    final datePart =
        "${date.day}/${date.month}/${date.year}";
    final timePart =
        "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";

    return "$datePart  $timePart";
  }

  Widget _infoRow(IconData icon, String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.blueGrey),
          const SizedBox(width: 10),
          Text(
            "$label:",
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              color: Colors.black54,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value?.toString() ?? "-",
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditableDate() {
    DateTime? currentDate;

    if (editedResult["fecha_detectada"] != null) {
      currentDate = DateTime.tryParse(editedResult["fecha_detectada"]);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          const Icon(Icons.calendar_today, size: 18, color: Colors.blueGrey),
          const SizedBox(width: 10),
          const Text(
            "Fecha:",
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: Colors.black54,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              final pickedDate = await showDatePicker(
                context: context,
                initialDate: currentDate ?? DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );

              if (pickedDate != null) {
                setState(() {
                  editedResult["fecha_detectada"] =
                      pickedDate.toIso8601String().split("T")[0];
                });
              }
            },
            child: Text(
              currentDate != null
                  ? "${currentDate.day}/${currentDate.month}/${currentDate.year}"
                  : "Seleccionar fecha",
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditableTime() {
    TimeOfDay? currentTime;

    if (editedResult["fecha_detectada"] != null) {
      final date = DateTime.tryParse(editedResult["fecha_detectada"]);
      if (date != null) {
        currentTime = TimeOfDay(hour: date.hour, minute: date.minute);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          const Icon(Icons.access_time, size: 18, color: Colors.blueGrey),
          const SizedBox(width: 10),
          const Text(
            "Hora:",
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: Colors.black54,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              final pickedTime = await showTimePicker(
                context: context,
                initialTime: currentTime ?? TimeOfDay.now(),
              );

              if (pickedTime != null) {
                setState(() {
                  final date = editedResult["fecha_detectada"] != null
                      ? DateTime.tryParse(editedResult["fecha_detectada"])
                      : DateTime.now();

                  if (date != null) {
                    final newDateTime = DateTime(
                      date.year,
                      date.month,
                      date.day,
                      pickedTime.hour,
                      pickedTime.minute,
                    );

                    editedResult["fecha_detectada"] =
                        newDateTime.toIso8601String();
                  }
                });
              }
            },
            child: Text(
              currentTime != null
                  ? currentTime.format(context)
                  : "Seleccionar hora",
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditableAction() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.flash_on, size: 18, color: Colors.blueGrey),
          const SizedBox(width: 10),
          const Text(
            "Acción:",
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: Colors.black54,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<int>(
              value: editedResult["activity_type_id"] is int
                  ? editedResult["activity_type_id"]
                  : int.tryParse(editedResult["activity_type_id"]?.toString() ?? ""),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: activityTypes.map<DropdownMenuItem<int>>((type) {
                return DropdownMenuItem<int>(
                  value: type["id"],
                  child: Text(type["name"]),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  editedResult["activity_type_id"] = value;

                  final selected = activityTypes.firstWhere(
                    (t) => t["id"] == value,
                    orElse: () => null,
                  );

                  if (selected != null) {
                    editedResult["accion_detectada"] = selected["name"];
                  }
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditableClient() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<int>(
        value: editedResult["cliente_id"] is int
            ? editedResult["cliente_id"]
            : int.tryParse(
                editedResult["cliente_id"]?.toString() ?? "",
              ),
        decoration: const InputDecoration(
          labelText: "Cliente",
          border: OutlineInputBorder(),
          isDense: true,
        ),
        items: clients.map<DropdownMenuItem<int>>((client) {
          return DropdownMenuItem<int>(
            value: client["id"],
            child: Text(client["name"]),
          );
        }).toList(),
        onChanged: (value) async {
          final api = context.read<ApiService>();

          setState(() {
            editedResult["cliente_id"] = value;

            final selected = clients.firstWhere(
              (c) => c["id"] == value,
            );

            editedResult["cliente_nombre"] = selected["name"];

            // Limpiar contacto al cambiar cliente
            editedResult["contacto_id"] = null;
            editedResult["contacto_nombre"] = null;
            contacts = [];
          });

          if (value != null) {
            final loadedContacts =
                await api.getContacts(clientId: value);

            setState(() {
              contacts = loadedContacts;
            });
          }
        },
      ),
    );
  }

  Widget _buildEditableContact() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<int>(
        value: editedResult["contacto_id"] is int
            ? editedResult["contacto_id"]
            : int.tryParse(
                editedResult["contacto_id"]?.toString() ?? "",
              ),
        decoration: const InputDecoration(
          labelText: "Contacto",
          border: OutlineInputBorder(),
          isDense: true,
        ),
        items: contacts.map<DropdownMenuItem<int>>((contact) {
          return DropdownMenuItem<int>(
            value: contact["id"],
            child: Text(contact["name"]),
          );
        }).toList(),
        onChanged: (value) {
          setState(() {
            editedResult["contacto_id"] = value;

            final selected = contacts.firstWhere(
              (c) => c["id"] == value,
            );

            editedResult["contacto_nombre"] = selected["name"];
          });
        },
      ),
    );
  }

}