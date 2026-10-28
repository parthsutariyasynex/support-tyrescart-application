import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../logic/rules.dart';
import '../../models/models.dart';
import '../../state/workspace_data.dart';
import '../widgets/common.dart';
import 'admin_screens.dart';

/// Settings (web: /settings). Workspace pages (templates, team, preferences, automations, reports) are for owners
/// and admins, as on the website; the server checks every change again.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    Widget section(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Text(t, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        ListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          leading: Avatar(name: s.userName, colorKey: s.userId ?? 'me', size: 56),
          title: Text(s.userName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          subtitle: Text('${s.userEmail}\n${s.workspaceName} · ${roleLabel(s.role)}${s.role == 'owner' ? ' (owner)' : ''}'),
          isThreeLine: true,
          onTap: () => go(const ProfileScreen()),
        ),
        const Divider(),
        section('Your preferences'),
        ListTile(leading: const Icon(Icons.person_outline), title: const Text('Profile'), subtitle: const Text('Name, phone number, job title'), onTap: () => go(const ProfileScreen())),
        ListTile(leading: const Icon(Icons.lock_outline), title: const Text('Change password'), onTap: () => go(const PasswordScreen())),
        ListTile(leading: const Icon(Icons.notifications_outlined), title: const Text('Notifications'), onTap: () => go(const NotificationSettingsScreen())),
        ListTile(
          leading: const Icon(Icons.dark_mode_outlined),
          title: const Text('Theme'),
          subtitle: Text(switch (s.themeMode) { ThemeMode.dark => 'Dark', ThemeMode.light => 'Light', ThemeMode.system => 'Same as the phone' }),
          onTap: () async {
            final m = await showDialog<ThemeMode>(
              context: context,
              builder: (c) => SimpleDialog(title: const Text('Theme'), children: [
                for (final (mode, label) in const [(ThemeMode.dark, 'Dark'), (ThemeMode.light, 'Light'), (ThemeMode.system, 'Same as the phone')])
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, mode),
                    child: Row(children: [
                      Icon(mode == s.themeMode ? Icons.radio_button_checked : Icons.radio_button_off),
                      const SizedBox(width: 12),
                      Text(label),
                    ]),
                  ),
              ]),
            );
            if (m != null) await s.setThemeMode(m);
          },
        ),
        ListTile(leading: const Icon(Icons.swap_horiz), title: const Text('Switch workspace'), onTap: () => go(const WorkspacesScreen())),
        section('Inbox settings'),
        ListTile(leading: const Icon(Icons.bolt), title: const Text('Saved replies'), subtitle: const Text('Type / in a message to use them'), onTap: () => go(const SavedRepliesScreen())),
        if (s.isAdmin) ListTile(leading: const Icon(Icons.description_outlined), title: const Text('Message templates'), onTap: () => go(const TemplatesAdminScreen())),
        section('Contacts and data'),
        ListTile(leading: const Icon(Icons.label_outline), title: const Text('Labels'), onTap: () => go(const LabelsScreen())),
        if (s.isAdmin) ...[
          section('Company settings'),
          ListTile(leading: const Icon(Icons.business_outlined), title: const Text('Company and workspace preferences'), onTap: () => go(const WorkspacePrefsScreen())),
          ListTile(leading: const Icon(Icons.group_outlined), title: const Text('User management'), onTap: () => go(const TeamScreen())),
          ListTile(leading: const Icon(Icons.smart_toy_outlined), title: const Text('Simple automations'), onTap: () => go(const AutomationsScreen())),
          ListTile(leading: const Icon(Icons.assessment_outlined), title: const Text('Assignment report'), onTap: () => go(const ReportScreen())),
        ],
        section('About'),
        ListTile(leading: const Icon(Icons.dns_outlined), title: const Text('Server'), subtitle: Text(s.server)),
        if (s.whatsappPhone != null) ListTile(leading: const Icon(Icons.chat_outlined), title: const Text('WhatsApp number'), subtitle: Text(s.whatsappPhone!)),
        ListTile(
          leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
          title: Text('Sign out', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          onTap: () async {
            if (await confirm(context, 'Sign out?', 'You will stop getting alerts on this phone until you sign in again.', ok: 'Sign out')) {
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              await s.signOut();
            }
          },
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final s = context.read<Session>();
  late final _name = TextEditingController(text: s.userName);
  late final _phone = TextEditingController(text: s.phone ?? '');
  late final _job = TextEditingController(text: s.jobTitle ?? '');
  bool _busy = false;

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return showMessage(context, 'Enter your name', error: true);
    setState(() => _busy = true);
    final ok = await attempt(context, () async {
      await s.repo.updateMyProfile({'name': _name.text.trim(), 'phone': _phone.text.trim(), 'jobTitle': _job.text.trim()});
      await s.refreshMe();
    }, done: 'Profile saved');
    if (mounted) setState(() => _busy = false);
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 14),
          TextField(controller: TextEditingController(text: s.userEmail), enabled: false, decoration: const InputDecoration(labelText: 'Email')),
          const SizedBox(height: 14),
          TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone number (with country code)')),
          const SizedBox(height: 14),
          TextField(controller: _job, decoration: const InputDecoration(labelText: 'Job title')),
          const SizedBox(height: 24),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
        ]),
      );
}

