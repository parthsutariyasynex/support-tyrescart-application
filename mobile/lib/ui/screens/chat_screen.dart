import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../logic/rules.dart';
import '../../logic/time.dart';
import '../../models/models.dart';
import '../../state/alerts.dart';
import '../../state/chat_controller.dart';
import '../../state/workspace_data.dart';
import '../theme.dart';
import '../widgets/bubbles.dart';
import '../widgets/common.dart';
import 'chat_sheets.dart';
import 'contact_screen.dart';
import 'template_sheet.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversationId, this.initial});
  final String conversationId;
  final Conversation? initial;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// A file picked for a note (uploaded when the note is saved)
class _NoteFile {
  _NoteFile(this.name, this.mime, this.bytes);
  final String name;
  final String mime;
  final Uint8List bytes;
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController chat;
  late final Alerts _alerts;
  final _scroll = ScrollController();

  // The list is reversed (offset 0 = the newest message at the bottom). Reading older messages, the view stays put
  // when new ones arrive; they're counted on the "jump to the latest" button instead.
  bool _awayFromBottom = false;
  int _newBelow = 0;
  String? _newestKey;
  final _text = TextEditingController();
  final _focus = FocusNode();
  final Map<String, GlobalKey> _keys = {};

  bool _noteMode = false;
  Message? _replyTo;
  Message? _editing;
  ContactRemark? _editingNote;
  String? _highlight;
  bool _busy = false;
  final List<_NoteFile> _noteFiles = [];
  final Map<String, String> _pickedMentions = {}; // user id → name

  // Suggestions above the composer: quick replies after "/", teammates after "@" (notes)
  List<QuickReply> _quick = [];
  List<WorkspaceMember> _mentionChoices = [];
  Timer? _quickTimer;

  // Search in conversation
  bool _searchOpen = false;
  final _searchCtrl = TextEditingController();
  List<String> _matches = [];
  int _matchIndex = -1;

  // Voice recording
  final _recorder = AudioRecorder();
  bool _recording = false;
  DateTime? _recordStart;
  Timer? _recordTick;

