import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/media_cache.dart';
import '../../core/session.dart';
import '../../logic/countries.dart';
import '../../logic/rules.dart';
import '../../logic/time.dart';
import '../../models/models.dart';
import '../../state/workspace_data.dart';
import '../widgets/common.dart';
import '../widgets/media.dart';

/// Contact info (web: the chat's profile panel): profile fields, lifecycle stage, lists, custom properties, notes and
/// files. Every role can view and edit; deleting the contact is for owners and admins.
class ContactScreen extends StatefulWidget {
  const ContactScreen({super.key, required this.contactId, this.conversationId});
  final String contactId;
  final String? conversationId;
  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  ContactProfile? _p;
  List<CustomProperty> _custom = [];
  List<({String id, String name})> _allLists = [];
  List<ContactRemark> _notes = [];
  List<ChatFile> _files = [];
  ({String channel, DateTime? lastOutboundAt, DateTime? lastInboundAt})? _details;
  String? _error;
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _load();
    final rt = context.read<Session>().realtime;
    _subs.addAll([
      rt.on('contact:updated').listen((e) {
        if (e.map['id'] == widget.contactId) _loadProfile();
      }),
      rt.onAny({'contact:lists', 'contact:remarks'}).listen((e) {
        if (e.map['contactId'] == widget.contactId) _load();
      }),
      rt.on('contact:properties').listen((_) => _load()),
    ]);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final p = await context.read<Session>().repo.contact(widget.contactId);
      if (mounted) setState(() => _p = p);
    } catch (_) {}
  }

  Future<void> _load() async {
    final repo = context.read<Session>().repo;
    try {
      final r = await Future.wait([
        repo.contact(widget.contactId),
        repo.customProperties(),
        repo.contactLists(),
        repo.contactRemarks(widget.contactId),
        if (widget.conversationId != null) repo.chatFiles(widget.conversationId!),
        if (widget.conversationId != null) repo.chatDetails(widget.conversationId!),
      ]);
      if (!mounted) return;
      setState(() {
        _p = r[0] as ContactProfile;
        _custom = r[1] as List<CustomProperty>;
        _allLists = r[2] as List<({String id, String name})>;
        _notes = r[3] as List<ContactRemark>;
        if (widget.conversationId != null) {
          _files = r[4] as List<ChatFile>;
          _details = r[5] as ({String channel, DateTime? lastOutboundAt, DateTime? lastInboundAt});
        }
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _update(String field, dynamic value) async {
    await attempt(context, () async {
      final p = await context.read<Session>().repo.updateContact(widget.contactId, {field: value});
      if (mounted) setState(() => _p = p);
    });
  }

  Future<void> _editText(String field, String label) async {
    final v = await promptText(context, label, initial: _p?.field(field) ?? '', allowEmpty: true);
    if (v != null) await _update(field, v);
  }

  Future<void> _choose(String field, String label, List<ContactOption> options) async {
    final current = _p?.field(field);
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
            ListTile(title: const Text('None'), leading: Icon(current == null ? Icons.radio_button_checked : Icons.radio_button_off), onTap: () => Navigator.pop(ctx, '')),
            for (final o in options)
              ListTile(
                leading: Icon(current == o.value ? Icons.radio_button_checked : Icons.radio_button_off, color: o.color != null ? hexColor(o.color) : null),
                title: Text(o.label),
                onTap: () => Navigator.pop(ctx, o.value),
              ),
          ]),
        ),
      ),
    );
    if (v != null) await _update(field, v);
  }

  Future<void> _editCustom(CustomProperty prop) async {
    final repo = context.read<Session>().repo;
    final current = _p?.customValues[prop.id];
    String? value;
    switch (prop.type) {
      case 'boolean':
        value = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(title: const Text('Yes'), onTap: () => Navigator.pop(ctx, 'true')),
              ListTile(title: const Text('No'), onTap: () => Navigator.pop(ctx, 'false')),
              ListTile(title: const Text('Clear'), onTap: () => Navigator.pop(ctx, '')),
            ]),
          ),
        );
      case 'options':
        value = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: ListView(shrinkWrap: true, children: [
              for (final o in prop.options) ListTile(title: Text(o), trailing: o == current ? const Icon(Icons.check) : null, onTap: () => Navigator.pop(ctx, o)),
              ListTile(title: const Text('Clear'), onTap: () => Navigator.pop(ctx, '')),
            ]),
          ),
        );
      case 'date':
        final d = await showDatePicker(context: context, firstDate: DateTime(1900), lastDate: DateTime(2200), initialDate: DateTime.tryParse(current ?? '') ?? DateTime.now());
        if (d != null) value = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      default:
        value = await promptText(context, prop.name, initial: current ?? '', allowEmpty: true, maxLines: prop.type == 'multiline' ? 5 : 1);
    }
    if (value == null || !mounted) return;
    final v = value;
    await attempt(context, () async {
      final p = await repo.setCustomValue(widget.contactId, prop.id, v.isEmpty ? null : v);
      if (mounted) setState(() => _p = p);
    });
  }

  Future<void> _lists() async {
    final repo = context.read<Session>().repo;
    final mine = _p?.lists.map((l) => l.id).toSet() ?? {};
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            const ListTile(title: Text('Contact lists', style: TextStyle(fontWeight: FontWeight.w600))),
            if (_allLists.isEmpty) const ListTile(title: Text('No lists yet')),
            for (final l in _allLists)
              CheckboxListTile(
                value: mine.contains(l.id),
                title: Text(l.name),
                onChanged: (v) async {
                  final ok = await attempt(context, () => repo.setContactList(widget.contactId, l.id, v == true));
                  if (ok) setLocal(() => v == true ? mine.add(l.id) : mine.remove(l.id));
                },
              ),
          ]),
        ),
      ),
    );
    _loadProfile();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final data = context.watch<WorkspaceData>();
    final opts = data.fieldOptions;
    final p = _p;
    if (p == null) {
      return Scaffold(appBar: AppBar(title: const Text('Contact info')), body: _error != null ? ErrorRetry(message: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator()));
    }
    final displayName = [p.field('firstName'), p.field('lastName')].whereType<String>().where((s) => s.isNotEmpty).join(' ');
    final name = displayName.isNotEmpty ? displayName : (p.name ?? '+${p.waId}');
    final phoneCountry = countryByCode(p.field('phoneCountry')) ?? countryOfNumber(p.waId);
    final stage = opts?.stage(p.field('leadStage'));
    String? optionLabel(List<ContactOption>? list, String? v) => v == null ? null : (list?.where((o) => o.value == v).firstOrNull?.label ?? v);
    final cache = context.read<MediaCache>();

    Widget field(String label, String? value, VoidCallback onTap, {IconData? icon}) => ListTile(
          leading: icon != null ? Icon(icon) : null,
          title: Text(label, style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.outline)),
          subtitle: Text(value == null || value.isEmpty ? 'Not set' : value, style: TextStyle(fontSize: 15.5, color: Theme.of(context).colorScheme.onSurface)),
          trailing: const Icon(Icons.edit_outlined, size: 18),
          onTap: onTap,
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Contact info')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: [
          const SizedBox(height: 20),
          Center(child: Avatar(name: name, colorKey: p.id, size: 96)),
          const SizedBox(height: 12),
          Center(child: Text(name, style: Theme.of(context).textTheme.headlineSmall)),
          Center(
            child: GestureDetector(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: '+${p.waId}'));
                showMessage(context, 'Number copied');
              },
              child: Text('${phoneCountry?.flag ?? ''} +${p.waId}', style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 16)),
            ),
          ),
          if (p.name != null && displayName.isNotEmpty) Center(child: Text('WhatsApp name: ${p.name}', style: TextStyle(color: Theme.of(context).colorScheme.outline))),
          if (stage != null) Padding(padding: const EdgeInsets.only(top: 8), child: Center(child: LabelChip(name: stage.label, color: stage.color ?? '#64748b', small: false))),
          const SizedBox(height: 12),
          const Divider(),
          _section('Contact property'),
          field('First name', p.field('firstName'), () => _editText('firstName', 'First name')),
          field('Last name', p.field('lastName'), () => _editText('lastName', 'Last name')),
          field('Email', p.field('email'), () => _editText('email', 'Email')),
          field('Company', p.field('companyName'), () => _editText('companyName', 'Company name')),
          field('Job title', p.field('jobTitle'), () => _editText('jobTitle', 'Job title')),
          field('Lifecycle stage', stage?.label, () => _choose('leadStage', 'Lifecycle stage', opts?.leadStages ?? const [])),
          field('Lead source', optionLabel(opts?.leadSources, p.field('leadSource')), () => _choose('leadSource', 'Lead source', opts?.leadSources ?? const [])),
          field('Priority', optionLabel(opts?.priorities, p.field('priority')), () => _choose('priority', 'Priority', opts?.priorities ?? const [])),
          field('Country', countryByCode(p.field('country'))?.name ?? p.field('country'), () async {
            final c = await showModalBottomSheet<PhoneCountry>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => const _CountryList());
            if (c != null) await _update('country', c.code);
          }),
          SwitchListTile(
            title: const Text('Subscribed'),
            subtitle: const Text('Wants messages from you'),
            value: p.subscribed,
            onChanged: (v) => _update('subscribed', v),
          ),
          ListTile(
            title: Text('Lists', style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.outline)),
            subtitle: p.lists.isEmpty ? const Text('Not in any list') : Wrap(spacing: 6, runSpacing: 4, children: [for (final l in p.lists) Chip(label: Text(l.name), visualDensity: VisualDensity.compact)]),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: _lists,
          ),
          for (final prop in _custom) field(prop.name, _customText(prop, p.customValues[prop.id]), () => _editCustom(prop)),
          if (_details != null) ...[
            const Divider(),
            _section('Chat'),
            ListTile(leading: const Icon(Icons.chat_outlined), title: const Text('Channel'), subtitle: Text(_details!.channel)),
            ListTile(leading: const Icon(Icons.call_received), title: const Text('Customer last wrote'), subtitle: Text(_details!.lastInboundAt == null ? 'Never' : formatDateTime(_details!.lastInboundAt!))),
            ListTile(leading: const Icon(Icons.call_made), title: const Text('Team last wrote'), subtitle: Text(_details!.lastOutboundAt == null ? 'Never' : formatDateTime(_details!.lastOutboundAt!))),
          ],
          if (_files.isNotEmpty) ...[
            const Divider(),
            _section('Media and documents (${_files.length})'),
            SizedBox(
              height: 96,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                for (final f in _files.where((f) => f.available))
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: f.type == 'image' || f.type == 'sticker'
                        ? SizedBox(width: 96, height: 96, child: AuthImage(load: () => cache.message(f.id), maxHeight: 96))
                        : InkWell(
                            onTap: () => openProtectedFile(context, () => cache.messageFile(f.id, f.mediaName ?? '${f.type}-${f.id}.${f.type == 'voice' || f.type == 'audio' ? audioExtension(f.mediaMime) : (documentTypes[f.mediaMime] ?? 'mp4')}')),
                            child: Container(
                              width: 96,
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                Icon(switch (f.type) { 'video' => Icons.movie, 'voice' || 'audio' => Icons.mic, _ => Icons.insert_drive_file }),
                                const SizedBox(height: 4),
                                Text(f.mediaName ?? f.type, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
                              ]),
                            ),
                          ),
                  ),
              ]),
            ),
          ],
          const Divider(),
          _section('Internal notes (${_notes.length})'),
          if (_notes.isEmpty) const ListTile(title: Text('No notes yet. Add one from the chat ("Add note").')),
          for (final n in _notes)
            ListTile(
              leading: const Icon(Icons.sticky_note_2_outlined, color: Color(0xFFB45309)),
              title: Text(n.body.isEmpty ? '${n.files.length} file${n.files.length == 1 ? '' : 's'}' : n.body),
              subtitle: Text('${n.authorName ?? 'Teammate'} · ${formatDateTime(n.createdAt)}'),
            ),
          if (session.isAdmin) ...[
            const Divider(),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('Delete contact', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              subtitle: const Text('The contact and its chat leave the app. Restorable for a while from Settings.'),
              onTap: () async {
                if (!await confirm(context, 'Delete this contact?', 'Their chat leaves the app for everyone. Admins can restore it from Recently deleted contacts.', ok: 'Delete', danger: true)) return;
                if (!context.mounted) return;
                final ok = await attempt(context, () => session.repo.deleteContact(p.id), done: 'Contact deleted');
                if (ok && context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ],
          const SizedBox(height: 32),
        ]),
      ),
    );
  }

  String? _customText(CustomProperty prop, String? v) {
    if (v == null || v.isEmpty) return null;
    if (prop.type == 'boolean') return v == 'true' ? 'Yes' : 'No';
    if (prop.type == 'datetime') {
      final d = DateTime.tryParse(v);
      return d == null ? v : formatDateTime(d);
    }
    return v;
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(t, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
      );
}

class _CountryList extends StatelessWidget {
  const _CountryList();
  @override
  Widget build(BuildContext context) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: ListView(children: [
          for (final c in phoneCountries) ListTile(leading: Text(c.flag, style: const TextStyle(fontSize: 22)), title: Text(c.name), onTap: () => Navigator.pop(context, c)),
        ]),
      );
}
