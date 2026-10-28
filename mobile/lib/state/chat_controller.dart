import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/session.dart';
import '../logic/rules.dart';
import '../models/models.dart';

/// One row of the chat: a message bubble, an internal note, a timeline event, or a day separator.
sealed class ChatItem {
  DateTime get at;
}

class MessageItem extends ChatItem {
  MessageItem(this.message);
  final Message message;
  @override
  DateTime get at => message.createdAt;
}

class NoteItem extends ChatItem {
  NoteItem(this.note);
  final ContactRemark note;
  @override
  DateTime get at => note.createdAt;
}

class ActivityItem extends ChatItem {
  ActivityItem(this.activity);
  final Activity activity;
  @override
  DateTime get at => activity.createdAt;
}

/// A message on its way (shown with a clock until the server answers), like WhatsApp
class PendingSend {
  PendingSend({required this.localId, required this.kind, required this.text, this.fileName, this.bytes, this.replyTo});
  final String localId;
  final String kind; // text | image | document | voice
  final String text;
  final String? fileName;
  final Uint8List? bytes;
  final QuotedMessage? replyTo;
  final DateTime at = DateTime.now().toUtc();
  String? error;
}

/// The open chat: its messages (paged), internal notes, timeline and every action on it, kept live from the server.
class ChatController extends ChangeNotifier {
  ChatController(this.session, this.conversationId) {
    final rt = session.realtime;
    _subs.addAll([
      rt.on('message:new').listen((e) {
        final msg = e.map['message'];
        if (msg is! Map) return;
        final m = Message.fromJson(Map<String, dynamic>.from(msg));
        if (m.conversationId != conversationId) return;
        final conv = e.map['conversation'];
        if (conv is Map && conv['lastInboundAt'] is String) {
          conversation?.lastInboundAt = DateTime.tryParse(conv['lastInboundAt']);
          // A new customer message opens the window again: the composer goes back to normal
          if (!m.isOut) windowClosedByServer = false;
        }
        _upsert(m);
        if (!m.isOut) unawaited(_markRead());
      }),
      rt.onAny({'message:status', 'message:updated'}).listen((e) {
        final m = Message.fromJson(e.map);
        if (m.conversationId != conversationId) return;
        final i = messages.indexWhere((x) => x.id == m.id);
        if (i >= 0) {
          messages[i] = messages[i].newer(m);
          notifyListeners();
        }
      }),
      rt.on('contact:remarks').listen((e) {
        if (e.map['contactId'] == conversation?.contact.id) unawaited(loadNotes());
      }),
      rt.on('activity:new').listen((e) {
        final a = Activity.fromJson(e.map);
        if (a.conversationId != conversationId || a.type == 'message_received' || activity.any((x) => x.id == a.id)) return;
        activity.add(a);
        notifyListeners();
      }),
      rt.on('conversation:status').listen((e) {
        final m = e.map;
        if ((m['conversationId'] ?? m['id']) != conversationId) return;
        conversation?.status = m['status'] ?? conversation!.status;
        conversation?.snoozedUntil = m['snoozedUntil'] is String ? DateTime.tryParse(m['snoozedUntil']) : null;
        notifyListeners();
      }),
      rt.on('conversation:assigned').listen((e) {
        if (e.map['conversationId'] != conversationId) return;
        final a = e.map['assignee'];
        conversation?.assignee = a is Map ? AssigneeRef.fromJson(Map<String, dynamic>.from(a)) : null;
        notifyListeners();
      }),
      rt.on('assignment:you').listen((e) {
        // Assigned to you while you're looking at it: it counts as opened (no reminders for it)
        if (e.map['conversationId'] == conversationId) unawaited(_markRead());
      }),
      rt.on('conversation:labels').listen((e) {
        if (e.map['conversationId'] != conversationId) return;
        conversation?.labels = (e.map['labels'] as List?)?.whereType<Map>().map((l) => LabelRef.fromJson(Map<String, dynamic>.from(l))).toList() ?? [];
        notifyListeners();
      }),
      rt.on('conversation:pinned').listen((e) {
        if (e.map['conversationId'] != conversationId) return;
        conversation?.pinned = e.map['pinned'] == true;
        notifyListeners();
      }),
      rt.on('conversation:collaborators').listen((e) {
        if (e.map['conversationId'] != conversationId) return;
        final ids = (e.map['collaborators'] as List?)?.whereType<Map>().map((m) => m['id']).toList() ?? [];
        conversation?.isCollaborator = ids.contains(session.userId);
        notifyListeners();
      }),
      rt.on('conversation:cleared').listen((e) {
        if (e.map['conversationId'] == conversationId && e.map['userId'] == session.userId) unawaited(load());
      }),
      rt.on('contact:updated').listen((e) {
        final m = e.map;
        final c = conversation;
        if (c == null || m['id'] != c.contact.id) return;
        c.contact = Contact(
            id: c.contact.id,
            waId: c.contact.waId,
            name: m.containsKey('name') ? m['name'] as String? : c.contact.name,
            leadStage: m.containsKey('leadStage') ? m['leadStage'] as String? : c.contact.leadStage,
            country: m.containsKey('country') ? m['country'] as String? : c.contact.country);
        notifyListeners();
      }),
      rt.on('contact:deleted').listen((e) {
        if (e.map['conversationId'] == conversationId) {
          gone = true;
          notifyListeners();
        }
      }),
      rt.on('typing').listen((e) {
        final m = e.map;
        if (m['conversationId'] != conversationId || m['userId'] == session.userId) return;
        if (m['typing'] == true) {
          typingName = '${m['name'] ?? 'Someone'}';
          _typingTimer?.cancel();
          _typingTimer = Timer(const Duration(seconds: 6), () {
            typingName = null;
            notifyListeners();
          });
        } else {
          typingName = null;
        }
        notifyListeners();
      }),
      rt.connection.where((c) => c).listen((_) => unawaited(load(quiet: true))),
    ]);
  }

