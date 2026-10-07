// Productos (I.8): catálogo comercial del CRM (nombre y PVP). Misma lista que
// usan los selectores de Nueva/Editar actividad, Registrar venta y el Action
// Engine (GET /products): un producto nuevo aparece en todos sin más.
// Estructura y lenguaje visual de Clientes (cabecera, buscador, contador y una
// única superficie de listado); cada fila con su menú «⋮» (Editar / Eliminar).
// CRMVoice no gestiona inventario: aquí no hay stock.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/design/cv_theme.dart';
import '../core/design/cv_tokens.dart';
import '../core/money.dart';
import '../models/product.dart';
import '../services/api_service.dart';
import '../widgets/crm/crm_ui.dart';
import '../widgets/crm/product_form.dart';
import '../widgets/ui/cv_components.dart';
import '../widgets/ui/cv_feedback.dart';
import 'home_screen.dart';

class ProductsScreen extends StatelessWidget {
  const ProductsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppShell(
      currentIndex: 4,
      title: 'Productos',
      body: CrmTheme(child: ProductsContent()),
    );
  }
}

class ProductsContent extends StatefulWidget {
  const ProductsContent({super.key});

  @override
  State<ProductsContent> createState() => _ProductsContentState();
}

enum _ProductAction { edit, delete }

class _ProductsContentState extends State<ProductsContent> {
  final _search = TextEditingController();
  int _request = 0;

