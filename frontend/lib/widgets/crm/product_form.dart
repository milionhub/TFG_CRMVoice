// Alta y edición de producto (I.8) sobre POST/PUT /products: nombre y PVP.
// Mismo Interaction System que Cliente/Contacto (CrmFormShell, FormSections,
// errores del servidor por campo). Sin stock: CRMVoice no gestiona inventario.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/money.dart';
import '../../models/product.dart';
import '../../services/api_service.dart';
import 'client_form.dart' show maxLength;
import 'crm_ui.dart';
import 'form_shell.dart';

/// Producto guardado, o null si se cancela.
Future<Product?> openProductForm(BuildContext context, {Product? product}) =>
    openCrmForm<Product>(context, ProductForm(product: product));

/// Mensaje de validación del PVP (mismas reglas que los importes de ventas).
String? validateProductPrice(String? input) {
  if ((input ?? '').trim().isEmpty) return 'Indica el PVP';
  return validateEuroAmount(input)?.replaceAll('importe', 'PVP').replaceAll('Importe', 'PVP');
}

class ProductForm extends StatefulWidget {
  final Product? product;

  const ProductForm({super.key, this.product});

  @override
  State<ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<ProductForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.product?.name);
  late final _price = TextEditingController(
      text: widget.product?.priceCents == null ? null : centsToInput(widget.product!.priceCents!));

  bool _saving = false;
  ApiException? _error;

  bool get _isEdit => widget.product != null;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final input = ProductInput(name: _name.text, price: _price.text);
    final api = context.read<ApiService>();
    try {
      final saved = _isEdit ? await api.updateProduct(widget.product!.id, input) : await api.createProduct(input);
      if (mounted) Navigator.pop(context, saved);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final cents = parseEuroCents(_price.text);
    return CrmFormShell(
      busy: _saving,
      title: _isEdit ? 'Editar producto' : 'Nuevo producto',
      maxWidth: 540,
      actions: [
        FormCancelButton(onPressed: _saving ? null : () => Navigator.pop(context)),
        SaveButton(saving: _saving, onPressed: _save, label: _isEdit ? 'Guardar cambios' : 'Crear producto'),
      ],
      body: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null)
              FormErrorNotice(
                message: error.message,
                details: error.issueMessages,
                action: error.kind == ApiErrorKind.duplicate
                    ? Text('Busca «${_name.text.trim()}» en Productos para editar el que ya existe.',
                        style: const TextStyle(fontSize: 13))
                    : null,
              ),
            FormSections(
              children: [
                FormSection(
                  title: 'Datos del producto',
                  children: [
                    TextFormField(
                      key: const Key('product-name'),
                      controller: _name,
                      decoration: InputDecoration(
                        labelText: 'Nombre *',
                        prefixIcon: const Icon(Icons.sell_outlined),
                        errorText: error?.messageFor('name'),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (v) {
                        final text = v?.trim() ?? '';
                        if (text.isEmpty) return 'El nombre es obligatorio';
                        if (text.length < 2) return 'Mínimo 2 caracteres';
                        return maxLength(100)(v);
                      },
                    ),
                    TextFormField(
                      key: const Key('product-price'),
                      controller: _price,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'PVP *',
                        suffixText: '€',
                        helperText: cents != null ? '= ${formatEuros(cents)}' : 'Ej.: 89, 89,90 o 1.190,00',
                        errorText: error?.messageFor('price'),
                      ),
                      onChanged: (_) => setState(() {}),
                      onFieldSubmitted: (_) => _save(),
                      validator: validateProductPrice,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
