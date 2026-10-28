import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/repo.dart';
import '../core/session.dart';
import '../logic/rules.dart';
import '../models/models.dart';

/// One chat list (Inbox, My chats, New leads, Collaborations, Mentions or a lifecycle stage) with its filters, pages
/// and live updates. Like the website, server events patch the rows at once and then the page reloads quietly.
class InboxStore extends ChangeNotifier {
  InboxStore(this.session, this.query) {
    final rt = session.realtime;
    _subs.addAll([
      rt.on('message:new').listen((e) {
        final conv = e.map['conversation'];
        final msg = e.map['message'];
        if (msg is Map) {
          final m = Message.fromJson(Map<String, dynamic>.from(msg));
          _patch(m.conversationId, (c) {
            c.lastMessage = m;
            c.lastMessageAt = m.createdAt;
            if (conv is Map && conv['lastInboundAt'] is String) c.lastInboundAt = DateTime.tryParse(conv['lastInboundAt']);
            if (conv is Map && conv['unread'] is num) c.unread = (conv['unread'] as num).toInt();
          });
          _sortVisible();
        }
        _reloadSoon();
      }),
      rt.on('message:status').listen((e) {
        final m = Message.fromJson(e.map);
        _patch(m.conversationId, (c) {
          if (c.lastMessage?.id == m.id) c.lastMessage = c.lastMessage!.newer(m);
        });
      }),
      rt.on('message:updated').listen((e) {
        final m = Message.fromJson(e.map);
        _patch(m.conversationId, (c) {
          if (c.lastMessage?.id == m.id) c.lastMessage = c.lastMessage!.newer(m);
        });
      }),
      rt.on('conversation:status').listen((e) {
        final m = e.map;
        _patch(m['id'] ?? m['conversationId'], (c) {
          if (m['status'] is String) c.status = m['status'];
          c.snoozedUntil = m['snoozedUntil'] is String ? DateTime.tryParse(m['snoozedUntil']) : null;
        });
        _reloadSoon();
      }),
      rt.on('conversation:assigned').listen((e) {
        final a = e.map['assignee'];
        _patch(e.map['conversationId'], (c) {
          c.assignee = a is Map ? AssigneeRef.fromJson(Map<String, dynamic>.from(a)) : null;
          c.wasAssigned = c.wasAssigned || a != null;
        });
        _reloadSoon();
      }),
      rt.on('conversation:labels').listen((e) {
        final labels = (e.map['labels'] as List?)?.whereType<Map>().map((l) => LabelRef.fromJson(Map<String, dynamic>.from(l))).toList() ?? [];
        _patch(e.map['conversationId'], (c) => c.labels = labels);
      }),
      rt.on('conversation:pinned').listen((e) {
        _patch(e.map['conversationId'], (c) => c.pinned = e.map['pinned'] == true);
        _reloadSoon();
      }),
      rt.on('conversation:unread').listen((e) {
        final u = (e.map['unread'] as num?)?.toInt() ?? 1;
        _patch(e.map['conversationId'], (c) => c.unread = c.unread > u ? c.unread : u);
      }),
      rt.on('conversation:collaborators').listen((e) {
        final ids = (e.map['collaborators'] as List?)?.whereType<Map>().map((m) => m['id']).toList() ?? [];
        _patch(e.map['conversationId'], (c) => c.isCollaborator = ids.contains(session.userId));
        if (query.assignee == 'collaborating') _reloadSoon();
      }),
      rt.on('contact:updated').listen((e) {
        final m = e.map;
        for (final c in items.where((c) => c.contact.id == m['id'])) {
          c.contact = Contact(
              id: c.contact.id,
              waId: c.contact.waId,
              name: c.contact.name,
              leadStage: m.containsKey('leadStage') ? m['leadStage'] as String? : c.contact.leadStage,
              country: m.containsKey('country') ? m['country'] as String? : c.contact.country);
        }
        notifyListeners();
        if (query.leadStage != null || query.leadStages.isNotEmpty) _reloadSoon();
      }),
      rt.on('contact:deleted').listen((e) {
        items.removeWhere((c) => c.id == e.map['conversationId']);
        notifyListeners();
      }),
      rt.onAny({'contact:restored', 'conversation:started', 'conversation:cleared'}).listen((_) => _reloadSoon()),
      rt.onAny({'mention:you', 'mentions:changed'}).listen((_) {
        if (query.assignee == 'mentioned') _reloadSoon();
      }),
      rt.on('typing').listen((e) {
        final m = e.map;
        final id = m['conversationId'] as String?;
        if (id == null || m['userId'] == session.userId) return;
        if (m['typing'] == true) {
          typing[id] = (name: '${m['name'] ?? 'Someone'}', until: DateTime.now().add(const Duration(seconds: 6)));
        } else {
          typing.remove(id);
        }
        notifyListeners();
      }),
      rt.connection.where((c) => c).listen((_) => _reloadSoon()),
    ]);
    _typingSweep = Timer.periodic(const Duration(seconds: 2), (_) {
      final before = typing.length;
      typing.removeWhere((_, v) => v.until.isBefore(DateTime.now()));
      if (typing.length != before) notifyListeners();
    });
  }

