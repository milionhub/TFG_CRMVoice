// Catálogo de productos (I.8): nombre y PVP. Misma fuente que los selectores
// de actividades y ventas (GET /products). CRMVoice no gestiona inventario:
// un producto no tiene stock (la cantidad de una venta son unidades vendidas).

int? _int(Object? value) => value is int ? value : (value is num ? value.toInt() : null);

String? _str(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

class Product {
  final int id;
  final String name;

  /// PVP en céntimos (el backend guarda euros; se convierte sin coma flotante al mostrar).
  final int? priceCents;

  const Product({required this.id, required this.name, this.priceCents});

  static Product? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _int(json['id']);
    if (id == null) return null;
    final price = json['price'];
    return Product(
      id: id,
      name: _str(json['name']) ?? '#$id',
      priceCents: price is num ? (price * 100).round() : null,
    );
  }

  static List<Product> listFrom(Object? json) =>
      json is List ? json.map(fromJson).whereType<Product>().toList() : const [];
}

/// Alta y edición (POST/PUT /products): el PVP se envía como texto y lo
/// interpreta el backend con las mismas reglas que los importes de ventas.
class ProductInput {
  final String name;
  final String price;

  const ProductInput({required this.name, required this.price});

  Map<String, dynamic> toJson() => {'name': name.trim(), 'price': price.trim()};
}

/// Búsqueda local sin mayúsculas ni tildes ("raton" encuentra «Ratón Faro»).
bool productMatches(Product product, String query) {
  final needle = _fold(query.trim());
  return needle.isEmpty || _fold(product.name).contains(needle);
}

String _fold(String s) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñç';
  const to = 'aaaaeeeeiiiioooouuuunc';
  final buffer = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    buffer.write(i >= 0 ? to[i] : ch);
  }
  return buffer.toString();
}
