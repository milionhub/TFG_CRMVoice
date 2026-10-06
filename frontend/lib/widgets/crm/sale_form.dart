// Ventas (H.3) sobre el contrato H.2:
// - alta: UNA operación con 1 a 5 líneas (POST /sales, todas o ninguna);
// - edición: una venta = una línea (PUT /sales/{id}).
// El importe se escribe en euros y viaja como TEXTO: lo interpreta el
// backend en céntimos. Aquí solo se valida y se enseña la interpretación.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_colors.dart';
import '../../core/money.dart';
import '../../models/crm.dart';
import '../../services/api_service.dart';
import 'crm_ui.dart';
import 'form_shell.dart';

const int maxSaleLines = 5;

/// Alta (sale == null) o edición de una venta del cliente. true si se guardó.
Future<bool?> openSaleForm(
  BuildContext context, {
  required Client client,
  required List<Contact> contacts,
  Sale? sale,
}) =>
    openCrmForm<bool>(context, SaleForm(client: client, contacts: contacts, sale: sale));

class _Line {
  final Key key = UniqueKey();
  CatalogItem? product;
  final TextEditingController concept;
  final TextEditingController quantity;
  final TextEditingController amount;

  _Line({this.product, String? concept, int? quantity, String? amount})
      : concept = TextEditingController(text: concept),
        quantity = TextEditingController(text: quantity?.toString()),
        amount = TextEditingController(text: amount);

  void dispose() {
    concept.dispose();
    quantity.dispose();
    amount.dispose();
  }

  SaleLineInput toInput() => SaleLineInput(
        productId: product?.id,
        concept: product == null ? concept.text : null,
        quantity: int.tryParse(quantity.text.trim()),
        amount: amount.text,
      );
}

class SaleForm extends StatefulWidget {
  final Client client;
  final List<Contact> contacts;
  final Sale? sale;

  const SaleForm({super.key, required this.client, required this.contacts, this.sale});

  @override
  State<SaleForm> createState() => _SaleFormState();
}