  final Session session;
  ConversationQuery query;
  final List<StreamSubscription> _subs = [];
  Timer? _reloadTimer;
  Timer? _typingSweep;
  int _generation = 0;

  List<Conversation> items = [];
  bool loading = false;
  bool loadingMore = false;
  bool hasMore = false;
  String? _cursor;
  String? error;

  /// Who is typing where (other agents only; WhatsApp doesn't tell businesses when a customer types)
  final Map<String, ({String name, DateTime until})> typing = {};

  /// The "Unread" chip: only chats with unread customer messages (the server filters with its "unread" search word
  /// when nothing else is searched; otherwise the rows are narrowed here)
  bool unreadOnly = false;

  /// What's shown: the server's rows, with the search applied at once while the server search refreshes
  List<Conversation> get visible {
    final searched = (query.search?.trim().isEmpty ?? true) ? items : items.where((c) => matchesSearch(c, query.search!)).toList();
    return unreadOnly ? searched.where((c) => c.unread > 0).toList() : searched;
  }

  void _patch(String? id, void Function(Conversation) fn) {
    if (id == null) return;
    var changed = false;
    for (final c in items) {
      if (c.id == id) {
        fn(c);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void _sortVisible() {
    final pinned = items.where((c) => c.pinned).toList();
    final rest = items.where((c) => !c.pinned).toList()
      ..sort((a, b) => query.sort == 'oldest' ? a.lastMessageAt.compareTo(b.lastMessageAt) : b.lastMessageAt.compareTo(a.lastMessageAt));
    items = [...pinned, ...rest];
    notifyListeners();
  }

  void _reloadSoon() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 350), () => load(quiet: true));
  }

  void setQuery(ConversationQuery q) {
    query = q;
    load();
  }

  Future<void> load({bool quiet = false}) async {
    final gen = ++_generation;
    if (!quiet) {
      loading = true;
      error = null;
      notifyListeners();
    }
    try {
      final page = await session.repo.conversations(query);
      if (gen != _generation) return; // a newer search/filter replaced this one
      items = page.nodes;
      hasMore = page.hasNextPage;
      _cursor = page.endCursor;
      error = null;
    } catch (e) {
      if (gen != _generation) return;
      if (!quiet || items.isEmpty) error = errorText(e);
    } finally {
      if (gen == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    if (!hasMore || loadingMore || loading) return;
    loadingMore = true;
    notifyListeners();
    final gen = _generation;
    try {
      final page = await session.repo.conversations(query, after: _cursor);
      if (gen != _generation) return;
      final known = items.map((c) => c.id).toSet();
      items = [...items, ...page.nodes.where((c) => !known.contains(c.id))];
      hasMore = page.hasNextPage;
      _cursor = page.endCursor;
    } catch (_) {
      // the list keeps what it has; scrolling again retries
    } finally {
      loadingMore = false;
      notifyListeners();
    }
  }

  /// Opening a chat clears its unread badge here at once (the server is told by the chat screen)
  void markOpened(String id) => _patch(id, (c) {
        c.unread = 0;
        if (c.assignee?.userId == session.userId) c.assigneeOpenedAt ??= DateTime.now().toUtc();
      });

  void patch(String id, void Function(Conversation) fn) => _patch(id, fn);

  void reload() => _reloadSoon();

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _reloadTimer?.cancel();
    _typingSweep?.cancel();
    super.dispose();
  }
}