  bool _loading = true;
  String? _error;
  List<Product> _products = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request; // las respuestas antiguas se descartan
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final products = await context.read<ApiService>().products();
      if (!mounted || request != _request) return;
      setState(() {
        _products = products;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = userMessage(e);
        _loading = false;
      });
    }
  }

  List<Product> get _visible => _products.where((p) => productMatches(p, _query)).toList();

  Future<void> _create() async {
    final created = await openProductForm(context);
    if (created == null || !mounted) return;
    showSuccess(context, 'Producto «${created.name}» creado');
    _load();
  }

  Future<void> _edit(Product product) async {
    final saved = await openProductForm(context, product: product);
    if (saved == null || !mounted) return;
    showSuccess(context, 'Producto «${saved.name}» guardado');
    _load();
  }

  Future<void> _delete(Product product) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Eliminar producto',
      message: '¿Seguro que quieres eliminar «${product.name}» del catálogo? No se puede deshacer.',
    );
    if (!confirmed || !mounted) return;
    try {
      await context.read<ApiService>().deleteProduct(product.id);
      if (!mounted) return;
      showSuccess(context, 'Producto eliminado');
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.kind == ApiErrorKind.conflict) {
        // En uso por actividades, ventas o facturas: se conserva el histórico
        await showCvNotice(context, tone: CvFeedbackTone.warning, title: 'No se puede eliminar', message: e.message);
      } else {
        showFailure(context, e.message);
      }
    } catch (e) {
      if (mounted) showFailure(context, userMessage(e));
    }
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = CvPageBody.insets(constraints.maxWidth);
        final horizontal = EdgeInsets.symmetric(horizontal: insets.left);
        final wide = constraints.maxWidth >= CvBreakpoints.tablet;
        return RefreshIndicator(
          onRefresh: _load,
          color: CvColors.primaryDark,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(insets.left, insets.top, insets.right, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CvPageHeader(
                        title: 'Productos',
                        subtitle: 'Gestiona el catálogo comercial de tu CRM.',
                        action: CvPrimaryButton(
                          label: 'Nuevo producto',
                          icon: Icons.add_rounded,
                          onPressed: _create,
                        ),
                      ),
                      const SizedBox(height: CvSpace.xl),
                      CvSearchField(
                        controller: _search,
                        hint: 'Buscar producto por nombre',
                        onChanged: (v) => setState(() => _query = v.trim()),
                        onSubmitted: (v) => setState(() => _query = v.trim()),
                        onClear: _clearSearch,
                      ),
                      const SizedBox(height: CvSpace.lg),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: horizontal.copyWith(bottom: insets.bottom),
                sliver: _body(wide),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Estados: carga inicial, error, catálogo vacío, búsqueda sin resultados y listado.
  Widget _body(bool wide) {
    if (_loading && _products.isEmpty) {
      return const SliverToBoxAdapter(
        child: CvStatePanel(
          icon: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: CvColors.primaryDark),
          ),
          title: 'Cargando productos…',
        ),
      );
    }
    if (_error != null && !_loading) {
      return SliverToBoxAdapter(
        child: CvStatePanel(
          icon: const Icon(Icons.cloud_off_outlined),
          title: 'No se pudieron cargar los productos.',
          message: _error,
          action: CvSecondaryButton(label: 'Reintentar', icon: Icons.refresh_rounded, onPressed: _load),
        ),
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return SliverToBoxAdapter(
        child: _query.isEmpty
            ? CvStatePanel(
                icon: const Icon(Icons.sell_outlined),
                title: 'Tu catálogo está vacío.',
                message: 'Crea tu primer producto para usarlo en actividades y ventas.',
                action: CvPrimaryButton(label: 'Crear el primero', icon: Icons.add_rounded, onPressed: _create),
              )
            : CvStatePanel(
                icon: const Icon(Icons.search_off_rounded),
                title: 'No encontramos productos para esta búsqueda.',
                message: 'Ningún producto coincide con «$_query».',
                action: TextButton(
                  onPressed: _clearSearch,
                  style: TextButton.styleFrom(foregroundColor: CvColors.primaryDark),
                  child: const Text('Limpiar búsqueda'),
                ),
              ),
      );
    }

    final n = visible.length;
    final count = _query.isEmpty
        ? (n == 1 ? '1 producto' : '$n productos')
        : (n == 1 ? '1 producto encontrado' : '$n productos encontrados');

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(left: 2, bottom: CvSpace.sm),
            child: Row(
              children: [
                Text(count, key: const Key('products-count'), style: CvText.helper.copyWith(fontSize: 13)),
                if (_loading) ...[
                  const SizedBox(width: CvSpace.sm),
                  const SizedBox(
                    width: 64,
                    child: LinearProgressIndicator(minHeight: 2, color: CvColors.primary),
                  ),
                ],
              ],
            ),
          ),
        ),
        CvSliverListSurface(
          itemCount: n,
          itemBuilder: (context, i) {
            final p = visible[i];
            return ProductRow(
              key: ValueKey('product-${p.id}'),
              product: p,
              wide: wide,
              onTap: () => _edit(p),
              menu: CvContextMenu<_ProductAction>(
                tooltip: 'Acciones del producto',
                onSelected: (action) => action == _ProductAction.edit ? _edit(p) : _delete(p),
                entries: const [
                  CvMenuEntry(value: _ProductAction.edit, label: 'Editar producto', icon: Icons.edit_outlined),
                  CvMenuEntry(
                    value: _ProductAction.delete,
                    label: 'Eliminar producto',
                    icon: Icons.delete_outline_rounded,
                    danger: true,
                    dividerBefore: true,
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Fila de producto con el mismo aspecto que CvEntityRow (altura, hover,
/// tipografía): icono del catálogo, nombre y PVP. Escritorio/tablet: el PVP
/// en su columna, alineado a la derecha; móvil: debajo del nombre.
class ProductRow extends StatelessWidget {
  final Product product;
  final bool wide;
  final VoidCallback onTap;
  final Widget menu;

  const ProductRow({super.key, required this.product, required this.wide, required this.onTap, required this.menu});

  @override
  Widget build(BuildContext context) {
    final p = product;
    final price = p.priceCents == null ? 'Sin PVP' : formatEuros(p.priceCents!);
    final priceStyle = CvText.label.copyWith(
      fontSize: 14.5,
      color: p.priceCents == null ? CvColors.textSecondary : CvColors.textPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: CvColors.background,
        highlightColor: CvColors.primarySoft.withValues(alpha: 0.6),
        splashColor: CvColors.primary.withValues(alpha: 0.10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(CvSpace.md, CvSpace.sm, CvSpace.xs, CvSpace.sm),
            child: Row(
              children: [
                const _ProductIcon(),
                const SizedBox(width: CvSpace.sm + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: CvText.label.copyWith(fontSize: 14.5)),
                      if (!wide) ...[
                        const SizedBox(height: 2),
                        Text(price, key: ValueKey('product-price-${p.id}'),
                            style: CvText.helper.copyWith(fontSize: 13)),
                      ],
                    ],
                  ),
                ),
                if (wide) ...[
                  const SizedBox(width: CvSpace.md),
                  SizedBox(
                    width: 140,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('PVP', style: CvText.helper.copyWith(fontSize: 12)),
                        Text(price, key: ValueKey('product-price-${p.id}'), textAlign: TextAlign.right,
                            style: priceStyle),
                      ],
                    ),
                  ),
                  const SizedBox(width: CvSpace.sm),
                ],
                menu,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProductIcon extends StatelessWidget {
  const _ProductIcon();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CvColors.primarySoft,
          borderRadius: BorderRadius.circular(CvRadius.control),
        ),
        child: const Icon(Icons.sell_outlined, size: 18, color: CvColors.primaryDark),
      ),
    );
  }
}
