import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../logic/time.dart';
import '../../models/models.dart';
import '../../state/workspace_data.dart';
import '../widgets/common.dart';

// Owners/admins pages. The server refuses these for other roles (FORBIDDEN); the app only hides them.

class TemplatesAdminScreen extends StatefulWidget {
  const TemplatesAdminScreen({super.key});
  @override
  State<TemplatesAdminScreen> createState() => _TemplatesAdminScreenState();
}

class _TemplatesAdminScreenState extends State<TemplatesAdminScreen> {
  late Future<List<MessageTemplate>> _f = context.read<Session>().repo.allTemplates();

  Color _statusColor(String s) => switch (s) {
        'APPROVED' => Colors.green,
        'PENDING' => Colors.orange,
        'REJECTED' || 'DISABLED' => Colors.red,
        _ => Colors.grey,
      };

  @override
  Widget build(BuildContext context) {
    final s = context.read<Session>();
    return Scaffold(
      appBar: AppBar(title: const Text('Message templates')),
      body: FutureBuilder<List<MessageTemplate>>(
        future: _f,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(message: snap.error.toString(), onRetry: () => setState(() => _f = s.repo.allTemplates()));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          return RefreshIndicator(
            onRefresh: () async => setState(() => _f = s.repo.allTemplates()),
            child: ListView(children: [
              const ListTile(
                leading: Icon(Icons.info_outline),
                subtitle: Text('Templates are reviewed by Meta. Create and edit them on the website (Settings → Message templates); they show here with their review status.'),
              ),
              for (final t in list)
                ListTile(
                  title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.body, maxLines: 3, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Row(children: [
                      Text(t.status, style: TextStyle(color: _statusColor(t.status), fontWeight: FontWeight.w600, fontSize: 12)),
                      Text('  ${t.category} · ${t.language}', style: const TextStyle(fontSize: 12)),
                    ]),
                    if (t.rejectedReason != null && t.rejectedReason != 'NONE') Text('Rejected: ${t.rejectedReason}', style: const TextStyle(fontSize: 12, color: Colors.red)),
                  ]),
                  isThreeLine: true,
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (!await confirm(context, 'Delete ${t.name} (${t.language})?', 'Meta deletes it. A deleted name can only be used again after 30 days.', ok: 'Delete', danger: true)) return;
                      if (!context.mounted) return;
                      final ok = await attempt(context, () => s.repo.deleteTemplate(t.name, t.id), done: 'Template deleted');
                      if (ok) setState(() => _f = s.repo.allTemplates());
                    },
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }
}

class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key});
  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  late Future<List<TeamMember>> _f = context.read<Session>().repo.members();

  void _reload() => setState(() => _f = context.read<Session>().repo.members());

  Future<void> _invite() async {
    final s = context.read<Session>();
    final name = TextEditingController();
    final email = TextEditingController();
    var role = 'agent';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Add a team member'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 10),
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: role,
              decoration: const InputDecoration(labelText: 'Role'),
              items: const [
                DropdownMenuItem(value: 'admin', child: Text('Admin')),
                DropdownMenuItem(value: 'supervisor', child: Text('Supervisor')),
                DropdownMenuItem(value: 'agent', child: Text('Agent')),
              ],
              onChanged: (v) => set(() => role = v ?? 'agent'),
            ),
            const SizedBox(height: 8),
            const Text('A new account gets an email to choose a password.', style: TextStyle(fontSize: 12)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final done = await attempt(context, () async {
      final r = await s.repo.inviteMember({'name': name.text.trim(), 'email': email.text.trim(), 'role': role});
      if (mounted) {
        showMessage(context, r.invited ? (r.emailSent ? 'Invite email sent.' : "Added, but the invite email couldn't be sent. They can use Forgot password.") : 'Added to the workspace.');
      }
    });
    if (done) _reload();
  }

