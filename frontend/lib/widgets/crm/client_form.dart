// Alta y edición de cliente (H.3) sobre POST/PUT /clients (ClientIn).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/crm.dart';
import '../../services/api_service.dart';
import '../ui/cv_feedback.dart';
import 'crm_ui.dart';
import 'form_shell.dart';

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final _phonePattern = RegExp(r'^[0-9 +\-()]{6,20}$');

String? validateOptionalEmail(String? value) {
  final v = value?.trim() ?? '';
  if (v.isEmpty) return null;
  if (v.length > 120 || !_emailPattern.hasMatch(v)) return 'Email no válido';
  return null;
}

String? validateOptionalPhone(String? value) {
  final v = value?.trim() ?? '';
  if (v.isEmpty) return null;
  if (!_phonePattern.hasMatch(v)) return 'Teléfono no válido (6 a 20 dígitos, espacios, +, - o paréntesis)';
  return null;
}

String? Function(String?) maxLength(int max) =>
    (value) => (value?.trim().length ?? 0) > max ? 'Máximo $max caracteres' : null;

/// Resultado de guardar: el cliente y, si el backend avisó, sus avisos.
Future<ClientSaveResult?> openClientForm(BuildContext context, {Client? client}) =>
    openCrmForm<ClientSaveResult>(context, ClientForm(client: client));

class ClientForm extends StatefulWidget {
  final Client? client;

  const ClientForm({super.key, this.client});

  @override
  State<ClientForm> createState() => _ClientFormState();
}