class PasswordScreen extends StatefulWidget {
  const PasswordScreen({super.key});
  @override
  State<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends State<PasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  bool _busy = false;

  Future<void> _save() async {
    final n = _next.text;
    if (n.length < 8 || n.length > 72 || !RegExp(r'[A-Za-z]').hasMatch(n) || !RegExp(r'\d').hasMatch(n)) {
      return showMessage(context, 'Use 8-72 characters with a letter and a number', error: true);
    }
    if (n != _again.text) return showMessage(context, "The new passwords don't match", error: true);
    setState(() => _busy = true);
    final s = context.read<Session>();
    final ok = await attempt(context, () async {
      final token = await s.repo.changeMyPassword(_current.text, n);
      await s.useToken(token); // other sessions are signed out; this one continues
    }, done: 'Password changed. Your other sessions were signed out.');
    if (mounted) setState(() => _busy = false);
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Change password')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(controller: _current, obscureText: true, decoration: const InputDecoration(labelText: 'Current password')),
          const SizedBox(height: 14),
          TextField(controller: _next, obscureText: true, decoration: const InputDecoration(labelText: 'New password', helperText: '8-72 characters with a letter and a number')),
          const SizedBox(height: 14),
          TextField(controller: _again, obscureText: true, decoration: const InputDecoration(labelText: 'New password again')),
          const SizedBox(height: 24),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Change password')),
        ]),
      );
}

class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(children: [
        SwitchListTile(title: const Text('Sound'), subtitle: const Text('A sound for new customer messages'), value: s.soundOn, onChanged: s.setSound),
        SwitchListTile(
          title: const Text('Phone notifications'),
          subtitle: const Text('Alerts while the app is in the background (messages, assignments, @mentions)'),
          value: s.deviceNotificationsOn,
          onChanged: s.setDeviceNotifications,
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          subtitle: Text('Alerts come through the live connection, so they arrive while the app is open or recently in the background. '
              'You get them for chats you may work on: your own, unassigned ones and collaborations (owners and admins: every chat).'),
        ),
      ]),
    );
  }
}

class WorkspacesScreen extends StatefulWidget {
  const WorkspacesScreen({super.key});
  @override
  State<WorkspacesScreen> createState() => _WorkspacesScreenState();
}

class _WorkspacesScreenState extends State<WorkspacesScreen> {
  late Future<List<WorkspaceSummary>> _f = context.read<Session>().repo.workspaces();
  @override
  Widget build(BuildContext context) {
    final s = context.read<Session>();
    return Scaffold(
      appBar: AppBar(title: const Text('Switch workspace')),
      body: FutureBuilder<List<WorkspaceSummary>>(
        future: _f,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(message: snap.error.toString(), onRetry: () => setState(() => _f = s.repo.workspaces()));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return ListView(children: [
            for (final w in snap.data!)
              ListTile(
                leading: Avatar(name: w.name, colorKey: w.id, size: 40),
                title: Text(w.name),
                subtitle: Row(children: [RolePill(w.role)]),
                trailing: w.id == s.workspaceId ? const Icon(Icons.check_circle, color: Colors.green) : null,
                onTap: w.id == s.workspaceId
                    ? null
                    : () async {
                        final ok = await attempt(context, () => s.switchWorkspace(w.id));
                        if (ok && context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                      },
              ),
          ]);
        },
      ),
    );
  }
}

