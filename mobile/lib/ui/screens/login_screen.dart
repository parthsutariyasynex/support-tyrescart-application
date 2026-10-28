import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../widgets/common.dart';

/// Sign in with the same email and password as the website. The server address is the website's address.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = context.read<Session>().signOutReason;
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = context.read<Session>();
      await session.signIn(session.server, _email.text, _password.text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final email = await promptText(context, 'Reset your password', initial: _email.text.trim(), hint: 'Your email', ok: 'Send link');
    if (email == null || !mounted) return;
    final session = context.read<Session>();
    session.api.baseUrl = session.server;
    await attempt(context, () => session.repo.requestPasswordReset(email),
        done: 'If that email has an account, a reset link is on its way. Open it on this phone or a computer.');
  }

  /// Developer only: long-press the logo to point the app at another server (e.g. a phone on the office Wi-Fi testing
  /// a local server). Never shown on the normal sign-in screen; empty goes back to the address built into the app.
  Future<void> _developerServer() async {
    final session = context.read<Session>();
    final v = await promptText(context, 'Server (developer)', initial: session.server, hint: 'Empty = built-in address', ok: 'Save', allowEmpty: true);
    if (v == null || !mounted) return;
    await session.setServer(v);
    if (mounted) showMessage(context, 'Server: ${session.server.isEmpty ? 'not set' : session.server}');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                    const SizedBox(height: 12),
                    Center(
                      child: GestureDetector(
                        key: const Key('login-logo'),
                        onLongPress: _developerServer,
                        child: Container(
                          width: 96,
                          height: 96,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          padding: const EdgeInsets.all(8),
                          child: Image.asset('assets/icon/launcher_kl.png', fit: BoxFit.contain, semanticLabel: 'KL'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('TyresCart Support', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('Sign in with your team account', textAlign: TextAlign.center, style: TextStyle(color: scheme.outline)),
                    const SizedBox(height: 28),
                    if (_error != null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(8)),
                        child: Text(_error!, style: TextStyle(color: scheme.onErrorContainer)),
                      ),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
                      validator: (v) => (v ?? '').contains('@') ? null : 'Enter your email',
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: _hide,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(icon: Icon(_hide ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _hide = !_hide)),
                      ),
                      validator: (v) => (v ?? '').isEmpty ? 'Enter your password' : null,
                    ),
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                      child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)) : const Text('Sign in'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(onPressed: _busy ? null : _forgot, child: const Text('Forgot password?')),
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
