import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/repo.dart';
import '../../core/session.dart';
import '../../logic/rules.dart';
import '../../logic/time.dart';
import '../../models/models.dart';
import '../../state/chat_controller.dart';
import '../../state/workspace_data.dart';
import '../widgets/common.dart';

/// Assign / reassign / unassign (owners, admins, supervisors). The Assignment Reason is required when assigning or
/// reassigning (the server refuses without it) and optional when unassigning; only the admin report shows it.
class AssignSheet extends StatefulWidget {
  const AssignSheet({super.key, required this.chat});
  final ChatController chat;
  @override
  State<AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends State<AssignSheet> {
  String? _picked; // member id; '' = unassign
  final _reason = TextEditingController();
  bool _busy = false;
  String _q = '';

  Future<void> _save() async {
    final unassign = _picked == '';
    if (!unassign && _reason.text.trim().isEmpty) {
      showMessage(context, 'Add an Assignment Reason', error: true);
      return;
    }
    setState(() => _busy = true);
    final ok = await attempt(context, () => widget.chat.assign(unassign ? null : _picked, reason: _reason.text));
    if (mounted) setState(() => _busy = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final data = context.watch<WorkspaceData>();
    final session = context.read<Session>();
    final current = widget.chat.conversation?.assignee;
    // People: every member of the workspace, by name (members are shown by their assignee entry = member id)
    final people = data.assignees.where((a) => a.userId != null && data.members.any((m) => m.id == a.userId)).toList()..sort((a, b) => a.name.compareTo(b.name));
    final others = data.assignees.where((a) => !(a.userId != null && data.members.any((m) => m.id == a.userId)) && a.conversationCount > 0).toList();
    final q = _q.toLowerCase();
    final list = [...people, ...others].where((a) => q.isEmpty || a.name.toLowerCase().contains(q)).toList();
    final canManage = session.canManageAssignments;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(children: [
              Expanded(child: Text(canManage ? 'Assign chat' : 'Assigned to', style: Theme.of(context).textTheme.titleLarge)),
              if (current != null) Text('Now: ${current.name}', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
            ]),
          ),
          if (!canManage)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text('Only owners, admins and supervisors can assign chats. Agents can take a New Lead with "Assign to me".'),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search people', isDense: true), onChanged: (v) => setState(() => _q = v)),
          ),
          Expanded(
            child: RadioGroup<String>(
              groupValue: canManage ? _picked : current?.id,
              onChanged: (v) {
                if (canManage && v != current?.id) setState(() => _picked = v);
              },
              child: ListView(children: [
                if (canManage && current != null)
                  const RadioListTile<String>(value: '', title: Text('Unassign'), secondary: Icon(Icons.person_off_outlined)),
                for (final a in list)
                  RadioListTile<String>(
                    value: a.id,
                    enabled: canManage && a.id != current?.id,
                    title: Text(a.userId == session.userId ? '${a.name} (you)' : a.name),
                    subtitle: Text('${a.conversationCount} chat${a.conversationCount == 1 ? '' : 's'}'),
                    secondary: MemberAvatar(name: a.name, userId: a.userId),
                  ),
              ]),
            ),
          ),
          if (canManage)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(children: [
                  TextField(
                    controller: _reason,
                    maxLength: 500,
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(labelText: _picked == '' ? 'Reason (optional)' : 'Assignment Reason (required)', isDense: true),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _picked == null || _busy ? null : _save,
                      child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(_picked == '' ? 'Unassign' : 'Assign'),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Labels on this chat (WhatsApp Business style). Creating labels needs label-management permission.
class LabelsSheet extends StatefulWidget {
  const LabelsSheet({super.key, required this.chat});
  final ChatController chat;
  @override
  State<LabelsSheet> createState() => _LabelsSheetState();
}

class _LabelsSheetState extends State<LabelsSheet> {
  final Set<String> _busy = {};

  @override
  Widget build(BuildContext context) {
    final data = context.watch<WorkspaceData>();
    final session = context.read<Session>();
    return ListenableBuilder(
      listenable: widget.chat,
      builder: (context, _) {
        final on = widget.chat.conversation?.labels.map((l) => l.id).toSet() ?? {};
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
              child: Row(children: [
                Expanded(child: Text('Labels', style: Theme.of(context).textTheme.titleLarge)),
                if (session.canManageLabels)
                  TextButton.icon(
                    onPressed: () async {
                      final name = await promptText(context, 'New label', hint: 'Label name', ok: 'Create');
                      if (name == null || !context.mounted) return;
                      await attempt(context, () async {
                        await session.repo.createLabel(name, '#25d366');
                        await data.loadLabels();
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('New'),
                  ),
              ]),
            ),
            Expanded(
              child: data.labels.isEmpty
                  ? const EmptyState(icon: Icons.label_outline, title: 'No labels yet')
                  : ListView(children: [
                      for (final l in data.labels)
                        CheckboxListTile(
                          value: on.contains(l.id),
                          secondary: Icon(Icons.label, color: hexColor(l.color)),
                          title: Text(l.name),
                          subtitle: Text('${l.conversationCount} chat${l.conversationCount == 1 ? '' : 's'}'),
                          onChanged: _busy.contains(l.id)
                              ? null
                              : (v) async {
                                  setState(() => _busy.add(l.id));
                                  await attempt(context, () => widget.chat.setLabel(l.id, v == true));
                                  await data.loadLabels().catchError((_) {}); // its chat count changed
                                  if (mounted) setState(() => _busy.remove(l.id));
                                },
                        ),
                    ]),
            ),
          ]),
        );
      },
    );
  }
}

/// Teammates added to this chat besides the assignee (they get its notifications)
class CollaboratorsSheet extends StatefulWidget {
  const CollaboratorsSheet({super.key, required this.conversationId});
  final String conversationId;
  @override
  State<CollaboratorsSheet> createState() => _CollaboratorsSheetState();
}

class _CollaboratorsSheetState extends State<CollaboratorsSheet> {
  List<WorkspaceMember>? _collabs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await context.read<Session>().repo.collaborators(widget.conversationId);
      if (mounted) setState(() => _collabs = c);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = context.watch<WorkspaceData>();
    final session = context.read<Session>();
    final ids = _collabs?.map((c) => c.id).toSet() ?? {};
    final addable = data.members.where((m) => !ids.contains(m.id)).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Align(alignment: Alignment.centerLeft, child: Text('Collaborators', style: Theme.of(context).textTheme.titleLarge))),
        Expanded(
          child: _error != null
              ? ErrorRetry(message: _error!, onRetry: _load)
              : _collabs == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(children: [
                      if (_collabs!.isEmpty) const ListTile(title: Text('No collaborators yet')),
                      for (final c in _collabs!)
                        ListTile(
                          leading: MemberAvatar(name: c.name, userId: c.id),
                          title: Text(c.id == session.userId ? '${c.name} (you)' : c.name),
                          subtitle: Text(c.email),
                          trailing: IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () async {
                              final ok = await attempt(context, () => session.repo.removeCollaborator(widget.conversationId, c.id),
                                  done: c.id == session.userId ? 'You removed yourself as a collaborator.' : '${c.name} removed as a collaborator.');
                              if (ok) _load();
                            },
                          ),
                        ),
                      if (addable.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('Add', style: TextStyle(fontWeight: FontWeight.w600))),
                      for (final m in addable)
                        ListTile(
                          leading: MemberAvatar(name: m.name, userId: m.id),
                          title: Text(m.name),
                          subtitle: Text(roleLabel(m.role)),
                          trailing: const Icon(Icons.add_circle_outline),
                          onTap: () async {
                            final ok = await attempt(context, () => session.repo.addCollaborators(widget.conversationId, [m.id]), done: '${m.name} added as a collaborator.');
                            if (ok) _load();
                          },
                        ),
                    ]),
        ),
      ]),
    );
  }
}