  @override
  void initState() {
    super.initState();
    chat = ChatController(context.read<Session>(), widget.conversationId);
    if (widget.initial != null) chat.conversation = widget.initial;
    chat.load();
    _alerts = context.read<Alerts>();
    _alerts.openConversationId = widget.conversationId;
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) chat.loadOlder();
      final away = _scroll.position.pixels > 300;
      if (away != _awayFromBottom || (!away && _newBelow > 0)) {
        setState(() {
          _awayFromBottom = away;
          if (!away) _newBelow = 0;
        });
      }
    });
    chat.addListener(_onChatChanged);
    _text.addListener(_onTextChanged);
  }

  /// The list key of a row (also used by findChildIndexCallback in _list)
  static String _rowKey(ChatItem item) => switch (item) {
    MessageItem(:final message) => 'm:${message.id}',
    NoteItem(:final note) => 'n:${note.id}',
    ActivityItem(:final activity) => 'a:${activity.id}',
  };

  /// A new newest row (message, note, event, a send on its way): at (or near) the bottom it simply shows; while older
  /// messages are being read the view stays where it is and new customer messages are counted on the button
  void _onChatChanged() {
    final items = chat.items;
    final newestKey = chat.pending.isNotEmpty ? 'p:${chat.pending.last.localId}' : (items.isEmpty ? null : _rowKey(items.last));
    if (newestKey == null || newestKey == _newestKey) return;
    final first = _newestKey == null;
    _newestKey = newestKey;
    if (first || !_scroll.hasClients) return;
    if (_scroll.offset > 300) {
      final last = items.last;
      if (last is MessageItem && !last.message.isOut) setState(() => _newBelow++);
      _keepReadingPosition();
    } else if (_scroll.offset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
    }
  }

  /// The list is reversed, so a row added at the bottom pushes everything above it up. Note where a message on screen
  /// is now, and once the new row is laid out move the list back by exactly that much.
  void _keepReadingPosition() {
    final height = MediaQuery.sizeOf(context).height;
    GlobalKey? anchor;
    double before = 0;
    for (final k in _keys.values) {
      final box = k.currentContext?.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) {
        final dy = box.localToGlobal(Offset.zero).dy;
        if (dy > 0 && dy < height) {
          anchor = k;
          before = dy;
          break;
        }
      }
    }
    if (anchor == null) return;
    final key = anchor;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !_scroll.hasClients) return;
      final moved = before - box.localToGlobal(Offset.zero).dy;
      if (moved.abs() > 0.5) _scroll.jumpTo(_scroll.offset + moved);
    });
  }

  /// Back to the newest message (after sending, or from the button)
  void _toBottom() {
    if (!_scroll.hasClients) return;
    if (_scroll.offset > 2000) _scroll.jumpTo(600); // a long way up: don't animate through the whole history
    _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    if (_newBelow > 0) setState(() => _newBelow = 0);
  }

  @override
  void dispose() {
    chat.removeListener(_onChatChanged);
    if (_alerts.openConversationId == widget.conversationId) _alerts.openConversationId = null;
    chat.dispose();
    _scroll.dispose();
    _text.dispose();
    _focus.dispose();
    _quickTimer?.cancel();
    _recordTick?.cancel();
    _searchCtrl.dispose();
    _recorder.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- Composer text

  void _onTextChanged() {
    final text = _text.text;
    if (!_noteMode && _editing == null) chat.typed(text);
    // "/" at the start: quick replies (web: typing / in the message box)
    if (!_noteMode && _editing == null && text.startsWith('/') && !text.contains('\n')) {
      final q = text.substring(1);
      _quickTimer?.cancel();
      _quickTimer = Timer(const Duration(milliseconds: 200), () async {
        try {
          final list = await context.read<Session>().repo.quickReplies(q);
          if (mounted && _text.text.startsWith('/')) setState(() => _quick = list);
        } catch (_) {}
      });
    } else if (_quick.isNotEmpty) {
      setState(() => _quick = []);
    }
    // "@" in a note: teammates by name or email
    if (_noteMode) {
      final at = mentionAt(text, _text.selection.baseOffset < 0 ? text.length : _text.selection.baseOffset);
      final members = context.read<WorkspaceData>().members.where((m) => m.id != context.read<Session>().userId).toList();
      final next = at == null ? <WorkspaceMember>[] : matchMembers(members, at.query, (m) => m.name, (m) => m.email).take(6).toList();
      if (next.length != _mentionChoices.length || !next.every(_mentionChoices.contains)) setState(() => _mentionChoices = next);
    } else if (_mentionChoices.isNotEmpty) {
      setState(() => _mentionChoices = []);
    }
    setState(() {}); // send/mic button and counter
  }

  void _pickMention(WorkspaceMember m) {
    final caret = _text.selection.baseOffset < 0 ? _text.text.length : _text.selection.baseOffset;
    final at = mentionAt(_text.text, caret);
    if (at == null) return;
    final r = insertMention(_text.text, at, m.name);
    _pickedMentions[m.id] = m.name;
    _text.value = TextEditingValue(
      text: r.text,
      selection: TextSelection.collapsed(offset: r.caret),
    );
    setState(() => _mentionChoices = []);
  }

  void _pickQuick(QuickReply q) {
    final text = q.description ?? q.shortcut;
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _quick = []);
  }

  int get _limit => _noteMode || _editingNote != null ? (context.read<WorkspaceData>().fieldOptions?.remarkMaxLength ?? 16000) : whatsappTextMax;

  // ---------------------------------------------------------------- Sending

  Future<void> _submit() async {
    final text = _text.text.trim();
    if (text.length > _limit) {
      showMessage(context, tooLongText(text.length, _limit), error: true);
      return;
    }
    if (_editing != null) return _saveEdit(text);
    if (_editingNote != null) return _saveNoteEdit(text);
    if (_noteMode) return _saveNote(text);
    if (text.isEmpty) return;
    final reply = _replyTo;
    _text.clear();
    setState(() => _replyTo = null);
    chat.stopTyping();
    try {
      _toBottom();
      await chat.sendText(text, replyTo: reply);
    } catch (e) {
      if (!mounted) return;
      if (isWindowClosedError(e)) {
        _text.text = text; // nothing is lost: the text stays for after a template
        showMessage(context, '24-hour window closed. Send an approved template instead.', error: true);
      } else if (e is ApiException && e.code == 'NOT_ASSIGNED') {
        showError(context, e);
      }
    }
  }

  Future<void> _saveNote(String text) async {
    if (text.isEmpty && _noteFiles.isEmpty) return;
    final c = chat.conversation;
    if (c == null) return;
    setState(() => _busy = true);
    try {
      final repo = context.read<Session>().repo;
      final ids = <String>[];
      for (final f in _noteFiles) {
        ids.add((await repo.uploadRemarkFile(c.contact.id, f.bytes, f.mime, f.name)).id);
      }
      _toBottom();
      await chat.addNote(text, mentions: mentionedIds(text, _pickedMentions), files: ids);
      _text.clear();
      _noteFiles.clear();
      _pickedMentions.clear();
      if (mounted) setState(() => _noteMode = false);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveEdit(String text) async {
    final m = _editing!;
    if (text.isEmpty) return;
    setState(() => _busy = true);
    final ok = await attempt(context, () => chat.edit(m, text));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) _cancelEdit();
  }

  Future<void> _saveNoteEdit(String text) async {
    final n = _editingNote!;
    if (text.isEmpty && n.files.isEmpty) return;
    setState(() => _busy = true);
    final ok = await attempt(context, () => chat.editNote(n, text));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) _cancelEdit();
  }

  void _cancelEdit() {
    setState(() {
      _editing = null;
      _editingNote = null;
    });
    _text.clear();
  }

  // ---------------------------------------------------------------- Attachments

  Future<void> _attach() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.photo_camera)),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.photo)),
              title: const Text('Photo'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.insert_drive_file)),
              title: const Text('Document'),
              onTap: () => Navigator.pop(ctx, 'document'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    String name;
    Uint8List bytes;
    String? reported;
    if (choice == 'document') {
      final files = await FilePicker.pickFiles(
        type: _noteMode ? FileType.any : FileType.custom,
        allowedExtensions: _noteMode ? null : ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'jpg', 'jpeg', 'png'],
      );
      if (files.isEmpty) return;
      name = files.first.name;
      bytes = await files.first.readAsBytes();
    } else {
      final x = await ImagePicker().pickImage(source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery, imageQuality: 85, maxWidth: 2560);
      if (x == null) return;
      bytes = await x.readAsBytes();
      name = x.name;
      reported = lookupMimeType(x.name, headerBytes: bytes);
      // The camera may give HEIC on iPhones; WhatsApp takes JPEG/PNG only (image_picker re-encodes with imageQuality)
      if (reported != null && !imageTypes.contains(reported) && reported.startsWith('image/')) reported = 'image/jpeg';
    }
    if (!mounted) return;
    reported ??= lookupMimeType(name, headerBytes: bytes);

    if (_noteMode) {
      if (_noteFiles.length >= noteFilesMax) {
        showMessage(context, 'Up to $noteFilesMax files per note', error: true);
        return;
      }
      setState(() => _noteFiles.add(_NoteFile(name, reported ?? 'application/octet-stream', bytes)));
      return;
    }

    final check = checkFile(name, reported, bytes.length);
    if (check is FileProblem) {
      showMessage(context, check.message, error: true);
      return;
    }
    final ok = check as FileOk;
    final caption = await _askCaption(name, ok.image ? bytes : null);
    if (caption == null || !mounted) return;
    final reply = _replyTo;
    setState(() => _replyTo = null);
    try {
      _toBottom();
      await chat.sendFile(bytes: bytes, mime: ok.mime, image: ok.image, name: name, caption: caption, replyTo: reply);
    } catch (e) {
      if (mounted && isWindowClosedError(e)) showMessage(context, '24-hour window closed. Send an approved template instead.', error: true);
    }
  }

  Future<String?> _askCaption(String name, Uint8List? image) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(image != null ? 'Send photo' : 'Send document'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (image != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(image, height: 200, fit: BoxFit.cover),
              ),
            if (image == null) ListTile(leading: const Icon(Icons.insert_drive_file), title: Text(name)),
            TextField(
              controller: ctrl,
              maxLength: captionMax,
              decoration: const InputDecoration(hintText: 'Add a caption'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Send')),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- Voice notes

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      if (mounted) showMessage(context, 'Allow the microphone to record voice messages.', error: true);
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
    // AAC in an MP4 (.m4a) file: the server accepts it (audio/mp4) and WhatsApp delivers it as audio
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1), path: path);
    HapticFeedback.mediumImpact();
    setState(() {
      _recording = true;
      _recordStart = DateTime.now();
    });
    _recordTick = Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {}));
  }

  Future<void> _stopRecording({required bool send}) async {
    _recordTick?.cancel();
    final path = await _recorder.stop();
    final started = _recordStart;
    setState(() => _recording = false);
    if (!send || path == null) return;
    if (started != null && DateTime.now().difference(started) < const Duration(milliseconds: 800)) {
      if (mounted) showMessage(context, 'Hold to record, release to send.');
      return;
    }
    final bytes = await File(path).readAsBytes();
    if (bytes.length > voiceMaxBytes) {
      if (mounted) showMessage(context, 'Voice messages can be up to 16 MB', error: true);
      return;
    }
    final reply = _replyTo;
    setState(() => _replyTo = null);
    try {
      _toBottom();
      await chat.sendVoice(bytes, 'audio/mp4', replyTo: reply);
    } catch (e) {
      if (mounted && isWindowClosedError(e)) showMessage(context, '24-hour window closed. Send an approved template instead.', error: true);
    }
  }

  // ---------------------------------------------------------------- Message and note actions

  Future<void> _messageActions(Message m) async {
    final session = context.read<Session>();
    final actions = messageActions(m, userId: session.userId, isAdmin: session.isAdmin, canReply: chat.canReply && chat.isWindowOpen && !chat.isClosed);
    if (actions.isEmpty) return;
    HapticFeedback.selectionClick();
    final choice = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (actions.contains(MessageAction.react))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in const ['👍', '❤️', '😂', '😮', '😢', '🙏'])
                      InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => Navigator.pop(ctx, 'react:$e'),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(shape: BoxShape.circle, color: m.teamReaction == e ? Theme.of(ctx).colorScheme.primaryContainer : null),
                          child: Text(e, style: const TextStyle(fontSize: 28)),
                        ),
                      ),
                    IconButton(onPressed: () => Navigator.pop(ctx, 'react:+'), icon: const Icon(Icons.add_reaction_outlined)),
                  ],
                ),
              ),
            if (actions.contains(MessageAction.reply))
              ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () => Navigator.pop(ctx, MessageAction.reply)),
            if (actions.contains(MessageAction.copy))
              ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () => Navigator.pop(ctx, MessageAction.copy)),
            if (actions.contains(MessageAction.forward))
              ListTile(leading: const Icon(Icons.forward), title: const Text('Forward'), onTap: () => Navigator.pop(ctx, MessageAction.forward)),
            if (actions.contains(MessageAction.edit))
              ListTile(leading: const Icon(Icons.edit), title: const Text('Edit'), onTap: () => Navigator.pop(ctx, MessageAction.edit)),
            if (actions.contains(MessageAction.info))
              ListTile(leading: const Icon(Icons.info_outline), title: const Text('Info'), onTap: () => Navigator.pop(ctx, MessageAction.info)),
            if (actions.contains(MessageAction.delete))
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                title: Text('Delete for everyone', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                onTap: () => Navigator.pop(ctx, MessageAction.delete),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice is String && choice.startsWith('react:')) {
      var emoji = choice.substring(6);
      if (emoji == '+') {
        final picked = await promptText(context, 'React with any emoji', hint: 'Type or pick an emoji on the keyboard', ok: 'React');
        if (picked == null || picked.isEmpty || !mounted) return;
        emoji = picked.characters.first;
      }
      await attempt(context, () => chat.react(m, m.teamReaction == emoji ? null : emoji));
      return;
    }
    switch (choice) {
      case MessageAction.reply:
        setState(() {
          _replyTo = m;
          _noteMode = false;
        });
        _focus.requestFocus();
      case MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: m.body));
        if (mounted) showMessage(context, 'Copied', duration: const Duration(milliseconds: 1200));
      case MessageAction.forward:
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => ForwardSheet(message: m),
        );
      case MessageAction.edit:
        setState(() {
          _editing = m;
          _editingNote = null;
          _noteMode = false;
          _replyTo = null;
        });
        _text.value = TextEditingValue(
          text: m.body,
          selection: TextSelection.collapsed(offset: m.body.length),
        );
        _focus.requestFocus();
      case MessageAction.info:
        _showInfo(m);
      case MessageAction.delete:
        if (!await confirm(
          context,
          'Delete for everyone?',
          "It's removed for your team in this app. The customer's WhatsApp keeps what it received.",
          ok: 'Delete',
          danger: true,
        )) {
          return;
        }
        try {
          final deleted = await chat.delete(m);
          if (!mounted) return;
          showMessage(
            context,
            'Message deleted',
            action: SnackBarAction(label: 'Undo', onPressed: () => chat.restore(deleted).catchError((e) => mounted ? showError(context, e) : null)),
          );
        } catch (e) {
          if (mounted) showError(context, e);
        }
    }
  }

  void _showInfo(Message m) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.schedule), title: const Text('Sent'), subtitle: Text(formatDateTime(m.createdAt))),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Sent by'),
              subtitle: Text(m.senderName ?? (m.automation != null ? 'Simple automations' : 'Team')),
            ),
            ListTile(
              leading: const Icon(Icons.done_all),
              title: const Text('Status'),
              subtitle: Text(switch (m.status) {
                'pending' => 'Sending…',
                'sent' => 'Sent to WhatsApp',
                'delivered' => "Delivered to the customer's phone",
                'read' => 'Read by the customer',
                'failed' => 'Not delivered${m.error != null ? ': ${m.error}' : ''}',
                _ => m.status,
              }),
            ),
            if (m.editedAt != null) ListTile(leading: const Icon(Icons.edit), title: const Text('Edited'), subtitle: Text(formatDateTime(m.editedAt!))),
          ],
        ),
      ),
    );
  }

  Future<void> _noteActions(ContactRemark n) async {
    final session = context.read<Session>();
    final mine = n.createdById == session.userId || session.isAdmin;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (n.body.isNotEmpty) ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () => Navigator.pop(ctx, 'copy')),
            if (mine) ListTile(leading: const Icon(Icons.edit), title: const Text('Edit note'), onTap: () => Navigator.pop(ctx, 'edit')),
            if (mine)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                title: Text('Delete note', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: n.body));
      case 'edit':
        setState(() {
          _editingNote = n;
          _editing = null;
          _noteMode = true;
          _replyTo = null;
        });
        _text.value = TextEditingValue(
          text: n.body,
          selection: TextSelection.collapsed(offset: n.body.length),
        );
        _focus.requestFocus();
      case 'delete':
        if (await confirm(context, 'Delete this note?', 'Its files and mentions are removed too.', ok: 'Delete', danger: true)) {
          if (mounted) await attempt(context, () => chat.deleteNote(n), done: 'Note deleted');
        }
    }
  }

  void _jumpTo(String messageId) {
    final key = _keys[messageId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(key!.currentContext!, alignment: 0.5, duration: const Duration(milliseconds: 300));
      setState(() => _highlight = messageId);
      Future.delayed(const Duration(seconds: 2), () => mounted ? setState(() => _highlight = null) : null);
    } else if (chat.hasOlder) {
      chat.loadOlder().then((_) => WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(messageId)));
    } else {
      showMessage(context, 'The original message is no longer in this chat.');
    }
  }

  // ---------------------------------------------------------------- Search in conversation

  void _search(String q) {
    final matches = findMessageMatches(chat.messages, q);
    setState(() {
      _matches = matches;
      _matchIndex = matches.isEmpty ? -1 : matches.length - 1; // newest first, like WhatsApp
    });
    if (_matchIndex >= 0) _jumpTo(_matches[_matchIndex]);
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    setState(() => _matchIndex = (_matchIndex + delta).clamp(0, _matches.length - 1));
    _jumpTo(_matches[_matchIndex]);
  }

  void _closeSearch() => setState(() {
    _searchOpen = false;
    _searchCtrl.clear();
    _matches = [];
    _matchIndex = -1;
  });

  PreferredSizeWidget _searchBar() {
    final fg = Theme.of(context).appBarTheme.foregroundColor;
    return AppBar(
      leading: IconButton(tooltip: 'Close search', icon: const Icon(Icons.arrow_back), onPressed: _closeSearch),
      title: TextField(
        key: const Key('chat-search'),
        controller: _searchCtrl,
        autofocus: true,
        onChanged: _search,
        style: TextStyle(color: fg),
        cursorColor: fg,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: 'Search in this chat',
          hintStyle: TextStyle(color: fg?.withValues(alpha: 0.7)),
        ),
      ),
      actions: [
        if (_searchCtrl.text.trim().isNotEmpty)
          Center(child: Text(_matches.isEmpty ? 'No results' : '${_matchIndex + 1}/${_matches.length}', style: const TextStyle(fontSize: 13))),
        IconButton(tooltip: 'Older match', onPressed: _matchIndex > 0 ? () => _step(-1) : null, icon: const Icon(Icons.keyboard_arrow_up)),
        IconButton(
          tooltip: 'Newer match',
          onPressed: _matchIndex >= 0 && _matchIndex < _matches.length - 1 ? () => _step(1) : null,
          icon: const Icon(Icons.keyboard_arrow_down),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- Chat menu

  Future<void> _menu(String action) async {
    final session = context.read<Session>();
    final c = chat.conversation;
    if (c == null) return;
    switch (action) {
      case 'contact':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ContactScreen(contactId: c.contact.id, conversationId: c.id),
          ),
        );
      case 'assign':
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => AssignSheet(chat: chat),
        );
      case 'claim':
        await attempt(context, chat.claim, done: 'You took this chat. It is now in your My chats.');
      case 'labels':
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => LabelsSheet(chat: chat),
        );
      case 'collaborators':
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => CollaboratorsSheet(conversationId: c.id),
        );
      case 'snooze':
        final until = await pickSnooze(context, session.businessDayStartHour);
        if (until != null && mounted) await attempt(context, () => chat.snooze(until), done: 'Snoozed until ${snoozedUntilText(until)}');
      case 'close':
        await attempt(context, () => chat.setClosed(true), done: 'Chat closed.');
      case 'reopen':
        await attempt(context, () => chat.setClosed(false), done: 'Chat reopened.');
      case 'pin':
        await attempt(context, () => chat.setPinned(!c.pinned), done: c.pinned ? 'Chat unpinned.' : 'Chat pinned to the top of your list.');
      case 'unread':
        if (await attempt(context, chat.markUnread) && mounted) Navigator.pop(context);
      case 'clear':
        if (await confirm(
          context,
          'Clear this chat?',
          'Hides everything so far from your own view. Nothing is deleted and your teammates still see it all.',
          ok: 'Clear',
        )) {
          if (mounted) await attempt(context, chat.clear);
        }
      case 'template':
        await chooseTemplate(context, chat);
        _toBottom();
      case 'search':
        setState(() => _searchOpen = true);
    }
  }

  // ---------------------------------------------------------------- Build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        final c = chat.conversation;
        final session = context.watch<Session>();
        final data = context.watch<WorkspaceData>();
        if (chat.gone) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(icon: Icons.delete_outline, title: 'This chat is no longer available', body: 'Its contact was deleted.'),
          );
        }
        return Scaffold(
          backgroundColor: context.chat.chatBackground,
          appBar: _searchOpen ? _searchBar() : _appBar(c, session),
          body: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _list(data)),
                    if (_awayFromBottom)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: Badge(
                          isLabelVisible: _newBelow > 0,
                          label: Text('$_newBelow'),
                          backgroundColor: context.chat.unreadBadge,
                          child: FloatingActionButton.small(
                            heroTag: null,
                            tooltip: 'Latest messages',
                            onPressed: _toBottom,
                            child: const Icon(Icons.keyboard_double_arrow_down),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _banners(c, session),
              // Suggestions give way (shrink) before anything overflows with the keyboard open
              if (_quick.isNotEmpty) Flexible(child: _suggestions()),
              if (_mentionChoices.isNotEmpty) Flexible(child: _mentions()),
              _composer(c),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _appBar(Conversation? c, Session session) {
    final name = c?.contact.display ?? '';
    String subtitle;
    if (chat.typingName != null) {
      subtitle = '${chat.typingName} is typing…';
    } else if (c == null) {
      subtitle = '';
    } else {
      final parts = <String>[
        if (c.assignee != null) 'Assigned to ${c.assignee!.userId == session.userId ? 'you' : c.assignee!.name}' else 'Unassigned',
        if (c.status == 'closed') 'Closed',
        if (c.status == 'snoozed') 'Snoozed until ${snoozedUntilText(c.snoozedUntil)}',
      ];
      subtitle = parts.join(' · ');
    }
    final left = timeUntilClose(c?.lastInboundAt);
    return AppBar(
      titleSpacing: 0,
      title: InkWell(
        onTap: c == null ? null : () => _menu('contact'),
        child: Row(
          children: [
            if (c != null) Avatar(name: name, colorKey: c.contact.id, size: 38),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.normal),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (c != null && !chat.windowClosedByServer && left != null)
          Center(
            child: Tooltip(
              message: '24-hour window: free replies for ${left.inHours} h ${left.inMinutes % 60} min more',
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text('${left.inHours}h', style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
        IconButton(tooltip: 'Template', icon: const Icon(Icons.description_outlined), onPressed: c == null || !chat.canReply ? null : () => _menu('template')),
        PopupMenuButton<String>(
          onSelected: _menu,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'contact', child: Text('Contact info')),
            const PopupMenuItem(value: 'search', child: Text('Search in chat')),
            if (c?.assignee == null) const PopupMenuItem(value: 'claim', child: Text('Assign to me')),
            PopupMenuItem(value: 'assign', child: Text(session.canManageAssignments ? 'Assign…' : 'Assigned to…')),
            const PopupMenuItem(value: 'labels', child: Text('Labels')),
            const PopupMenuItem(value: 'collaborators', child: Text('Collaborators')),
            if (c?.status != 'snoozed') const PopupMenuItem(value: 'snooze', child: Text('Snooze…')),
            if (c?.status != 'closed') const PopupMenuItem(value: 'close', child: Text('Close chat')),
            if (c?.status != 'open') const PopupMenuItem(value: 'reopen', child: Text('Reopen chat')),
            PopupMenuItem(value: 'pin', child: Text(c?.pinned == true ? 'Unpin chat' : 'Pin chat')),
            const PopupMenuItem(value: 'unread', child: Text('Mark as unread')),
            const PopupMenuItem(value: 'clear', child: Text('Clear chat')),
          ],
        ),
      ],
    );
  }

  Widget _list(WorkspaceData data) {
    if (chat.loading && chat.messages.isEmpty) return const Center(child: CircularProgressIndicator());
    if (chat.error != null && chat.messages.isEmpty) return ErrorRetry(message: chat.error!, onRetry: chat.load);
    final items = chat.items;
    final names = data.members.map((m) => m.name).toList();
    // Newest at the bottom: the list is reversed, so index 0 is the newest row
    // Every row has a stable key (findChildIndexCallback below): a row added at the bottom keeps the others where they
    // are instead of shifting each slot's content, so reading older messages isn't disturbed
    final rows = <Widget>[];
    void add(String key, Widget w) => rows.add(KeyedSubtree(key: ValueKey(key), child: w));
    for (final p in chat.pending.reversed) {
      add('p:${p.localId}', PendingBubble(pending: p, onRemove: () => chat.dismissPending(p)));
    }
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      add(_rowKey(item), switch (item) {
        MessageItem(:final message) => KeyedSubtree(
          key: _keys.putIfAbsent(message.id, GlobalKey.new),
          child: MessageBubble(
            message: message,
            highlighted: _highlight == message.id || (_matchIndex >= 0 && _matches[_matchIndex] == message.id),
            searchTerm: _searchOpen ? _searchCtrl.text : null,
            onLongPress: () => _messageActions(message),
            onQuoteTap: message.replyTo == null ? null : () => _jumpTo(message.replyTo!.id),
          ),
        ),
        NoteItem(:final note) => NoteBubble(note: note, memberNames: names, onLongPress: () => _noteActions(note)),
        ActivityItem(:final activity) => SystemPill(activityText(activity, context.read<Session>().userId), icon: Icons.info_outline),
      });
      final prev = i > 0 ? items[i - 1] : null;
      if (prev == null || dayKey(prev.at) != dayKey(item.at)) add('day:${dayKey(item.at)}', SystemPill(dayLabel(item.at)));
    }
    if (chat.loadingOlder) {
      add(
        'loading-older',
        const Padding(
          padding: EdgeInsets.all(12),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (!chat.hasOlder && items.isNotEmpty) {
      add('intro', const SystemPill('Messages are sent through WhatsApp. Internal notes are only seen by your team.', icon: Icons.lock_outline));
    }
    if (rows.isEmpty) return const EmptyState(icon: Icons.chat_bubble_outline, title: 'No messages yet');
    final index = {for (var i = 0; i < rows.length; i++) rows[i].key!: i};
    // (a short chat that fits doesn't stretch when dragged: the app's FitScrollBehavior)
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      itemBuilder: (_, i) => rows[i],
      findChildIndexCallback: (key) => index[key],
    );
  }

  Widget _banners(Conversation? c, Session session) {
    if (c == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    Widget bar(IconData icon, String text, {String? action, VoidCallback? onAction, Color? color}) => Material(
      color: color ?? scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
            if (action != null) TextButton(onPressed: onAction, child: Text(action)),
          ],
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (c.status == 'closed') bar(Icons.check_circle_outline, 'This chat is closed.', action: 'Reopen', onAction: () => _menu('reopen')),
        if (c.status == 'snoozed')
          bar(
            Icons.snooze,
            'Snoozed until ${snoozedUntilText(c.snoozedUntil)}. It comes back when the customer writes.',
            action: 'Unsnooze',
            onAction: () => _menu('reopen'),
          ),
        if (chat.mustClaimFirst && !_noteMode)
          bar(
            Icons.fiber_new,
            'New lead: take this chat to reply. You can still add an internal note.',
            action: 'Assign to me',
            onAction: () => _menu('claim'),
            color: const Color(0xFFFFF4C2).withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.2 : 1),
          ),
      ],
    );
  }

  Widget _suggestions() => Material(
    color: Theme.of(context).colorScheme.surface,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final q in _quick)
            ListTile(
              dense: true,
              leading: const Icon(Icons.bolt, size: 20),
              title: Text('/${q.shortcut}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(q.description ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => _pickQuick(q),
            ),
        ],
      ),
    ),
  );

  Widget _mentions() => Material(
    color: Theme.of(context).colorScheme.surface,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final m in _mentionChoices)
            ListTile(
              dense: true,
              leading: MemberAvatar(name: m.name, userId: m.id, size: 30),
              title: Text(m.name),
              subtitle: Text(m.email),
              onTap: () => _pickMention(m),
            ),
        ],
      ),
    ),
  );

  Widget _composer(Conversation? c) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.chat;
    if (c == null) return const SizedBox.shrink();

    final editingSomething = _editing != null || _editingNote != null;
    // Replies need: allowed to write (New Leads: Assign to me first), the 24-hour window open
    final windowClosed = !chat.isWindowOpen;
    if (!_noteMode && !editingSomething && (windowClosed || !chat.canReply)) {
      return SafeArea(
        top: false,
        child: Container(
          color: scheme.surface,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              if (windowClosed && chat.canReply)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _menu('template'),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Send template'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                  ),
                )
              else
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _menu('claim'),
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Assign to me'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                  ),
                ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => setState(() => _noteMode = true),
                icon: const Icon(Icons.sticky_note_2_outlined),
                label: const Text('Add note'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              ),
            ],
          ),
        ),
      );
    }

    final text = _text.text;
    final over = text.length > _limit;
    final showCounter = text.length > _limit * 0.9;
    final canSend = text.trim().isNotEmpty || (_noteMode && _noteFiles.isNotEmpty);

    return SafeArea(
      top: false,
      child: Container(
        color: _noteMode ? colors.note : scheme.surface,
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (windowClosed && !_noteMode && editingSomething == false) const SizedBox.shrink(),
            if (_editing != null || _editingNote != null)
              Row(
                children: [
                  const SizedBox(width: 8),
                  const Icon(Icons.edit, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _editing != null ? 'Editing message (the customer keeps what they received)' : 'Editing note',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                  IconButton(onPressed: _cancelEdit, icon: const Icon(Icons.close, size: 18)),
                ],
              ),
            if (_replyTo != null && !_noteMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                child: QuoteBlock(
                  quote: QuotedMessage(
                    id: _replyTo!.id,
                    direction: _replyTo!.direction,
                    type: _replyTo!.type,
                    body: _replyTo!.body,
                    senderName: _replyTo!.senderName,
                    deleted: _replyTo!.isDeleted,
                    mediaName: _replyTo!.mediaName,
                  ),
                  onClose: () => setState(() => _replyTo = null),
                ),
              ),
            if (_noteMode && _noteFiles.isNotEmpty)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final f in _noteFiles)
                      Padding(
                        padding: const EdgeInsets.only(right: 6, left: 4),
                        child: InputChip(
                          avatar: Icon(f.mime.startsWith('image/') ? Icons.image : Icons.insert_drive_file, size: 16),
                          label: Text(f.name, overflow: TextOverflow.ellipsis),
                          onDeleted: () => setState(() => _noteFiles.remove(f)),
                        ),
                      ),
                  ],
                ),
              ),
            if (!editingSomething)
              Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 4),
                child: Row(
                  children: [
                    _modeChip('Reply', !_noteMode, () => setState(() => _noteMode = false), enabled: chat.canReply && chat.isWindowOpen),
                    const SizedBox(width: 6),
                    _modeChip(
                      'Add note',
                      _noteMode,
                      () => setState(() {
                        _noteMode = true;
                        _replyTo = null;
                      }),
                    ),
                    const Spacer(),
                    if (showCounter)
                      Text(
                        '${text.length} / $_limit',
                        style: TextStyle(fontSize: 11.5, color: over ? scheme.error : colors.meta, fontWeight: over ? FontWeight.w700 : null),
                      ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            if (_recording)
              Row(
                children: [
                  const SizedBox(width: 10),
                  const Icon(Icons.fiber_manual_record, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Text(_recordStart == null ? '' : _elapsed(DateTime.now().difference(_recordStart!)), style: const TextStyle(fontSize: 16)),
                  const Spacer(),
                  TextButton.icon(onPressed: () => _stopRecording(send: false), icon: const Icon(Icons.delete_outline), label: const Text('Cancel')),
                  IconButton.filled(onPressed: () => _stopRecording(send: true), icon: const Icon(Icons.send)),
                ],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: _noteMode ? 'Attach to note' : 'Attach',
                    onPressed: editingSomething || _busy ? null : _attach,
                    icon: const Icon(Icons.attach_file),
                  ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: _noteMode
                            ? Colors.white.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.08 : 0.7)
                            : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: TextField(
                        controller: _text,
                        focusNode: _focus,
                        minLines: 1,
                        // fewer lines when little room is left (keyboard open on a small phone), so nothing overflows
                        maxLines: MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom < 560 ? 3 : 6,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: _noteMode ? 'Internal note · @ to mention a teammate' : (chat.isWindowOpen ? 'Message · / for quick replies' : 'Message'),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else if (canSend || _noteMode || editingSomething)
                    IconButton.filled(
                      onPressed: canSend && !over ? _submit : null,
                      style: IconButton.styleFrom(backgroundColor: _noteMode ? const Color(0xFFB45309) : null),
                      icon: Icon(editingSomething ? Icons.check : (_noteMode ? Icons.sticky_note_2 : Icons.send)),
                    )
                  else
                    GestureDetector(
                      onLongPressStart: (_) => _startRecording(),
                      onLongPressEnd: (_) => _stopRecording(send: true),
                      child: IconButton.filled(onPressed: _startRecording, icon: const Icon(Icons.mic)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  String _elapsed(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _modeChip(String label, bool selected, VoidCallback onTap, {bool enabled = true}) => ChoiceChip(
    label: Text(label, style: const TextStyle(fontSize: 12.5)),
    selected: selected,
    showCheckmark: false,
    visualDensity: VisualDensity.compact,
    onSelected: enabled ? (_) => onTap() : null,
  );
}
