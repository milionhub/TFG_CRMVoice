class Activity {
  final int id;
  final String? fecha;
  final String? cliente;
  final String? accion;
  final String comentario;
  final String resolutionStatus;

  Activity({
    required this.id,
    required this.fecha,
    required this.cliente,
    required this.accion,
    required this.comentario,
    required this.resolutionStatus,
  });

  factory Activity.fromJson(Map<String, dynamic> json) {
    return Activity(
      id: json['id'],
      fecha: json['fecha'],
      cliente: json['cliente'],
      accion: json['accion'],
      comentario: json['comentario'],
      resolutionStatus: json['resolution_status'] ?? 'auto',
    );
  }
}