/// Snooze: hidden until then; back to open at that time or as soon as the customer writes
Future<DateTime?> pickSnooze(BuildContext context, int businessDayStartHour) async {
  final choices = snoozeChoices(DateTime.now(), businessDayStartHour: businessDayStartHour);
  final r = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Snooze until', style: TextStyle(fontWeight: FontWeight.w600))),
        for (final c in choices)
          ListTile(leading: const Icon(Icons.snooze), title: Text(c.label), trailing: Text(snoozedUntilText(c.until)), onTap: () => Navigator.pop(ctx, c.until)),
        ListTile(leading: const Icon(Icons.edit_calendar_outlined), title: const Text('Pick date and time'), onTap: () => Navigator.pop(ctx, 'custom')),
      ]),
    ),
  );
  if (r is DateTime) return r;
  if (r != 'custom' || !context.mounted) return null;
  final now = DateTime.now();
  final day = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 365)), initialDate: now.add(const Duration(days: 1)));
  if (day == null || !context.mounted) return null;
  final time = await showTimePicker(context: context, initialTime: TimeOfDay(hour: businessDayStartHour, minute: 0));
  if (time == null) return null;
  // The picked wall-clock time is Dubai time, like every time in the app
  final at = dubaiInstant(day.year, day.month, day.day, time.hour, time.minute);
  return at.isAfter(DateTime.now()) ? at : null;
}