class _SaleFormState extends State<SaleForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _notes = TextEditingController(text: widget.sale?.notes);
  late final List<_Line> _lines;
  int? _contactId;
  late DateTime _saleDate;

  bool _loading = true;
  String? _loadError;
  List<CatalogItem> _products = const [];

  bool _saving = false;
  ApiException? _error;

  bool get _isEdit => widget.sale != null;

  @override
  void initState() {
    super.initState();
    final sale = widget.sale;
    if (sale != null) {
      _lines = [
        _Line(
          product: sale.productId == null
              ? null
              : CatalogItem(sale.productId!, sale.productName ?? 'Producto #${sale.productId}'),
          concept: sale.concept,
          quantity: sale.quantity,
          amount: centsToInput(sale.amountCents),
        ),
      ];
      _contactId = widget.contacts.any((c) => c.id == sale.contactId) ? sale.contactId : null;
      _saleDate = DateTime.tryParse(sale.saleDate ?? '') ?? DateTime.now();
    } else {
      _lines = [_Line()];
      final now = DateTime.now();
      _saleDate = DateTime(now.year, now.month, now.day);
    }
    _loadProducts();
  }

  @override
  void dispose() {
    _notes.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _loadProducts() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final products = await context.read<ApiService>().productItems();
      if (mounted) setState(() => _products = products);
    } catch (e) {
      if (mounted) setState(() => _loadError = userMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _addLine() {
    if (_lines.length >= maxSaleLines) return;
    setState(() => _lines.add(_Line()));
  }

  void _removeLine(int index) {
    if (_lines.length <= 1) return;
    setState(() => _lines.removeAt(index).dispose());
  }

  Future<void> _pickProduct(_Line line) async {
    final picked = await showSearchPicker<CatalogItem>(
      context,
      title: 'Producto',
      items: _products,
      labelOf: (p) => p.name,
      hint: 'Buscar producto...',
    );
    if (picked != null && mounted) setState(() => line.product = picked);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _saleDate.isAfter(now) ? now : _saleDate,
      firstDate: DateTime(2000),
      lastDate: now, // una venta es un hecho: nunca futura
    );
    if (picked != null) setState(() => _saleDate = picked);
  }

  int? get _totalCents {
    var total = 0;
    for (final l in _lines) {
      final cents = parseEuroCents(l.amount.text);
      if (cents == null) return null;
      total += cents;
    }
    return total;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final api = context.read<ApiService>();
    final date = formatApiDate(_saleDate);
    try {
      if (_isEdit) {
        await api.updateSale(
          widget.sale!.id,
          SaleUpdateInput(
            clientId: widget.client.id,
            contactId: _contactId,
            saleDate: date,
            notes: _notes.text,
            line: _lines.single.toInput(),
          ),
        );
      } else {
        await api.createSales(SaleCreateInput(
          clientId: widget.client.id,
          contactId: _contactId,
          saleDate: date,
          notes: _notes.text,
          lines: _lines.map((l) => l.toInput()).toList(),
        ));
      }
      if (!mounted) return;
      showSuccess(
        context,
        _isEdit
            ? 'Venta actualizada'
            : (_lines.length == 1 ? 'Venta registrada' : 'Venta registrada (${_lines.length} líneas)'),
      );
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Error del servidor de un campo de la línea (alta: "lines[i].x"; edición: "x").
  String? _lineError(int index, String field) =>
      _error?.messageFor(_isEdit ? field : 'lines[$index].$field');

  @override
  Widget build(BuildContext context) {
    final total = _totalCents;
    return CrmFormShell(
      busy: _saving,
      title: _isEdit ? 'Editar venta' : 'Registrar venta',
      maxWidth: 680,
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancelar')),
        SaveButton(
          saving: _saving,
          onPressed: _loading || _loadError != null ? null : _save,
          label: _isEdit ? 'Guardar cambios' : 'Guardar venta',
        ),
      ],
      body: _loading
          ? const LoadingView()
          : _loadError != null
              ? ErrorView(message: _loadError!, onRetry: _loadProducts)
              : Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null) FormErrorBanner(message: _error!.message, details: _error!.issueMessages),
                      ReadOnlyField(label: 'Cliente', value: widget.client.name, icon: Icons.business),
                      const SizedBox(height: 12),
                      _header(),
                      const SizedBox(height: 16),
                      for (var i = 0; i < _lines.length; i++) _lineCard(i),
                      if (!_isEdit)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _lines.length >= maxSaleLines ? null : _addLine,
                            icon: const Icon(Icons.add),
                            label: Text(_lines.length >= maxSaleLines
                                ? 'Máximo $maxSaleLines líneas'
                                : 'Añadir línea'),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _isEdit ? 'Importe' : 'Total (${_lines.length} ${_lines.length == 1 ? 'línea' : 'líneas'})',
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            Text(
                              total == null ? '—' : formatEuros(total),
                              key: const Key('sale-total'),
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _header() {
    final contactField = DropdownButtonFormField<int?>(
      initialValue: _contactId,
      isExpanded: true,
      items: [
        const DropdownMenuItem<int?>(value: null, child: Text('Sin contacto')),
        ...widget.contacts.map((c) => DropdownMenuItem<int?>(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis))),
      ],
      onChanged: (v) => setState(() => _contactId = v),
      decoration: InputDecoration(
        labelText: 'Contacto',
        prefixIcon: const Icon(Icons.person_outline),
        errorText: _error?.messageFor('contact'),
      ),
    );
    final dateField = InkWell(
      key: const Key('sale-date-field'),
      onTap: _pickDate,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Fecha de venta *',
          prefixIcon: const Icon(Icons.calendar_today, size: 20),
          errorText: _error?.messageFor('sale_date'),
        ),
        child: Text(formatDate(_saleDate)),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth < 440
              ? Column(children: [contactField, const SizedBox(height: 12), dateField])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Expanded(child: contactField), const SizedBox(width: 12), Expanded(child: dateField)],
                ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _notes,
          maxLength: 500,
          decoration: InputDecoration(labelText: 'Notas', errorText: _error?.messageFor('notes')),
        ),
      ],
    );
  }

  Widget _lineCard(int index) {
    final line = _lines[index];
    final cents = parseEuroCents(line.amount.text);
    final productError = _lineError(index, 'product') ?? _lineError(index, 'concept');

    final productField = line.product != null
        ? InputDecorator(
            decoration: InputDecoration(
              labelText: 'Producto',
              prefixIcon: const Icon(Icons.inventory_2_outlined),
              errorText: productError,
              suffixIcon: IconButton(
                tooltip: 'Quitar producto (usar concepto libre)',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => line.product = null),
              ),
            ),
            child: Text(line.product!.name, overflow: TextOverflow.ellipsis),
          )
        : TextFormField(
            key: ValueKey('concept-${line.key}'),
            controller: line.concept,
            maxLength: 200,
            decoration: InputDecoration(
              labelText: 'Concepto *',
              helperText: 'Texto libre, o elige un producto del catálogo',
              errorText: productError,
              suffixIcon: IconButton(
                tooltip: 'Elegir producto del catálogo',
                icon: const Icon(Icons.inventory_2_outlined),
                onPressed: () => _pickProduct(line),
              ),
            ),
            validator: (v) => line.product == null && (v?.trim().isEmpty ?? true)
                ? 'Indica un producto o un concepto'
                : null,
          );

    final quantityField = TextFormField(
      key: ValueKey('quantity-${line.key}'),
      controller: line.quantity,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: 'Cantidad', errorText: _lineError(index, 'quantity')),
      validator: (v) {
        final text = v?.trim() ?? '';
        if (text.isEmpty) return null;
        final n = int.tryParse(text);
        if (n == null || n < 1 || n > 100000) return 'Entero entre 1 y 100.000';
        return null;
      },
    );

    final amountField = TextFormField(
      key: ValueKey('amount-${line.key}'),
      controller: line.amount,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: 'Importe total *',
        suffixText: '€',
        helperText: cents != null ? '= ${formatEuros(cents)}' : 'Ej.: 4500, 4.500 o 4.500,00',
        errorText: _lineError(index, 'amount'),
      ),
      onChanged: (_) => setState(() {}),
      validator: validateEuroAmount,
    );

    return Container(
      key: line.key,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_isEdit ? 'Línea' : 'Línea ${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              ),
              if (!_isEdit)
                IconButton(
                  tooltip: 'Quitar línea',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: _lines.length <= 1 ? null : () => _removeLine(index),
                ),
            ],
          ),
          productField,
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth < 400
                ? Column(children: [quantityField, const SizedBox(height: 12), amountField])
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: quantityField),
                      const SizedBox(width: 12),
                      Expanded(flex: 3, child: amountField),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