  final Session session;
  final String conversationId;
  final List<StreamSubscription> _subs = [];
  Timer? _typingTimer;
  Timer? _windowTimer;

  Conversation? conversation;
  List<Message> messages = [];
  List<ContactRemark> notes = [];
  List<Activity> activity = [];
  final List<PendingSend> pending = [];
  bool loading = true;
  bool loadingOlder = false;
  bool hasOlder = false;
  String? _cursor;
  String? error;
  String? typingName;
  bool gone = false;

  /// The server refused a send because the window had closed (its clock decides): show "Send template" at once
  bool windowClosedByServer = false;

  bool get isWindowOpen => !windowClosedByServer && windowOpen(conversation?.lastInboundAt);
  bool get isClosed => conversation?.status == 'closed';
  bool get isUnassigned => conversation?.assignee == null;

  /// New Leads: agents must take the chat before replying; owners, admins and supervisors may reply directly
  bool get mustClaimFirst => isUnassigned && !session.isSupervisorOrAbove;

  bool get canReply => conversation != null && !mustClaimFirst;

  /// Rows oldest first: messages, notes and timeline events by time, plus pending sends at the end
  List<ChatItem> get items {
    final list = <ChatItem>[
      ...messages.map(MessageItem.new),
      ...notes.map(NoteItem.new),
      ...activity.map(ActivityItem.new),
    ];
    list.sort((a, b) => a.at.compareTo(b.at));
    // Older timeline/notes than the first loaded page wait until that page is loaded (no jumps)
    if (hasOlder && messages.isNotEmpty) {
      final first = messages.first.createdAt;
      list.removeWhere((i) => i is! MessageItem && i.at.isBefore(first));
    }
    return list;
  }

  Future<void> load({bool quiet = false}) async {
    if (!quiet) {
      loading = true;
      error = null;
      notifyListeners();
    }
    try {
      final results = await Future.wait([
        session.repo.conversation(conversationId),
        session.repo.messages(conversationId),
      ]);
      conversation = results[0] as Conversation;
      final page = results[1] as dynamic;
      messages = List<Message>.from(page.nodes);
      hasOlder = page.hasNextPage;
      _cursor = page.endCursor;
      error = null;
      loading = false;
      notifyListeners();
      _scheduleWindowCheck();
      await Future.wait([loadNotes(), loadActivity(), _markRead()]);
    } catch (e) {
      if (e is ApiException && e.code == 'NOT_FOUND') gone = true;
      if (!quiet || conversation == null) error = errorText(e);
      loading = false;
      notifyListeners();
    }
  }