/// Forward a message to up to 5 chats, as in WhatsApp (each chat's own rules apply: window, closed chats)
class ForwardSheet extends StatefulWidget {
  const ForwardSheet({super.key, required this.message});
  final Message message;
  @override
  State<ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<ForwardSheet> {
  static const max = 5;
  List<Conversation> _chats = [];
  final Set<String> _picked = {};
  bool _loading = true;
  bool _sending = false;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([String q = '']) async {
    setState(() => _loading = true);
    try {
      final page = await context.read<Session>().repo.conversations(ConversationQuery(search: q, status: 'open'));
      if (mounted) setState(() => _chats = page.nodes);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final session = context.read<Session>();
    final m = widget.message;
    final kind = forwardKind(m);
    if (kind == null) return;
    setState(() => _sending = true);
    var sent = 0;
    final errors = <String>[];
    ({Uint8List bytes, String mime})? file;
    for (final id in _picked) {
      try {
        if (kind == 'text') {
          await session.repo.sendText(id, m.body);
        } else {
          final mediaFile = file ??= await session.api.download('/inbox/messages/${Uri.encodeComponent(m.id)}/media');
          final mime = (m.mediaMime ?? mediaFile.mime).split(';').first.trim();
          final bytes = mediaFile.bytes;
          if (kind == 'voice') {
            await session.repo.sendVoice(id, bytes, mime);
          } else {
            final ext = kind == 'image' ? (mime == 'image/png' ? 'png' : 'jpg') : (documentTypes[mime] ?? 'bin');
            await session.repo.sendFile(id,
                bytes: bytes,
                mime: mime,
                image: kind == 'image',
                name: m.mediaName ?? '${kind == 'image' ? 'photo' : 'document'}.$ext',
                caption: isMediaPlaceholder(m.body) ? '' : m.body);
          }
        }
        sent++;
      } catch (e) {
        final c = _chats.where((c) => c.id == id).firstOrNull;
        errors.add('${c?.contact.display ?? 'A chat'}: $e');
      }
    }
    if (!mounted) return;
    setState(() => _sending = false);
    Navigator.pop(context);
    showMessage(context, errors.isEmpty ? 'Forwarded to $sent chat${sent == 1 ? '' : 's'}.' : 'Forwarded to $sent. ${errors.join(' · ')}', error: errors.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    return SheetBody(
      fraction: 0.85,
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 4), child: Align(alignment: Alignment.centerLeft, child: Text('Forward to…', style: Theme.of(context).textTheme.titleLarge))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search chats', isDense: true),
            onChanged: (v) {
              _q = v;
              Future.delayed(const Duration(milliseconds: 350), () {
                if (_q == v && mounted) _load(v);
              });
            },
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(children: [
                  for (final c in _chats.where((c) => c.id != widget.message.conversationId))
                    Builder(builder: (context) {
                      final blocked = forwardBlocked(c);
                      return CheckboxListTile(
                        value: _picked.contains(c.id),
                        onChanged: blocked.isNotEmpty || (!_picked.contains(c.id) && _picked.length >= max)
                            ? null
                            : (v) => setState(() => v == true ? _picked.add(c.id) : _picked.remove(c.id)),
                        secondary: Avatar(name: c.contact.display, colorKey: c.contact.id, size: 38),
                        title: Text(c.contact.display),
                        subtitle: Text(blocked.isNotEmpty ? blocked : '+${c.contact.waId}'),
                      );
                    }),
                ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _picked.isEmpty || _sending ? null : _send,
                icon: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                label: Text('Forward${_picked.isEmpty ? '' : ' (${_picked.length})'}'),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
