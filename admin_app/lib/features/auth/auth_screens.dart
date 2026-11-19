import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/logo.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: ref.read(sessionProvider).email ?? '');
  final _password = TextEditingController();
  final _totp = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _totp.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).login(email: _email.text, password: _password.text, totp: _totp.text);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
      _totp.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = ref.watch(sessionProvider).message;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: AutofillGroup(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Center(child: FlarianeLogo(size: 88, withWordmark: true)),
                    if (AppConfig.isTest) ...[
                      const SizedBox(height: 10),
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(color: const Color(0xFFF59E0B), borderRadius: BorderRadius.circular(20)),
                          child: const Text('SERVEUR DE TEST', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1)),
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    if (message != null) ...[
                      Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.warning)),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _email,
                      decoration: const InputDecoration(labelText: 'Email'),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      validator: (v) => (v ?? '').contains('@') ? null : 'Email invalide',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      decoration: const InputDecoration(labelText: 'Mot de passe'),
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      validator: (v) => (v ?? '').isEmpty ? 'Requis' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _totp,
                      decoration: const InputDecoration(labelText: 'Code à 6 chiffres (si ton compte en a un)'),
                      keyboardType: TextInputType.number,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                      validator: (v) => (v ?? '').isEmpty || RegExp(r'^\d{6}$').hasMatch(v!) ? null : '6 chiffres',
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: AppColors.danger)),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : const Text('Se connecter'),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DevicePendingScreen extends ConsumerWidget {
  const DevicePendingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deviceId = ref.watch(sessionProvider).deviceId;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.phonelink_lock_rounded, size: 56, color: AppColors.primary),
            const SizedBox(height: 16),
            Text('Appareil en attente d’approbation', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(
              'Un super administrateur doit approuver cet appareil (n° $deviceId) dans le panneau web, '
              'rubrique Appareils. Reconnectez-vous ensuite.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: () => ref.read(sessionProvider.notifier).init(),
              child: const Text('Se reconnecter'),
            ),
          ]),
        ),
      ),
    );
  }
}

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref.read(sessionProvider.notifier).unlock();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final message = ref.watch(sessionProvider).message;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.lock_rounded, size: 56, color: AppColors.primary),
            const SizedBox(height: 16),
            Text('Application verrouillée', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 28),
            FilledButton(onPressed: _busy ? null : _unlock, child: const Text('Déverrouiller')),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.read(sessionProvider.notifier).logout(),
              child: const Text('Se déconnecter'),
            ),
          ]),
        ),
      ),
    );
  }
}


/// auth: the back-office account signed in with a temporary password. A new one is chosen here, then the sign-in goes on.
class NewPasswordScreen extends ConsumerStatefulWidget {
  const NewPasswordScreen({super.key});

  @override
  ConsumerState<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

class _NewPasswordScreenState extends ConsumerState<NewPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).setNewPassword(current: _current.text, next: _next.text);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.code == 'invalid_credentials' ? 'Mot de passe temporaire incorrect.' : e.message);
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
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _form,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Icon(Icons.password_rounded, size: 56, color: AppColors.primary),
                    const SizedBox(height: 16),
                    Text('Nouveau mot de passe', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text('Remplacez le mot de passe temporaire pour continuer.', textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _current,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Mot de passe temporaire'),
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
                    TextButton(onPressed: () => ref.read(sessionProvider.notifier).cancelPasswordChange(), child: const Text('Annuler')),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}