  Future<void> _actions(TeamMember m) async {
    final s = context.read<Session>();
    if (m.isOwner || m.userId == s.userId) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(m.name, style: const TextStyle(fontWeight: FontWeight.w600)), subtitle: Text(m.email)),
          for (final r in const ['admin', 'supervisor', 'agent'])
            if (r != m.role) ListTile(leading: const Icon(Icons.badge_outlined), title: Text('Make ${r[0].toUpperCase()}${r.substring(1)}'), onTap: () => Navigator.pop(ctx, 'role:$r')),
          if (m.role == 'agent' || m.role == 'supervisor')
            SwitchListTile(
              title: const Text('Can manage labels'),
              value: m.canManageLabels,
              onChanged: (v) => Navigator.pop(ctx, 'labels:$v'),
            ),
          ListTile(
            leading: Icon(m.active ? Icons.block : Icons.check_circle_outline),
            title: Text(m.active ? 'Deactivate' : 'Activate'),
            subtitle: m.active ? const Text("They can't sign in here; nothing is deleted.") : null,
            onTap: () => Navigator.pop(ctx, m.active ? 'deactivate' : 'activate'),
          ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    bool ok;
    if (choice.startsWith('role:')) {
      ok = await attempt(context, () => s.repo.updateMemberRole(m.userId, choice.substring(5)), done: 'Role changed');
    } else if (choice.startsWith('labels:')) {
      ok = await attempt(context, () => s.repo.setLabelPermission(m.userId, choice.endsWith('true')));
    } else {
      ok = await attempt(context, () => s.repo.setMemberActive(m.userId, choice == 'activate'));
    }
    if (ok) {
      _reload();
      if (mounted) context.read<WorkspaceData>().loadMembers();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('User management')),
        floatingActionButton: FloatingActionButton(onPressed: _invite, child: const Icon(Icons.person_add_alt_1)),
        body: FutureBuilder<List<TeamMember>>(
          future: _f,
          builder: (context, snap) {
            if (snap.hasError) return ErrorRetry(message: snap.error.toString(), onRetry: _reload);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return ListView(children: [
              for (final m in snap.data!)
                ListTile(
                  leading: MemberAvatar(name: m.name, userId: m.userId, size: 40),
                  title: Text(m.name + (m.isOwner ? ' (owner)' : '')),
                  subtitle: Text('${m.email}${m.status != 'active' ? ' · ${m.status}' : ''}'),
                  trailing: RolePill(m.role),
                  enabled: m.active,
                  onTap: () => _actions(m),
                ),
            ]);
          },
        ),
      );
}

class WorkspacePrefsScreen extends StatefulWidget {
  const WorkspacePrefsScreen({super.key});
  @override
  State<WorkspacePrefsScreen> createState() => _WorkspacePrefsScreenState();
}

class _WorkspacePrefsScreenState extends State<WorkspacePrefsScreen> {
  Map<String, dynamic>? _v;
  String? _error;
  late final _company = TextEditingController(text: context.read<Session>().workspaceName);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await context.read<Session>().repo.workspaceSettings();
      if (mounted) setState(() => _v = v);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _set(String key, int value) async {
    final s = context.read<Session>();
    await attempt(context, () async {
      await s.repo.updateWorkspaceSettings({key: value});
      await _load();
      await s.refreshMe();
    }, done: 'Saved');
  }

  Future<void> _number(String key, String label, {int min = 0, int max = 1000}) async {
    final v = await promptText(context, label, initial: '${_v?[key] ?? ''}');
    final n = int.tryParse(v ?? '');
    if (n == null) return;
    if (n < min || n > max) {
      if (mounted) showMessage(context, 'Enter a number from $min to $max', error: true);
      return;
    }
    await _set(key, n);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<Session>();
    return Scaffold(
      appBar: AppBar(title: const Text('Company and workspace')),
      body: _v == null
          ? (_error != null ? ErrorRetry(message: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator()))
          : ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Expanded(child: TextField(controller: _company, decoration: const InputDecoration(labelText: 'Company name'))),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => attempt(context, () async {
                      await s.repo.renameWorkspace(_company.text.trim());
                      await s.refreshMe();
                    }, done: 'Company name saved'),
                    child: const Text('Save'),
                  ),
                ]),
              ),
              ListTile(title: const Text('Time zone'), subtitle: Text('${_v!['defaultTimeZone']} (the app shows Dubai time)')),
              ListTile(title: const Text('Default country for numbers'), subtitle: Text('${_v!['defaultCountry']}')),
              ListTile(
                title: const Text('Business day starts at'),
                subtitle: Text('${_v!['businessDayStartHour']}:00 (snooze Tomorrow / Monday)'),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _number('businessDayStartHour', 'Hour (0-23)', max: 23),
              ),
              ListTile(
                title: const Text('Reminders for unattended chats'),
                subtitle: Text(_v!['reminderMinutes'] == 0 ? 'Off' : 'Every ${_v!['reminderMinutes']} minutes'),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _number('reminderMinutes', 'Minutes (0 = off)', max: 1440),
              ),
              ListTile(
                title: const Text('Away after'),
                subtitle: Text('${_v!['awayMinutes']} idle minutes'),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _number('awayMinutes', 'Minutes', min: 1, max: 1440),
              ),
              ListTile(
                title: const Text('Keep deleted contacts for'),
                subtitle: Text('${_v!['deletedContactRetentionDays']} days'),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _number('deletedContactRetentionDays', 'Days', min: 1, max: 365),
              ),
            ]),
    );
  }
}

