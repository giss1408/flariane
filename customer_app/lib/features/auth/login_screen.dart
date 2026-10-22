import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/logo.dart';

/// Sign in or create an account with an Ivorian phone number and a password.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController();
  bool _creating = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = ref.read(authProvider.notifier);
    try {
      if (_creating) {
        await auth.register(_phone.text, _password.text, name: _name.text.trim().isEmpty ? null : _name.text.trim());
      } else {
        await auth.login(_phone.text, _password.text);
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _form,
                child: AutofillGroup(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Center(child: FlarianeLogo(size: 84, withWordmark: true)),
                    const SizedBox(height: 6),
                    const Text('Tes paniers SHEIN et Temu livrés à Abidjan', textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Se connecter')),
                        ButtonSegment(value: true, label: Text('Créer un compte')),
                      ],
                      selected: {_creating},
                      onSelectionChanged: (s) => setState(() {
                        _creating = s.first;
                        _error = null;
                      }),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      autofillHints: const [AutofillHints.telephoneNumber],
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 +]')), LengthLimitingTextInputFormatter(17)],
                      decoration: const InputDecoration(labelText: 'Numéro WhatsApp', hintText: '07 01 02 03 04'),
                      validator: (v) => (v ?? '').replaceAll(RegExp(r'\D'), '').length < 10 ? '10 chiffres' : null,
                    ),
                    if (_creating) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        autofillHints: const [AutofillHints.givenName],
                        decoration: const InputDecoration(labelText: 'Votre prénom'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      autofillHints: [_creating ? AutofillHints.newPassword : AutofillHints.password],
                      decoration: InputDecoration(
                        labelText: 'Mot de passe',
                        helperText: _creating ? '8 caractères minimum' : null,
                        suffixIcon: IconButton(
                          tooltip: _obscure ? 'Afficher' : 'Masquer',
                          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) => _creating && (v ?? '').length < 8 ? '8 caractères minimum' : ((v ?? '').isEmpty ? 'Requis' : null),
                    ),
                    if (_creating) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _confirm,
                        obscureText: _obscure,
                        decoration: const InputDecoration(labelText: 'Confirmer le mot de passe'),
                        validator: (v) => v != _password.text ? 'Les mots de passe diffèrent' : null,
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: AppColors.danger)),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : Text(_creating ? 'Créer mon compte' : 'Se connecter'),
                    ),
                    if (!_creating)
                      TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Mot de passe oublié'),
                            content: const Text('Écrivez-nous sur WhatsApp depuis votre numéro : nous vous enverrons un '
                                'mot de passe temporaire, à changer à la connexion.'),
                            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
                          ),
                        ),
                        child: const Text('Mot de passe oublié ?'),
                      ),
                    TextButton(
                      onPressed: () => launchUrl(Uri.parse('$apiBaseUrl/legal/confidentialite'), mode: LaunchMode.externalApplication),
                      child: const Text('Confidentialité', style: TextStyle(color: AppColors.muted)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}

/// Shown after an admin reset: the temporary password must be replaced before continuing.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key, this.forced = false});

  final bool forced;

  @override
  ConsumerState<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).changePassword(_current.text, _next.text);
      ref.invalidate(meProvider);
      if (mounted && !widget.forced) Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() => _error = e.code == 'invalid_credentials' ? 'Mot de passe actuel incorrect.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: FlarianeHeader(
          subtitle: 'Nouveau mot de passe',
          showBack: !widget.forced,
          actions: [
            if (widget.forced)
              TextButton(onPressed: () => ref.read(authProvider.notifier).logout(), child: const Text('Déconnexion')),
          ],
        ),
        body: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(24), children: [
            if (widget.forced) ...[
              const Text('Choisissez un nouveau mot de passe pour remplacer le mot de passe temporaire.'),
              const SizedBox(height: 16),
            ],
            TextFormField(
              controller: _current,
              obscureText: true,
              decoration: InputDecoration(labelText: widget.forced ? 'Mot de passe temporaire' : 'Mot de passe actuel'),
              validator: (v) => (v ?? '').isEmpty ? 'Requis' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _next,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(labelText: 'Nouveau mot de passe', helperText: '8 caractères minimum'),
              validator: (v) => (v ?? '').length < 8 ? '8 caractères minimum' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirmer'),
              validator: (v) => v != _next.text ? 'Les mots de passe diffèrent' : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _submit, child: const Text('Enregistrer')),
          ]),
        ),
      );
}
