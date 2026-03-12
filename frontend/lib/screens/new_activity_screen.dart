import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../core/app_colors.dart';
import 'history_screen.dart';

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

  /// ESTILO CRM PARA DROPDOWNS
  InputDecoration _crmDropdownDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(
        color: Colors.black,
        fontWeight: FontWeight.w500,
      ),
      enabledBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: AppColors.primary),
      ),
      focusedBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: AppColors.primary, width: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {

    final action = editedResult["accion_detectada"] ?? "";
    final color = getActivityColor(action);

    final client =
        editedResult["cliente_nombre"] ??
        editedResult["cliente_detectado"] ??
        "-";

    final contact =
        editedResult["contacto_nombre"] ??
        editedResult["contacto_detectado"] ??
        "-";

    final productsDetected = editedResult["products_detected"] ?? [];

    return Scaffold(
      backgroundColor: AppColors.background,

      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: AppColors.primary,
        title: const Text(
          "Nueva actividad",
          style: TextStyle(
            color: AppColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [

          IconButton(
            icon: Icon(isEditing ? Icons.close : Icons.edit_outlined),
            onPressed: () async {

              if (!isEditing) {

                final api = context.read<ApiService>();

                activityTypes = await api.getActivityTypes();
                clients = await api.getClients();
                products = await api.getProducts();

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

      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 18),
                padding: const EdgeInsets.all(16),

                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                ),

                child: Row(
                  children: [

                    const Icon(
                      Icons.auto_awesome,
                      color: AppColors.primary,
                    ),

                    const SizedBox(width: 10),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [

                          Text(
                            "Voice-CRM ha detectado esta actividad",
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),

                          SizedBox(height: 2),

                          Text(
                            "Revísala antes de guardarla",
                            style: TextStyle(
                              color: Colors.black87,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),

                  ],
                ),
              ),

            /// CARD PRINCIPAL
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(.05),
                    blurRadius: 16,
                    offset: const Offset(0,8),
                  )
                ],
              ),

              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  /// BARRA COLOR
                  Container(
                    width: 4,
                    height: 120,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),

                  const SizedBox(width: 18),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [

                        /// ACCION
                        isEditing
                            ? _buildEditableAction()
                            : Text(
                                action,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),

                        const SizedBox(height: 10),

                        /// CLIENTE
                        isEditing
                            ? _buildEditableClient()
                            : Text(
                                client,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),

                        const SizedBox(height: 4),

                        /// CONTACTO
                        isEditing
                            ? _buildEditableContact()
                            : Row(
                                children: [
                                  const Icon(
                                    Icons.person,
                                    size: 16,
                                    color: Colors.black54,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    contact,
                                    style: const TextStyle(
                                      color: Colors.black54,
                                    ),
                                  ),
                                ],
                              ),

                        const SizedBox(height: 18),

                        /// FECHA
                        isEditing
                            ? _buildEditableDate()
                            : _infoRow(
                                Icons.calendar_today,
                                "Fecha",
                                _formatDateTime(
                                    editedResult["fecha_detectada"]),
                              ),

                        if (isEditing)
                          _buildEditableTime(),

                        const SizedBox(height: 18),

                        /// TRANSCRIPCION
                        if (editedResult["texto"] != null)
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppColors.background,
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
                  )
                ],
              ),
            ),

            const SizedBox(height: 20),

            /// PRODUCTOS DETECTADOS
            if (productsDetected.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Productos detectados",
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.black54,
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: productsDetected.map<Widget>((p) {

                      final name =
                          p["product_raw"] ??
                          p["name"] ??
                          "";

                      return Chip(
                        backgroundColor: AppColors.primary,

                        label: Text(
                          name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),

                        deleteIcon: isEditing
                            ? const Icon(
                                Icons.close,
                                size: 18,
                                color: Colors.white,
                              )
                            : null,

                        onDeleted: isEditing
                            ? () {
                                setState(() {
                                  editedResult["products_detected"]
                                      .remove(p);
                                });
                              }
                            : null,
                      );

                    }).toList(),
                  ),

                ],
              ),

            if (isEditing)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextButton.icon(
                  onPressed: _showAddProductDialog,
                  icon: const Icon(Icons.add, color: AppColors.primary),
                  label: const Text(
                    "Añadir producto",
                    style: TextStyle(color: AppColors.primary),
                  ),
                ),
              ),

            const SizedBox(height: 30),

            /// BOTON GUARDAR
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),

                onPressed: () async {

                  final api = context.read<ApiService>();

                  final payload = {

                    "cliente_id": editedResult["cliente_id"],
                    "contacto_id": editedResult["contacto_id"],
                    "activity_type_id": editedResult["activity_type_id"],

                    "fecha_detectada": editedResult["fecha_detectada"],

                    "texto": editedResult["texto"],

                    "products_detected": editedResult["products_detected"],

                    "cliente_detectado": editedResult["cliente_detectado"],
                    "contacto_detectado": editedResult["contacto_detectado"],
                    "accion_detectada": editedResult["accion_detectada"],

                    "resolution_status": editedResult["resolution_status"],
                    "overall_confidence": editedResult["overall_confidence"],
                  };

                  final response = await api.createActivity(payload);

                  if (response["success"] == true) {

                    if (!mounted) return;

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("Actividad guardada correctamente"),
                        backgroundColor: Colors.green,
                      ),
                    );

                    Navigator.pop(context);

                  } else {

                    if (!mounted) return;

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(response["error"] ?? "Error guardando actividad"),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                },

                child: const Text(
                  "Guardar actividad",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),

          ],
        ),
      ),
    );
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

  String _formatDateTime(String? iso) {

    if (iso == null) return "-";

    final date = DateTime.tryParse(iso);

    if (date == null) return "-";

    return "${date.day}/${date.month}/${date.year} · "
        "${date.hour.toString().padLeft(2,'0')}:"
        "${date.minute.toString().padLeft(2,'0')}";
  }

  /// EDITABLE FIELDS

  Widget _buildEditableAction() {

    return Row(
      children: [

        const Icon(
          Icons.flash_on,
          color: Colors.black54,
          size: 20,
        ),

        const SizedBox(width: 8),

        Expanded(
          child: DropdownButtonFormField<int>(
            value: editedResult["activity_type_id"],
            dropdownColor: Colors.white,
            iconEnabledColor: AppColors.primary,
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w600,
            ),
            decoration: _crmDropdownDecoration("Acción"),
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
                );

                editedResult["accion_detectada"] = selected["name"];

              });

            },
          ),
        ),
      ],
    );
  }

  Widget _buildEditableClient() {

    return Row(
      children: [
        
        const Icon(
        Icons.business,
        color: Colors.black,
        size: 20,
      ),

      const SizedBox(width: 8),

      Expanded(
        child: DropdownButtonFormField<int>(
      value: editedResult["cliente_id"],
      dropdownColor: Colors.white,
      iconEnabledColor: AppColors.primary,
      style: const TextStyle(
        color: AppColors.primary,
        fontWeight: FontWeight.w600,
      ),
      decoration: _crmDropdownDecoration("Cliente"),
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

          final selected =
              clients.firstWhere((c) => c["id"] == value);

          editedResult["cliente_nombre"] = selected["name"];

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
    )
       ],
    );

  }

  Widget _buildEditableContact() {

    return Row(
    children: [

      const Icon(
        Icons.person,
        color: Colors.black54,
        size: 20,
      ),

      const SizedBox(width: 8),

      Expanded(
        child: DropdownButtonFormField<int>(
      value: editedResult["contacto_id"],
      dropdownColor: Colors.white,
      iconEnabledColor: AppColors.primary,
      style: const TextStyle(
        color: AppColors.primary,
        fontWeight: FontWeight.w600,
      ),
      decoration: _crmDropdownDecoration("Contacto"),
      items: contacts.map<DropdownMenuItem<int>>((contact) {

        return DropdownMenuItem<int>(
          value: contact["id"],
          child: Text(contact["name"]),
        );

      }).toList(),

      onChanged: contacts.isEmpty
          ? null
          : (value) {

              setState(() {

                editedResult["contacto_id"] = value;

                final selected =
                    contacts.firstWhere(
                        (c) => c["id"] == value);

                editedResult["contacto_nombre"] =
                    selected["name"];

              });

            },

    ),
    )
       ],
    );

  }

  Widget _buildEditableDate() {

    DateTime? currentDate;

    if (editedResult["fecha_detectada"] != null) {
      currentDate =
          DateTime.tryParse(editedResult["fecha_detectada"]);
    }

    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: Colors.black87,
        backgroundColor: Colors.white,
      ),
      icon: const Icon(Icons.calendar_today),
      label: Text(
        currentDate != null
            ? "${currentDate.day}/${currentDate.month}/${currentDate.year}"
            : "Seleccionar fecha",
      ),

      onPressed: () async {

        final picked = await showDatePicker(
          context: context,
          initialDate: currentDate ?? DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),

          builder: (context, child) {
            return Theme(
              data: Theme.of(context).copyWith(
                colorScheme: const ColorScheme.light(
                  primary: AppColors.primary,
                  onPrimary: Colors.white,
                  onSurface: Colors.black,
                ),
                dialogBackgroundColor: Colors.white,
              ),
              child: child!,
            );
          },
        );

        if (picked != null) {

          setState(() {

            editedResult["fecha_detectada"] =
                picked.toIso8601String().split("T")[0];

          });

        }

      },

    );

  }

  Widget _buildEditableTime() {

    TimeOfDay? currentTime;

    if (editedResult["fecha_detectada"] != null) {

      final date =
          DateTime.tryParse(editedResult["fecha_detectada"]);

      if (date != null) {
        currentTime =
            TimeOfDay(hour: date.hour, minute: date.minute);
      }

    }

    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: Colors.black87,
        backgroundColor: Colors.white,
      ),
      icon: const Icon(Icons.access_time),
      label: Text(
        currentTime != null
            ? currentTime.format(context)
            : "Seleccionar hora",
      ),

      onPressed: () async {

        final picked = await showTimePicker(
          context: context,
          initialTime: currentTime ?? TimeOfDay.now(),

          builder: (context, child) {
            return Theme(
              data: Theme.of(context).copyWith(
                colorScheme: const ColorScheme.light(
                  primary: AppColors.primary,
                  onPrimary: Colors.white,
                  onSurface: Colors.black,
                ),
                dialogBackgroundColor: Colors.white,
              ),
              child: child!,
            );
          },
        );

        if (picked != null) {

          setState(() {

            final date =
                editedResult["fecha_detectada"] != null
                    ? DateTime.tryParse(
                        editedResult["fecha_detectada"])
                    : DateTime.now();

            if (date != null) {

              final newDateTime = DateTime(
                date.year,
                date.month,
                date.day,
                picked.hour,
                picked.minute,
              );

              editedResult["fecha_detectada"] =
                  newDateTime.toIso8601String();

            }

          });

        }

      },

    );

  }

  void _showAddProductDialog() {

    showDialog(
      context: context,
      builder: (_) {

        int? selectedId;

        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text("Añadir producto"),

          content: DropdownButtonFormField<int>(
            dropdownColor: Colors.white,
            iconEnabledColor: AppColors.primary,
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w600,
            ),
            decoration: _crmDropdownDecoration("Producto"),
            items: products.map<DropdownMenuItem<int>>((p) {

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
              child: const Text(
                "Cancelar",
                style: TextStyle(color: AppColors.primary),
              ),
            ),

            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              onPressed: () {

                if (selectedId != null) {

                  final product =
                      products.firstWhere(
                          (p) => p["id"] == selectedId);

                  setState(() {

                    editedResult["products_detected"].add({

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

}