class _ClientFormState extends State<ClientForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.client?.name);
  late final _alias = TextEditingController(text: widget.client?.alias);
  late final _city = TextEditingController(text: widget.client?.city);
  late final _province = TextEditingController(text: widget.client?.province);
  late final _phone = TextEditingController(text: widget.client?.phone);
  late final _email = TextEditingController(text: widget.client?.email);
  late final _cif = TextEditingController(text: widget.client?.cif);

  bool _saving = false;
  ApiException? _error;

  bool get _isEdit => widget.client != null;

  @override
  void dispose() {
    for (final c in [_name, _alias, _city, _province, _phone, _email, _cif]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final input = ClientInput(
      name: _name.text,
      alias: _alias.text,
      city: _city.text,
      province: _province.text,
      // Sin pantalla de grupos en H.3: la edición conserva el grupo actual
      groupId: widget.client?.groupId,
      phone: _phone.text,
      email: _email.text,
      cif: _cif.text,
    );
    final api = context.read<ApiService>();
    try {
      final result = _isEdit ? await api.updateClient(widget.client!.id, input) : await api.createClient(input);
      if (!mounted) return;
      if (result.warnings.isNotEmpty) {
        // Ya está guardado: el aviso no debe dejar el botón en "Guardando..."
        // ni permitir un segundo envío (el formulario se cierra al aceptar)
        setState(() => _saving = false);
        await showCvNotice(
          context,
          tone: CvFeedbackTone.warning,
          title: 'Cliente guardado con un aviso',
          message: result.warnings.map((w) => w.message).join('\n'),
        );
        if (!mounted) return;
      }
      Navigator.pop(context, result);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _serverError(String field) => _error?.messageFor(field);

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return CrmFormShell(
      busy: _saving,
      title: _isEdit ? 'Editar cliente' : 'Nuevo cliente',
      actions: [
        FormCancelButton(onPressed: _saving ? null : () => Navigator.pop(context)),
        SaveButton(saving: _saving, onPressed: _save, label: _isEdit ? 'Guardar cambios' : 'Crear cliente'),
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
                action: error.kind == ApiErrorKind.duplicate && error.existingId != null
                    ? Text('Busca «${_name.text.trim()}» en Clientes para abrir el que ya existe.',
                        style: const TextStyle(fontSize: 13))
                    : null,
              ),
            FormSections(
              children: [
                FormSection(
                  title: 'Datos principales',
                  children: [
                    TextFormField(
                      controller: _name,
                      decoration: InputDecoration(
                        labelText: 'Razón social *',
                        prefixIcon: const Icon(Icons.business_outlined),
                        errorText: _serverError('name'),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (v) {
                        final text = v?.trim() ?? '';
                        if (text.isEmpty) return 'La razón social es obligatoria';
                        if (text.length < 2) return 'Mínimo 2 caracteres';
                        return maxLength(120)(v);
                      },
                    ),
                    TextFormField(
                      controller: _alias,
                      decoration: InputDecoration(
                        labelText: 'Alias / nombre comercial',
                        errorText: _serverError('alias'),
                      ),
                      validator: maxLength(60),
                    ),
                  ],
                ),
                FormSection(
                  title: 'Ubicación',
                  children: [
                    FieldPair(
                      first: TextFormField(
                        controller: _city,
                        decoration: InputDecoration(labelText: 'Población', errorText: _serverError('city')),
                        validator: maxLength(80),
                      ),
                      second: TextFormField(
                        controller: _province,
                        decoration: InputDecoration(labelText: 'Provincia', errorText: _serverError('province')),
                        validator: maxLength(80),
                      ),
                    ),
                  ],
                ),
                FormSection(
                  title: 'Contacto',
                  children: [
                    FieldPair(
                      first: TextFormField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                            labelText: 'Teléfono',
                            prefixIcon: const Icon(Icons.phone_outlined),
                            errorText: _serverError('phone')),
                        validator: validateOptionalPhone,
                      ),
                      second: TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                            labelText: 'Email',
                            prefixIcon: const Icon(Icons.email_outlined),
                            errorText: _serverError('email')),
                        validator: validateOptionalEmail,
                      ),
                    ),
                  ],
                ),
                FormSection(
                  title: 'Información fiscal',
                  children: [
                    TextFormField(
                      controller: _cif,
                      decoration: InputDecoration(labelText: 'CIF', errorText: _serverError('cif')),
                      validator: maxLength(20),
                    ),
                    if (widget.client?.groupName != null)
                      ReadOnlyField(label: 'Grupo', value: widget.client!.groupName!, icon: Icons.account_tree_outlined),
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

// =====================================================================
// Contactos
// =====================================================================

/// Alta (contact == null) o edición de un contacto del cliente indicado.
Future<Contact?> openContactForm(BuildContext context,
        {required int clientId, required String clientName, Contact? contact}) =>
    openCrmForm<Contact>(context, ContactForm(clientId: clientId, clientName: clientName, contact: contact));

class ContactForm extends StatefulWidget {
  final int clientId;
  final String clientName;
  final Contact? contact;

  const ContactForm({super.key, required this.clientId, required this.clientName, this.contact});

  @override
  State<ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends State<ContactForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.contact?.name);
  late final _role = TextEditingController(text: widget.contact?.role);
  late final _phone = TextEditingController(text: widget.contact?.phone);
  late final _email = TextEditingController(text: widget.contact?.email);

  bool _saving = false;
  ApiException? _error;

  bool get _isEdit => widget.contact != null;

  @override
  void dispose() {
    for (final c in [_name, _role, _phone, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final input = ContactInput(name: _name.text, role: _role.text, phone: _phone.text, email: _email.text);
    final api = context.read<ApiService>();
    try {
      final saved = _isEdit
          ? await api.updateContact(widget.contact!.id, input)
          : await api.createContact(widget.clientId, input);
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
    return CrmFormShell(
      busy: _saving,
      title: _isEdit ? 'Editar contacto' : 'Nuevo contacto',
      maxWidth: 540,
      actions: [
        FormCancelButton(onPressed: _saving ? null : () => Navigator.pop(context)),
        SaveButton(saving: _saving, onPressed: _save, label: _isEdit ? 'Guardar cambios' : 'Crear contacto'),
      ],
      body: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null) FormErrorNotice(message: error.message, details: error.issueMessages),
            FormSections(
              children: [
                ReadOnlyField(label: 'Cliente', value: widget.clientName, icon: Icons.business_outlined),
                FormSection(
                  title: 'Datos del contacto',
                  children: [
                    TextFormField(
                      controller: _name,
                      decoration: InputDecoration(
                        labelText: 'Nombre *',
                        prefixIcon: const Icon(Icons.person_outline),
                        errorText: error?.messageFor('name') ?? error?.messageFor('contact'),
                      ),
                      validator: (v) {
                        final text = v?.trim() ?? '';
                        if (text.isEmpty) return 'El nombre es obligatorio';
                        if (text.length < 2) return 'Mínimo 2 caracteres';
                        return maxLength(80)(v);
                      },
                    ),
                    TextFormField(
                      controller: _role,
                      decoration: InputDecoration(
                        labelText: 'Cargo',
                        prefixIcon: const Icon(Icons.badge_outlined),
                        errorText: error?.messageFor('role'),
                      ),
                      validator: maxLength(80),
                    ),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                          labelText: 'Teléfono',
                          prefixIcon: const Icon(Icons.phone_outlined),
                          errorText: error?.messageFor('phone')),
                      validator: validateOptionalPhone,
                    ),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                          labelText: 'Email',
                          prefixIcon: const Icon(Icons.email_outlined),
                          errorText: error?.messageFor('email')),
                      validator: validateOptionalEmail,
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
