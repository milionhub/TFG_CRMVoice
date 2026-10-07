// Ventas (H.3) sobre el contrato H.2:
// - alta: UNA operación con 1 a 5 líneas (POST /sales, todas o ninguna);
// - edición: una venta = una línea (PUT /sales/{id}).
// El importe se escribe en euros y viaja como TEXTO: lo interpreta el
// backend en céntimos. Aquí solo se valida y se enseña la interpretación.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';
import '../../core/money.dart';
import '../../models/crm.dart';
import '../../services/api_service.dart';
import '../ui/cv_components.dart';
import 'crm_ui.dart';
import 'form_shell.dart';

const int maxSaleLines = 5;

/// Alta (sale == null) o edición de una venta del cliente. true si se guardó.
Future<bool?> openSaleForm(
  BuildContext context, {
  required Client client,
  required List<Contact> contacts,
  Sale? sale,
}) => openCrmForm<bool>(context, SaleForm(client: client, contacts: contacts, sale: sale));

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
        await api.createSales(
          SaleCreateInput(
            clientId: widget.client.id,
            contactId: _contactId,
            saleDate: date,
            notes: _notes.text,
            lines: _lines.map((l) => l.toInput()).toList(),
          ),
        );
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
  String? _lineError(int index, String field) => _error?.messageFor(_isEdit ? field : 'lines[$index].$field');

  @override
  Widget build(BuildContext context) {
    final total = _totalCents;
    return CrmFormShell(
      busy: _saving,
      title: _isEdit ? 'Editar venta' : 'Registrar venta',
      maxWidth: 680,
      actions: [
        FormCancelButton(onPressed: _saving ? null : () => Navigator.pop(context)),
        SaveButton(
          saving: _saving,
          onPressed: _loading || _loadError != null ? null : _save,
          label: _isEdit ? 'Guardar cambios' : 'Guardar venta',
        ),
      ],
      body: _loading
          ? const FormLoadState.loading()
          : _loadError != null
          ? FormLoadState.error(error: _loadError!, onRetry: _loadProducts)
          : Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) FormErrorNotice(message: _error!.message, details: _error!.issueMessages),
                  FormSections(
                    children: [
                      FormSection(
                        title: 'Venta',
                        children: [
                          ReadOnlyField(label: 'Cliente', value: widget.client.name, icon: Icons.business_outlined),
                          ..._header(),
                        ],
                      ),
                      FormSection(
                        title: _isEdit ? 'Línea de venta' : 'Líneas de venta',
                        children: [
                          AnimatedSize(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            alignment: Alignment.topCenter,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < _lines.length; i++) ...[
                                  if (i > 0)
                                    const Padding(
                                      padding: EdgeInsets.symmetric(vertical: CvSpace.md),
                                      child: Divider(height: 1, thickness: 1, color: CvColors.border),
                                    ),
                                  _lineFields(i),
                                ],
                              ],
                            ),
                          ),
                          if (!_isEdit)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: CvTextAction(
                                label: _lines.length >= maxSaleLines ? 'Máximo $maxSaleLines líneas' : 'Añadir línea',
                                onPressed: _lines.length >= maxSaleLines ? null : _addLine,
                              ),
                            ),
                        ],
                      ),
                      SaleTotalBar(
                        label: _isEdit ? 'Importe' : 'Total',
                        detail: _isEdit ? null : '${_lines.length} ${_lines.length == 1 ? 'línea' : 'líneas'}',
                        total: total,
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  /// Contacto y fecha (en fila si cabe) y notas.
  List<Widget> _header() {
    final contactField = DropdownButtonFormField<int?>(
      initialValue: _contactId,
      isExpanded: true,
      icon: cvSelectChevron,
      items: [
        const DropdownMenuItem<int?>(value: null, child: Text('Sin contacto')),
        ...widget.contacts.map(
          (c) => DropdownMenuItem<int?>(
            value: c.id,
            child: Text(c.name, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: (v) => setState(() => _contactId = v),
      decoration: InputDecoration(
        labelText: 'Contacto',
        prefixIcon: const Icon(Icons.person_outline),
        errorText: _error?.messageFor('contact'),
      ),
    );
    final dateField = TapField(
      key: const Key('sale-date-field'),
      label: 'Fecha de venta *',
      value: formatDate(_saleDate),
      icon: Icons.calendar_today_outlined,
      errorText: _error?.messageFor('sale_date'),
      onTap: _pickDate,
    );
    return [
      FieldPair(first: contactField, second: dateField),
      TextFormField(
        controller: _notes,
        maxLength: 500,
        decoration: InputDecoration(labelText: 'Notas', errorText: _error?.messageFor('notes')),
      ),
    ];
  }

  /// Una línea: cabecera «Línea N» (+ quitar), producto/concepto y
  /// cantidad + importe. Sin tarjeta: las líneas se separan con un divisor.
  Widget _lineFields(int index) {
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
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(() => line.product = null),
              ),
            ),
            child: Text(
              line.product!.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, color: CvColors.textPrimary),
            ),
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
                icon: const Icon(Icons.search_rounded),
                onPressed: () => _pickProduct(line),
              ),
            ),
            validator: (v) =>
                line.product == null && (v?.trim().isEmpty ?? true) ? 'Indica un producto o un concepto' : null,
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

    return Column(
      key: line.key,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 40,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _isEdit ? 'Línea' : 'Línea ${index + 1}',
                  style: CvText.label.copyWith(fontSize: 13, color: CvColors.textSecondary),
                ),
              ),
              if (!_isEdit)
                IconButton(
                  tooltip: 'Quitar línea',
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  style: IconButton.styleFrom(
                    foregroundColor: CvColors.textSecondary,
                    hoverColor: CvColors.dangerSoft,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.sm)),
                  ),
                  onPressed: _lines.length <= 1 ? null : () => _removeLine(index),
                ),
            ],
          ),
        ),
        const SizedBox(height: CvSpace.xxs),
        productField,
        const SizedBox(height: CvFormLayout.fieldGap),
        FieldPair(minWidth: 400, firstFlex: 2, secondFlex: 3, first: quantityField, second: amountField),
      ],
    );
  }
}

/// Total de la venta: superficie teal muy suave y cifra con presencia.
/// Lo comparten el formulario de venta y la revisión de Voice (I.6.4).
class SaleTotalBar extends StatelessWidget {
  final String label;
  final String? detail;
  final int? total;

  /// Texto si falta algún importe.
  final String missing;

  /// Key del texto del importe (los tests lo leen).
  final Key totalKey;

  const SaleTotalBar({
    super.key,
    required this.label,
    required this.detail,
    required this.total,
    this.missing = '—',
    this.totalKey = const Key('sale-total'),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: CvColors.primarySoft,
        borderRadius: BorderRadius.circular(CvRadius.control + 2),
        border: Border.all(color: CvColors.primary.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: CvText.label.copyWith(fontSize: 14, color: CvColors.primaryDark)),
                if (detail != null) Text(detail!, style: CvText.helper.copyWith(fontSize: 12.5)),
              ],
            ),
          ),
          const SizedBox(width: CvSpace.sm),
          Flexible(
            child: Text(
              total == null ? missing : formatEuros(total!),
              key: totalKey,
              textAlign: TextAlign.right,
              style:
                  (total == null ? CvText.helper.copyWith(fontSize: 14, fontWeight: FontWeight.w600) : CvText.heading)
                      .copyWith(
                        fontSize: total == null ? 14 : 22,
                        letterSpacing: -0.4,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
            ),
          ),
        ],
      ),
    );
  }
}