class AutomationsScreen extends StatefulWidget {
  const AutomationsScreen({super.key});
  @override
  State<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends State<AutomationsScreen> {
  Map<String, dynamic>? _v;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await context.read<Session>().repo.automationSettings();
      if (mounted) setState(() => _v = v);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _save(Map<String, dynamic> input) async {
    await attempt(context, () async {
      await context.read<Session>().repo.updateAutomationSettings(input);
      await _load();
    });
  }

  Future<void> _editReply(String key, String title) async {
    final v = await promptText(context, title, initial: '${_v?[key] ?? ''}', maxLines: 6, maxLength: (_v?['replyMaxLength'] as num?)?.toInt());
    if (v != null) await _save({key: v});
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final days = const ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    return Scaffold(
      appBar: AppBar(title: const Text('Simple automations')),
      body: v == null
          ? (_error != null ? ErrorRetry(message: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator()))
          : ListView(children: [
              SwitchListTile(title: const Text('Automations on'), value: v['enabled'] == true, onChanged: (x) => _save({'enabled': x})),
              ListTile(
                title: const Text('Working hours'),
                subtitle: Text(((v['workingHours'] as List?) ?? []).map((d) => '${days[(d['day'] as num).toInt()]} ${d['start']}-${d['end']}').join(', ').ifEmpty('Closed every day')),
              ),
              const Divider(),
              SwitchListTile(title: const Text('Reply during working hours'), value: v['replyInHoursEnabled'] == true, onChanged: (x) => _save({'replyInHoursEnabled': x})),
              ListTile(title: Text('${v['replyInHours']}'.ifEmpty('No text')), trailing: const Icon(Icons.edit_outlined, size: 18), onTap: () => _editReply('replyInHours', 'Reply during working hours')),
              SwitchListTile(title: const Text('Reply outside working hours'), value: v['replyOutHoursEnabled'] == true, onChanged: (x) => _save({'replyOutHoursEnabled': x})),
              ListTile(title: Text('${v['replyOutHours']}'.ifEmpty('No text')), trailing: const Icon(Icons.edit_outlined, size: 18), onTap: () => _editReply('replyOutHours', 'Reply outside working hours')),
              ListTile(
                title: const Text('At most one automatic reply per chat every'),
                subtitle: Text('${v['cooldownHours']} hours'),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () async {
                  final h = int.tryParse(await promptText(context, 'Hours', initial: '${v['cooldownHours']}') ?? '');
                  if (h != null) await _save({'cooldownHours': h});
                },
              ),
              const Divider(),
              SwitchListTile(title: const Text('Assign new chats automatically'), value: v['routingEnabled'] == true, onChanged: (x) => _save({'routingEnabled': x})),
              ListTile(
                title: const Text('How'),
                subtitle: Text(switch (v['routingMode']) { 'specific' => 'One teammate gets every new chat', 'round_robin' => 'Chosen teammates in turn', _ => 'Leave unassigned' }),
              ),
              SwitchListTile(title: const Text('Only teammates who are online'), value: v['routingOnlineOnly'] == true, onChanged: (x) => _save({'routingOnlineOnly': x})),
              const ListTile(leading: Icon(Icons.info_outline), subtitle: Text('Working hours and who gets new chats are set on the website.')),
            ]),
    );
  }
}

extension on String {
  String ifEmpty(String other) => trim().isEmpty ? other : this;
}

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  DateTimeRange? _range;
  late Future<List<Map<String, dynamic>>> _f = _fetch();

  Future<List<Map<String, dynamic>>> _fetch() => context.read<Session>().repo.assignmentReport(
        from: _range == null ? null : dubaiInstant(_range!.start.year, _range!.start.month, _range!.start.day),
        to: _range == null ? null : dubaiInstant(_range!.end.year, _range!.end.month, _range!.end.day).add(const Duration(days: 1)),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Assignment report'), actions: [
          IconButton(
            icon: const Icon(Icons.date_range),
            onPressed: () async {
              final now = DateTime.now();
              final r = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 3), lastDate: now, initialDateRange: _range);
              if (r != null) {
                _range = r;
                setState(() => _f = _fetch());
              }
            },
          ),
        ]),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _f,
          builder: (context, snap) {
            if (snap.hasError) return ErrorRetry(message: snap.error.toString(), onRetry: () => setState(() => _f = _fetch()));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            if (snap.data!.isEmpty) return const EmptyState(icon: Icons.assessment_outlined, title: 'No assignments in this period');
            return ListView.separated(
              itemCount: snap.data!.length,
              separatorBuilder: (_, _) => const Divider(),
              itemBuilder: (_, i) {
                final r = snap.data![i];
                final prev = (r['previousAssignee'] as Map?)?['name'] ?? 'Unassigned';
                final next = (r['newAssignee'] as Map?)?['name'] ?? 'Unassigned';
                final at = DateTime.tryParse('${r['createdAt']}');
                return ListTile(
                  title: Text('${r['contactName'] ?? '+${r['contactWaId']}'}'),
                  subtitle: Text('$prev → $next\nBy ${(r['assignedBy'] as Map?)?['name'] ?? 'System'}${r['reason'] != null ? ' · "${r['reason']}"' : ''}'),
                  isThreeLine: true,
                  trailing: at == null ? null : Text(formatShortDate(at), style: const TextStyle(fontSize: 12)),
                );
              },
            );
          },
        ),
      );
}
