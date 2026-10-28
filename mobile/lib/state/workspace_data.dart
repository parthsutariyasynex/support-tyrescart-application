import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/app_badge.dart';
import '../core/session.dart';
import '../logic/rules.dart';
import '../models/models.dart';

/// Workspace-wide lists used by many screens (labels, assignees, teammates, lifecycle stages, counts, the bell),
/// loaded once and kept live from the server's events.
class WorkspaceData extends ChangeNotifier {
  WorkspaceData(this.session) {
    final rt = session.realtime;
    // Reading a chat lowers the total too (the server sends no event for it), like the website
    session.onConversationRead = () => _debounce('unread', loadUnreadTotal);
    // Back from the background: pushes counted on the icon meanwhile; the server's total replaces that guess
    _lifecycle = AppLifecycleListener(onResume: () {
      if (session.state == SessionState.signedIn) _debounce('unread', loadUnreadTotal);
    });
    _subs.addAll([
      rt.onAny({'label:saved', 'label:deleted'}).listen((_) => _debounce('labels', loadLabels)),
      rt.onAny({'assignee:saved', 'assignee:deleted', 'member:removed', 'member:permissions', 'conversation:assigned'}).listen((_) {
        _debounce('assignees', loadAssignees);
        _debounce('members', loadMembers);
        _debounce('counts', loadCounts);
      }),
      rt.onAny({'leadStages:changed'}).listen((_) => _debounce('options', loadFieldOptions)),
      rt.onAny({'message:new', 'conversation:status', 'conversation:started', 'conversation:unread', 'contact:deleted', 'contact:restored', 'chat:new', 'contact:updated'})
          .listen((_) {
        _debounce('counts', loadCounts);
        _debounce('unread', loadUnreadTotal);
        _debounce('stages', loadStageCounts);
      }),
      rt.on('notification:new').listen((e) {
        final a = Activity.fromJson(e.map);
        if (!inBell(a) || (a.actorId != null && a.actorId == session.userId)) return;
        if (notifications.any((x) => x.id == a.id)) return;
        notifications = [a, ...notifications].take(30).toList();
        unseen++;
        notifyListeners();
      }),
      rt.on('mentions:changed').listen((_) => _debounce('feed', loadNotifications)),
      rt.connection.where((c) => c).listen((_) => refreshAll()), // reconnected: pull what may have been missed
      rt.on('presence:update').listen((e) {
        final id = e.map['userId'] as String?;
        if (id == null) return;
        presence[id] = presenceFrom(e.map['status'] as String?);
        notifyListeners();
      }),
    ]);
  }

  final Session session;
  late final AppLifecycleListener _lifecycle;
  final List<StreamSubscription> _subs = [];
  final Map<String, Timer> _timers = {};

  List<Label> labels = [];
  List<Assignee> assignees = [];
  List<WorkspaceMember> members = [];
  ContactFieldOptions? fieldOptions;
  Map<String?, int> stageCounts = {};
  ConversationCounts counts = ConversationCounts();
  int unreadTotal = 0;
  List<Activity> notifications = [];
  /// Online / away / offline per user id (anyone missing is offline), live from the server
  final Map<String, PresenceStatus> presence = {};
  int unseen = 0;
  bool loaded = false;

  void _debounce(String key, Future<void> Function() fn) {
    _timers[key]?.cancel();
    _timers[key] = Timer(const Duration(milliseconds: 400), () => fn().catchError((_) {}));
  }

  Future<void> refreshAll() async {
    await Future.wait([
      loadLabels(),
      loadAssignees(),
      loadMembers(),
      loadFieldOptions(),
      loadCounts(),
      loadUnreadTotal(),
      loadStageCounts(),
      loadNotifications(),
      loadPresence(),
    ].map((f) => f.catchError((_) {})));
    loaded = true;
    notifyListeners();
  }

  Future<void> loadLabels() async {
    labels = await session.repo.labels();
    notifyListeners();
  }

  Future<void> loadAssignees() async {
    assignees = await session.repo.assignees();
    notifyListeners();
  }

  Future<void> loadMembers() async {
    members = await session.repo.workspaceMembers();
    notifyListeners();
  }

  Future<void> loadFieldOptions() async {
    fieldOptions = await session.repo.fieldOptions();
    notifyListeners();
  }

  Future<void> loadCounts() async {
    counts = await session.repo.counts();
    notifyListeners();
  }

  Future<void> loadUnreadTotal() async {
    unreadTotal = await session.repo.unreadTotal();
    unawaited(AppBadge.set(unreadTotal)); // the count on the app's icon
    notifyListeners();
  }

  Future<void> loadStageCounts() async {
    stageCounts = await session.repo.leadStageCounts();
    notifyListeners();
  }

  Future<void> loadNotifications() async {
    final n = await session.repo.notifications();
    notifications = n.items.where(inBell).take(30).toList();
    unseen = notifications.where((a) => n.seenAt == null || a.createdAt.isAfter(n.seenAt!)).length;
    notifyListeners();
  }

  Future<void> loadPresence() async {
    final d = await session.api.gql('{ presence { userId status } }');
    presence
      ..clear()
      ..addAll({for (final p in d['presence'] as List) p['userId'] as String: presenceFrom(p['status'] as String?)});
    notifyListeners();
  }

  PresenceStatus presenceOf(String? userId) => userId == null ? PresenceStatus.offline : (presence[userId] ?? PresenceStatus.offline);

  Future<void> markNotificationsSeen() async {
    unseen = 0;
    notifyListeners();
    await session.repo.markNotificationsSeen();
  }

  ContactOption? stage(String? value) => fieldOptions?.stage(value);

  /// Member display name by user id (for notes and @mentions)
  String? memberName(String? userId) => userId == null ? null : members.where((m) => m.id == userId).firstOrNull?.name;

  @override
  void dispose() {
    _lifecycle.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    for (final t in _timers.values) {
      t.cancel();
    }
    super.dispose();
  }
}
