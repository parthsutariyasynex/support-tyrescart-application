import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../logic/rules.dart';
import '../../models/models.dart';
import '../../state/chat_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Picks one of the account's approved templates (never Meta's sample), then opens the send screen
Future<void> chooseTemplate(BuildContext context, ChatController chat) async {
  final t = await showModalBottomSheet<MessageTemplate>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _TemplateList(),
  );
  if (t == null || !context.mounted) return;
  await Navigator.push(context, MaterialPageRoute(builder: (_) => TemplateSendScreen(chat: chat, template: t)));
}

class _TemplateList extends StatefulWidget {
  const _TemplateList();
  @override
  State<_TemplateList> createState() => _TemplateListState();
}

class _TemplateListState extends State<_TemplateList> {
  late Future<List<MessageTemplate>> _future;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _future = context.read<Session>().repo.approvedTemplates();
  }

  @override
  Widget build(BuildContext context) {
    return SheetBody(
      fraction: 0.85,
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 4), child: Align(alignment: Alignment.centerLeft, child: Text('Templates', style: Theme.of(context).textTheme.titleLarge))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search templates', isDense: true), onChanged: (v) => setState(() => _q = v.toLowerCase())),
        ),
        Expanded(
          child: FutureBuilder<List<MessageTemplate>>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) {
                return ErrorRetry(message: snap.error.toString(), onRetry: () => setState(() => _future = context.read<Session>().repo.approvedTemplates()));
              }
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final list = snap.data!.where((t) => _q.isEmpty || t.name.toLowerCase().contains(_q) || t.body.toLowerCase().contains(_q)).toList();
              if (list.isEmpty) {
                return const EmptyState(icon: Icons.description_outlined, title: 'No approved templates', body: 'Templates approved by Meta for this WhatsApp number show here.');
              }
              return ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(),
                itemBuilder: (_, i) {
                  final t = list[i];
                  return ListTile(
                    enabled: t.sendable,
                    title: Text(t.name.replaceAll('_', ' '), style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.body, maxLines: 3, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text([t.category, t.language, if (!t.sendable) (t.unsupportedReason ?? "Can't be sent from the app")].join(' · '),
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
                    ]),
                    onTap: t.sendable ? () => Navigator.pop(context, t) : null,
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}

class TemplateSendScreen extends StatefulWidget {
  const TemplateSendScreen({super.key, required this.chat, required this.template});
  final ChatController chat;
  final MessageTemplate template;
  @override
  State<TemplateSendScreen> createState() => _TemplateSendScreenState();
}

class _TemplateSendScreenState extends State<TemplateSendScreen> {
  TemplateValues _values = emptyValues();
  final Map<String, TextEditingController> _ctrls = {};
  ({Uint8List bytes, String mime, String name})? _file;
  bool _loading = true;
  bool _sending = false;

  MessageTemplate get t => widget.template;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  /// The customer's first and last name, by the server's rule: what's saved on the contact, else the WhatsApp name
  Future<void> _prefill() async {
    final c = widget.chat.conversation;
    var names = customerNames(name: c?.contact.name);
    try {
      if (c != null) {
        final p = await context.read<Session>().repo.contact(c.contact.id);
        names = customerNames(firstName: p.field('firstName'), lastName: p.field('lastName'), name: p.name);
      }
    } catch (_) {}
    _values = autoFillValues(t, names);
    if (mounted) setState(() => _loading = false);
  }

  TextEditingController _ctrl(String group, String key) => _ctrls.putIfAbsent('$group:$key', () {
        final v = (_values[group]?[key] ?? '').replaceAll(noName, '');
        return TextEditingController(text: v)
          ..addListener(() => setState(() => _values[group]![key] = _ctrls['$group:$key']!.text.isEmpty && nameFor(key) != null && group == 'body' ? noName : _ctrls['$group:$key']!.text));
      });

  Future<void> _pickHeaderFile() async {
    final kind = t.mediaHeader!;
    if (kind == 'IMAGE') {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      setState(() => _file = (bytes: bytes, mime: lookupMimeType(x.name, headerBytes: bytes) ?? 'image/jpeg', name: x.name));
      return;
    }
    final files = await FilePicker.pickFiles(type: kind == 'VIDEO' ? FileType.video : FileType.any);
    if (files.isEmpty) return;
    final f = files.first;
    final bytes = await f.readAsBytes();
    setState(() => _file = (bytes: bytes, mime: lookupMimeType(f.name, headerBytes: bytes) ?? 'application/octet-stream', name: f.name));
  }

  String get _bodyText => readableMessage(t.body, _values['body'] ?? {});

  Future<void> _send() async {
    final missing = missingValues(t, _values, hasFile: _file != null);
    if (missing.isNotEmpty) {
      showMessage(context, 'Fill in ${missing.join(', ')}', error: true);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Send this template?'),
        content: SingleChildScrollView(child: Text(_bodyText)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes, Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // One id per confirmation: if this request is retried, the server returns the first send instead of sending twice
    final rnd = Random.secure();
    final requestId = List.generate(24, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[rnd.nextInt(36)]).join();
    setState(() => _sending = true);
    try {
      await widget.chat.sendTemplate(t, _values, requestId, headerFile: _file);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[];
    if (t.header?.format == 'TEXT') {
      for (final v in t.header!.variables) {
        fields.add(TextField(controller: _ctrl('header', v), decoration: InputDecoration(labelText: 'Header {{$v}}')));
      }
    }
    for (final v in t.bodyVariables) {
      final which = nameFor(v);
      fields.add(TextField(
        controller: _ctrl('body', v),
        decoration: InputDecoration(
          labelText: which == 'first' ? 'First name {{$v}}' : which == 'last' ? 'Last name {{$v}}' : '{{$v}}',
          helperText: which != null ? 'Leave empty if unknown: the name is left out of the message' : null,
        ),
      ));
    }
    for (var i = 0; i < t.buttons.length; i++) {
      final b = t.buttons[i];
      if ((b.type == 'URL' && b.variables.isNotEmpty) || b.type == 'COPY_CODE') {
        fields.add(TextField(controller: _ctrl('buttons', '$i'), decoration: InputDecoration(labelText: b.type == 'COPY_CODE' ? 'Coupon code' : 'Link for "${b.text}"')));
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(t.name.replaceAll('_', ' '))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: context.chat.chatBackground, borderRadius: BorderRadius.circular(10)),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: context.chat.outgoing, borderRadius: BorderRadius.circular(10)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (t.mediaHeader != null)
                        Container(
                          height: 120,
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(6)),
                          alignment: Alignment.center,
                          child: _file != null && _file!.mime.startsWith('image/')
                              ? ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(_file!.bytes, fit: BoxFit.cover, width: double.infinity))
                              : Text(_file?.name ?? 'Header ${t.mediaHeader!.toLowerCase()}'),
                        ),
                      if (t.header?.format == 'TEXT')
                        Text(readableMessage(t.header!.text, _values['header'] ?? {}), style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(_bodyText, style: const TextStyle(fontSize: 15)),
                      if (t.footer != null && t.footer!.isNotEmpty) Text(t.footer!, style: TextStyle(fontSize: 12, color: context.chat.meta)),
                      for (final b in t.buttons)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Center(child: Text(b.text.isEmpty ? (b.type == 'COPY_CODE' ? 'Copy code' : b.type) : b.text, style: TextStyle(color: context.chat.mention, fontWeight: FontWeight.w600))),
                        ),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (t.mediaHeader != null)
                OutlinedButton.icon(
                  onPressed: _pickHeaderFile,
                  icon: const Icon(Icons.attach_file),
                  label: Text(_file == null ? 'Choose the header ${t.mediaHeader!.toLowerCase()}' : 'Change file (${_file!.name})'),
                ),
              for (final f in fields) Padding(padding: const EdgeInsets.only(top: 12), child: f),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _sending ? null : _send,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                icon: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                label: const Text('Send template'),
              ),
            ]),
    );
  }
}
