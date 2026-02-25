import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'package:provider/provider.dart';

class NewActivityScreen extends StatelessWidget {
  final Map<String, dynamic> result;

  const NewActivityScreen({super.key, required this.result});

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
    final status = result["resolution_status"];
    final statusColor = _statusColor(status);
    final overall = (result["overall_confidence"] ?? 0) / 100;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.black87,
        title: const Text("Nueva Actividad"),
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
                        "${result["overall_confidence"] ?? 0}%",
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
                  Text(
                    result["cliente_nombre"] ?? result["cliente_detectado"],
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),

                  const SizedBox(height: 4),

                  /// CONTACTO
                  Row(
                    children: [
                      const Icon(Icons.person,
                          size: 16, color: Colors.black54),
                      const SizedBox(width: 6),
                      Text(
                        result["contacto_nombre"] ?? result["contacto_detectado"],
                        style: const TextStyle(
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  const Divider(),

                  const SizedBox(height: 16),

                  _infoRow(Icons.calendar_today, "Fecha",
                      result["fecha_detectada"]),
                  _infoRow(Icons.flash_on, "Acción",
                      result["accion_detectada"]),

                  const SizedBox(height: 20),

                  /// TRANSCRIPCIÓN
                  if (result["texto"] != null)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F6F8),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        result["texto"],
                        style: const TextStyle(
                          color: Colors.black87,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const Spacer(),

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
                  final response = await api.createActivity(result);

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
}