  /// The composer switches to "Send template" the moment the window closes, even with the screen left open
  void _scheduleWindowCheck() {
    _windowTimer?.cancel();
    final left = timeUntilClose(conversation?.lastInboundAt);
    if (left != null) _windowTimer = Timer(left + const Duration(seconds: 1), notifyListeners);
  }

  Future<void> loadOlder() async {
    if (!hasOlder || loadingOlder) return;
    loadingOlder = true;
    notifyListeners();
    try {
      final page = await session.repo.messages(conversationId, after: _cursor);
      final known = messages.map((m) => m.id).toSet();
      messages = [...page.nodes.where((m) => !known.contains(m.id)), ...messages];
      hasOlder = page.hasNextPage;
      _cursor = page.endCursor;
    } catch (_) {
    } finally {
      loadingOlder = false;
      notifyListeners();
    }
  }

  Future<void> loadNotes() async {
    try {
      notes = await session.repo.chatNotes(conversationId);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> loadActivity() async {
    try {
      activity = (await session.repo.conversationActivity(conversationId)).where((a) => a.type != 'message_received').toList();
      notifyListeners();
    } catch (_) {}
  }

  void _upsert(Message m) {
    final i = messages.indexWhere((x) => x.id == m.id);
    if (i >= 0) {
      messages[i] = messages[i].newer(m);
    } else {
      messages.add(m);
      messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    if (conversation != null && m.createdAt.isAfter(conversation!.lastMessageAt)) {
      conversation!.lastMessageAt = m.createdAt;
      conversation!.lastMessage = m;
    }
    notifyListeners();
  }

  String _localId() => 'local-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  QuotedMessage? _quote(Message? m) => m == null
      ? null
      : QuotedMessage(id: m.id, direction: m.direction, type: m.type, body: m.body, senderName: m.senderName, deleted: m.isDeleted, mediaMime: m.mediaMime, mediaName: m.mediaName);

  /// Runs a send with a pending bubble; WINDOW_CLOSED switches the composer to templates
  Future<bool> _send(PendingSend p, Future<Message> Function() run) async {
    pending.add(p);
    notifyListeners();
    try {
      final m = await run();
      pending.remove(p);
      _upsert(m);
      return true;
    } catch (e) {
      if (isWindowClosedError(e)) {
        windowClosedByServer = true;
        pending.remove(p);
        notifyListeners();
        rethrow;
      }
      p.error = errorText(e);
      notifyListeners();
      rethrow;
    }
  }

  Future<bool> sendText(String text, {Message? replyTo}) => _send(
        PendingSend(localId: _localId(), kind: 'text', text: text, replyTo: _quote(replyTo)),
        () => session.repo.sendText(conversationId, text, replyToId: replyTo?.id),
      );

  Future<bool> sendFile({required Uint8List bytes, required String mime, required bool image, required String name, String caption = '', Message? replyTo}) => _send(
        PendingSend(localId: _localId(), kind: image ? 'image' : 'document', text: caption, fileName: name, bytes: image ? bytes : null, replyTo: _quote(replyTo)),
        () => session.repo.sendFile(conversationId, bytes: bytes, mime: mime, image: image, name: name, caption: caption, replyToId: replyTo?.id),
      );

  Future<bool> sendVoice(Uint8List bytes, String mime, {Message? replyTo}) => _send(
        PendingSend(localId: _localId(), kind: 'voice', text: '', replyTo: _quote(replyTo)),
        () => session.repo.sendVoice(conversationId, bytes, mime, replyToId: replyTo?.id),
      );

  void dismissPending(PendingSend p) {
    pending.remove(p);
    notifyListeners();
  }

  Future<void> sendTemplate(MessageTemplate t, TemplateValues values, String requestId, {({Uint8List bytes, String mime, String name})? headerFile}) async {
    final m = await session.repo.sendTemplate(conversationId, t, values, requestId, headerFile: headerFile);
    _upsert(m);
  }

  Future<void> react(Message m, String? emoji) async => _upsert(await session.repo.react(m.id, emoji));
  Future<void> edit(Message m, String body) async => _upsert(await session.repo.editMessage(m.id, body, m.version));
  Future<Message> delete(Message m) async {
    final d = await session.repo.deleteMessage(m.id, m.version);
    _upsert(d);
    return d;
  }

  Future<void> restore(Message deleted) async => _upsert(await session.repo.restoreMessage(deleted.id, deleted.version));

  // ---------------------------------------------------------------- Notes

  Future<void> addNote(String body, {List<String> mentions = const [], List<String> files = const []}) async {
    final c = conversation;
    if (c == null) return;
    final note = await session.repo.addRemark(c.contact.id, body, mentions: mentions, files: files);
    if (!notes.any((n) => n.id == note.id)) notes.add(note);
    notifyListeners();
  }

  Future<void> editNote(ContactRemark n, String body) async {
    final updated = await session.repo.updateRemark(n.id, body);
    final i = notes.indexWhere((x) => x.id == n.id);
    if (i >= 0) notes[i] = updated;
    notifyListeners();
  }

  Future<void> deleteNote(ContactRemark n) async {
    await session.repo.deleteRemark(n.id);
    notes.removeWhere((x) => x.id == n.id);
    notifyListeners();
  }

  // ---------------------------------------------------------------- Chat actions

  Future<void> claim() async {
    final a = await session.repo.claim(conversationId);
    conversation?.assignee = a;
    notifyListeners();
    // Taken while looking at it: it counts as opened by its new assignee (no "waiting for you" mark or reminders)
    await _markRead();
  }

  /// Tells the server this chat is read, then the unread total (Chats tab, app icon) is reloaded. Never throws.
  Future<void> _markRead() async {
    try {
      await session.repo.markRead(conversationId);
      session.onConversationRead?.call();
    } catch (_) {}
  }

  Future<void> assign(String? memberId, {String? reason}) async {
    final a = await session.repo.assign(conversationId, assigneeId: memberId, reason: reason);
    conversation?.assignee = a;
    notifyListeners();
  }

  Future<void> setLabel(String labelId, bool add) async {
    conversation?.labels = await session.repo.setConversationLabel(conversationId, labelId, add);
    notifyListeners();
  }

  Future<void> setClosed(bool close) async {
    await session.repo.setStatus(conversationId, close);
    conversation?.status = close ? 'closed' : 'open';
    conversation?.snoozedUntil = null;
    notifyListeners();
  }

  Future<void> snooze(DateTime until) async {
    await session.repo.snooze(conversationId, until);
    conversation?.status = 'snoozed';
    conversation?.snoozedUntil = until;
    notifyListeners();
  }

  Future<void> setPinned(bool pinned) async {
    await session.repo.setPinned(conversationId, pinned);
    conversation?.pinned = pinned;
    notifyListeners();
  }

  Future<void> markUnread() => session.repo.markUnread(conversationId);

  Future<void> clear() async {
    await session.repo.clearChat(conversationId);
    await load(quiet: true);
  }

  // ---------------------------------------------------------------- Typing

  DateTime _lastTyping = DateTime.fromMillisecondsSinceEpoch(0);
  bool _typingSent = false;

  /// "typing…" for teammates: about one event every 2.5 s while typing, and a stop when the box empties or the chat closes
  void typed(String text) {
    if (!canReply || !isWindowOpen) return;
    if (text.isEmpty) {
      stopTyping();
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastTyping) > const Duration(milliseconds: 2500)) {
      _lastTyping = now;
      _typingSent = true;
      session.realtime.emit('typing', {'conversationId': conversationId, 'typing': true});
    }
  }

  void stopTyping() {
    if (!_typingSent) return;
    _typingSent = false;
    _lastTyping = DateTime.fromMillisecondsSinceEpoch(0);
    session.realtime.emit('typing', {'conversationId': conversationId, 'typing': false});
  }

  @override
  void dispose() {
    stopTyping();
    for (final s in _subs) {
      s.cancel();
    }
    _typingTimer?.cancel();
    _windowTimer?.cancel();
    super.dispose();
  }
}