class SavedRepliesScreen extends StatefulWidget {
  const SavedRepliesScreen({super.key});
  @override
  State<SavedRepliesScreen> createState() => _SavedRepliesScreenState();
}

class _SavedRepliesScreenState extends State<SavedRepliesScreen> {
  late Future<List<QuickReply>> _f = context.read<Session>().repo.quickReplies();
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Saved replies')),
        body: FutureBuilder<List<QuickReply>>(
          future: _f,
          builder: (context, snap) {
            if (snap.hasError) return ErrorRetry(message: snap.error.toString(), onRetry: () => setState(() => _f = context.read<Session>().repo.quickReplies()));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            if (snap.data!.isEmpty) return const EmptyState(icon: Icons.bolt, title: 'No saved replies');
            return ListView.separated(
              itemCount: snap.data!.length,
              separatorBuilder: (_, _) => const Divider(),
              itemBuilder: (_, i) {
                final q = snap.data![i];
                return ListTile(
                  title: Text('/${q.shortcut}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text([q.description ?? '', if (q.category != null) '· ${q.category!.replaceAll('_', ' ')}'].join('\n')),
                );
              },
            );
          },
        ),
      );
}

class LabelsScreen extends StatelessWidget {
  const LabelsScreen({super.key});

  static const palette = ['#25d366', '#0ea5e9', '#6366f1', '#a855f7', '#ec4899', '#ef4444', '#f97316', '#eab308', '#14b8a6', '#64748b'];

  Future<void> _edit(BuildContext context, Label? label) async {
    final s = context.read<Session>();
    final data = context.read<WorkspaceData>();
    final name = TextEditingController(text: label?.name ?? '');
    var color = label?.color ?? palette.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(label == null ? 'New label' : 'Edit label'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in palette)
                GestureDetector(
                  onTap: () => set(() => color = p),
                  child: CircleAvatar(radius: 16, backgroundColor: hexColor(p), child: color.toLowerCase() == p ? const Icon(Icons.check, color: Colors.white, size: 18) : null),
                ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty || !context.mounted) return;
    await attempt(context, () async {
      if (label == null) {
        await s.repo.createLabel(name.text.trim(), color);
      } else {
        await s.repo.updateLabel(label.id, name.text.trim(), color);
      }
      await data.loadLabels();
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = context.watch<WorkspaceData>();
    final s = context.read<Session>();
    return Scaffold(
      appBar: AppBar(title: const Text('Labels')),
      floatingActionButton: s.canManageLabels ? FloatingActionButton(onPressed: () => _edit(context, null), child: const Icon(Icons.add)) : null,
      body: data.labels.isEmpty
          ? const EmptyState(icon: Icons.label_outline, title: 'No labels yet')
          : ListView(children: [
              if (!s.canManageLabels) const ListTile(leading: Icon(Icons.info_outline), subtitle: Text('Only admins, or agents they allow, can create and change labels.')),
              for (final l in data.labels)
                ListTile(
                  leading: Icon(Icons.label, color: hexColor(l.color)),
                  title: Text(l.name),
                  subtitle: Text('${l.conversationCount} chat${l.conversationCount == 1 ? '' : 's'}'),
                  trailing: !s.canManageLabels
                      ? null
                      : PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'edit') return _edit(context, l);
                            if (await confirm(context, 'Delete "${l.name}"?', 'It is removed from every chat.', ok: 'Delete', danger: true) && context.mounted) {
                              await attempt(context, () async {
                                await s.repo.deleteLabel(l.id);
                                await data.loadLabels();
                              });
                            }
                          },
                          itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit')), PopupMenuItem(value: 'delete', child: Text('Delete'))],
                        ),
                ),
            ]),
    );
  }
}
