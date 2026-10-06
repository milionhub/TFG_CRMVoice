// Importes en EUR sin coma flotante (H.3).
//
// El backend guarda céntimos (int) y es quien interpreta el texto del
// usuario (core/formats.py: parse_money_cents). Aquí se replica el mismo
// criterio SOLO para validar y enseñar la interpretación antes de guardar;
// al backend se le envía el texto tal cual.

final _currency = RegExp(r'\s*(€|eur|euros?)\s*$', caseSensitive: false);
final _plain = RegExp(r'^\d+$'); // 4500
final _decimal = RegExp(r'^\d+[.,]\d{1,2}$'); // 4500.00 · 4500,00 · 4500,5
final _esThousands = RegExp(r'^\d{1,3}(\.\d{3})+(,\d{1,2})?$'); // 4.500 · 4.500,00

const int maxAmountCents = 1000000000; // mismo tope que el backend

/// Texto en euros -> céntimos, o null si no es un formato aceptado
/// (vacío, ambiguo como "4,500", más de dos decimales, cero...).
int? parseEuroCents(String input) {
  final text = input.trim().replaceAll(_currency, '').replaceAll(' ', '');
  String integer;
  String fraction = '';
  if (_plain.hasMatch(text)) {
    integer = text;
  } else if (_decimal.hasMatch(text)) {
    final parts = text.split(RegExp('[.,]'));
    integer = parts[0];
    fraction = parts[1];
  } else if (_esThousands.hasMatch(text)) {
    final parts = text.split(',');
    integer = parts[0].replaceAll('.', '');
    fraction = parts.length > 1 ? parts[1] : '';
  } else {
    return null;
  }
  final euros = int.tryParse(integer);
  if (euros == null || integer.length > 9) return null;
  final cents = euros * 100 + (fraction.isEmpty ? 0 : int.parse(fraction.padRight(2, '0')));
  if (cents <= 0 || cents > maxAmountCents) return null;
  return cents;
}

/// Mensaje de validación (en español) o null si el importe es válido.
String? validateEuroAmount(String? input) {
  final text = (input ?? '').trim();
  if (text.isEmpty) return 'Indica el importe';
  final cents = parseEuroCents(text);
  if (cents != null) return null;
  final cleaned = text.replaceAll(_currency, '').replaceAll(' ', '');
  if (RegExp(r'^\d{1,3},\d{3}$').hasMatch(cleaned)) {
    return 'Importe ambiguo: escribe 4.500 o 4500,00';
  }
  if (RegExp(r'^\d+[.,]\d{3,}$').hasMatch(cleaned)) {
    return 'Máximo dos decimales (p. ej. 4500,00)';
  }
  if (RegExp(r'^[0.,]+$').hasMatch(cleaned)) return 'El importe debe ser mayor que cero';
  return 'Importe no válido. Usa por ejemplo 4500, 4.500 o 4.500,00';
}

/// 450000 -> "4.500,00 €".
String formatEuros(int cents) {
  final negative = cents < 0;
  final abs = cents.abs();
  final euros = (abs ~/ 100).toString();
  final buffer = StringBuffer();
  for (var i = 0; i < euros.length; i++) {
    if (i > 0 && (euros.length - i) % 3 == 0) buffer.write('.');
    buffer.write(euros[i]);
  }
  final fraction = (abs % 100).toString().padLeft(2, '0');
  return '${negative ? '-' : ''}$buffer,$fraction €';
}

/// Céntimos -> texto editable que el backend acepta sin ambigüedad
/// ("4500" o "4500,50"; nunca separador de miles).
String centsToInput(int cents) {
  final euros = cents ~/ 100;
  final fraction = cents % 100;
  return fraction == 0 ? '$euros' : '$euros,${fraction.toString().padLeft(2, '0')}';
}
