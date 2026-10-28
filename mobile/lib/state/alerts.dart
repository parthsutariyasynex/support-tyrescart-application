import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;
import 'package:just_audio/just_audio.dart';

import '../core/realtime.dart';
import '../core/session.dart';
import '../logic/rules.dart';
import '../models/models.dart';

/// A pop-up inside the app (like the website's toasts and message pop-ups). Tapping it opens the chat.
class AlertBanner {
  AlertBanner(this.title, this.body, this.conversationId);
  final String title;
  final String body;
  final String? conversationId;
}

/// Alerts on every screen, from the one live connection (web: AppShell). The server sends each person only their own
/// assignment, mention and reminder events; customer messages go to the whole workspace, so they're filtered here by
/// the same rule as the website (alertsYou): admins every chat, others unassigned chats, their own and collaborations.
class Alerts with WidgetsBindingObserver {
  Alerts(this.session);
  final Session session;

  /// Whether push notifications reach this phone for the current sign-in (then background alerts come from them)
  bool Function() pushActive = () => false;

  final _banners = StreamController<AlertBanner>.broadcast();
  Stream<AlertBanner> get banners => _banners.stream;

  /// Opens a chat (set by the app once its navigator exists)
  void Function(String conversationId)? openChat;

  /// The app was started by tapping one of its own notifications (e.g. a data-only push shown while it was closed)
  void Function(String conversationId)? launchedFrom;

  /// The chat on screen right now: its messages don't alert
  String? openConversationId;

  /// A push notification that arrived while the app is open. The live connection normally alerted already, so it's
  /// shown only while that connection is down (e.g. it's reconnecting): nothing twice, nothing missed.
  void fromPush(String title, String body, String? conversationId, String kind) {
    if (session.realtime.isConnected) return;
    if (_foreground && conversationId != null && openConversationId == conversationId) return; // you're reading it
    _alert(title, body, conversationId, notifyInBackground: true, isMessage: kind == 'message');
  }

  bool _foreground = true;
  final _seen = <String>{};
  final List<StreamSubscription> _subs = [];
  final _notifications = FlutterLocalNotificationsPlugin();
  AudioPlayer? _player;
  int _nextId = 1;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      await _notifications.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_notification'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (r) {
          final id = r.payload;
          if (id != null && id.isNotEmpty) openChat?.call(id);
        },
      );
      final launch = await _notifications.getNotificationAppLaunchDetails();
      final launchedChat = launch?.didNotificationLaunchApp == true ? launch!.notificationResponse?.payload : null;
      if (launchedChat != null && launchedChat.isNotEmpty) launchedFrom?.call(launchedChat);
      // Asked without waiting: the answer only matters for later background alerts, and waiting here would keep
      // the app on a blank screen until the person answers the system dialog
      if (Platform.isAndroid) {
        final android = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        // The channel push notifications use too (the server sends channel_id "messages"), so it exists even
        // before the app has shown a notification of its own
        unawaited(android
            ?.createNotificationChannel(const AndroidNotificationChannel('messages', 'Messages',
                description: 'New customer messages, assignments and mentions', importance: Importance.high))
            .catchError((_) {}));
        unawaited(android?.requestNotificationsPermission().catchError((_) => false));
      }
    } catch (_) {
      // Notifications unavailable (e.g. denied): in-app banners still work
    }
    final rt = session.realtime;
    _subs.addAll([
      rt.on('message:new').listen(_onMessage),
      rt.on('assignment:you').listen((e) {
        final m = e.map;
        _alert('This chat has been assigned to you', '${m['contactName'] ?? ''}${m['actorName'] != null ? ' · by ${m['actorName']}' : ''}', m['conversationId'], notifyInBackground: true);
      }),
      rt.on('assignment:removed').listen((e) {
        final m = e.map;
        final who = m['actorName'] ?? 'A teammate';
        final a = m['assignee'] as Map?;
        final text = a == null
            ? '$who unassigned you from this chat.'
            : (m['actorId'] != null && a['userId'] == m['actorId'])
                ? '$who took this chat from you.'
                : '$who reassigned this chat to ${a['name']}.';
        _alert(text, '${m['contactName'] ?? ''}', m['conversationId'], notifyInBackground: true);
      }),
      rt.on('assignment:changed').listen((e) {
        final m = e.map;
        final who = m['actorName'] ?? 'A teammate';
        final a = m['assignee'] as Map?;
        final prev = m['previous'];
        final self = a != null && m['actorId'] != null && a['userId'] == m['actorId'];
        final text = a != null
            ? self
                ? '$who took this chat${prev != null ? ' from $prev' : ''}.'
                : prev != null
                    ? '$who reassigned this chat from $prev to ${a['name']}.'
                    : '$who assigned this chat to ${a['name']}.'
            : '$who unassigned ${prev ?? 'the assignee'} from this chat.';
        _alert(text, '${m['contactName'] ?? ''}', m['conversationId']);
      }),
      rt.on('collaborator:you').listen((e) => _alert('${e.map['actorName'] ?? 'A teammate'} added you as a collaborator on this chat.', '${e.map['contactName'] ?? ''}', e.map['conversationId'])),
      rt.on('collaborator:removed').listen((e) => _alert('${e.map['actorName'] ?? 'A teammate'} removed you as a collaborator from this chat.', '${e.map['contactName'] ?? ''}', e.map['conversationId'])),
      rt.on('mention:you').listen((e) {
        final m = e.map;
        _alert('${m['actorName'] ?? 'A teammate'} mentioned you in a note.', '${m['contactName'] ?? ''} · ${m['text'] ?? ''}', m['conversationId'], notifyInBackground: true);
      }),
      rt.on('chat:new').listen((e) => _alert('New chat received. It is waiting in New Leads.', '${e.map['contactName'] ?? ''}', e.map['conversationId'])),
      rt.on('assignment:reminder').listen((e) {
        final chats = (e.map['chats'] as List?)?.whereType<Map>().toList() ?? const [];
        if (chats.isEmpty) return;
        final mine = chats.where((c) => c['kind'] != 'unassigned').length;
        final waiting = chats.length - mine;
        final parts = [
          if (mine > 0) mine == 1 ? '1 chat assigned to you still needs attention' : '$mine chats assigned to you still need attention',
          if (waiting > 0) waiting == 1 ? '1 new chat is still unassigned and unread' : '$waiting new chats are still unassigned and unread',
        ];
        _alert('Reminder: ${parts.join('; ')}.', chats.map((c) => c['contactName']).join(', '), chats.first['conversationId'] as String?);
      }),
    ]);
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      Platform.isAndroid ? _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>() : null;

  /// Whether the phone lets this app show notifications (null: unknown, e.g. iOS before asking)
  Future<bool?> notificationsAllowed() async {
    try {
      return await _android?.areNotificationsEnabled();
    } catch (_) {
      return null;
    }
  }

  /// Asks the phone for notification permission (the system dialog); returns whether it's allowed now
  Future<bool> requestNotifications() async {
    try {
      return await _android?.requestNotificationsPermission() ?? true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _onMessage(ServerEvent e) async {
    final data = e.map;
    final msg = data['message'];
    if (msg is! Map) return;
    final m = Message.fromJson(Map<String, dynamic>.from(msg));
    if (m.isOut || m.isDeleted || _seen.contains(m.id)) return;
    _seen.add(m.id);
    if (_seen.length > 200) _seen.remove(_seen.first);
    if (_foreground && openConversationId == m.conversationId) return; // you're reading it
    final conv = data['conversation'] is Map ? Map<String, dynamic>.from(data['conversation']) : <String, dynamic>{};
    if (!session.isSupervisorOrAbove && conv['assignedToId'] != null) {
      // Someone's chat: alert only its assignee and collaborators (admins and supervisors: every chat, like push)
      try {
        final c = await session.repo.conversation(m.conversationId);
        final mineOrShared = c.assignee == null || c.assignee!.userId == session.userId || c.isCollaborator;
        if (!mineOrShared) return;
      } catch (_) {
        return;
      }
      if (_foreground && openConversationId == m.conversationId) return; // opened meanwhile
    }
    final contact = conv['contact'] is Map ? conv['contact'] as Map : const {};
    final name = (contact['name'] as String?)?.trim();
    final title = (name != null && name.isNotEmpty) ? name : (contact['waId'] != null ? '+${contact['waId']}' : 'New message');
    var text = (filePreview(m.type, m.body, m.mediaName) ?? (isMediaPlaceholder(m.body) ? '' : m.body)).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) text = 'New message';
    if (text.length > 120) text = '${text.substring(0, 119)}…';
    _alert(title, text, m.conversationId, notifyInBackground: true, isMessage: true);
  }

  void _alert(String title, String body, String? conversationId, {bool notifyInBackground = false, bool isMessage = false}) {
    if (_foreground) {
      _banners.add(AlertBanner(title, body, conversationId));
      if (isMessage) unawaited(_ping());
    } else if (notifyInBackground && session.deviceNotificationsOn && !pushActive()) {
      unawaited(_showDeviceNotification(title, body, conversationId));
    }
  }

  Future<void> _ping() async {
    if (!session.soundOn) return;
    try {
      _player ??= AudioPlayer();
      await _player!.setAsset('assets/sounds/ping.wav');
      await _player!.play();
    } catch (_) {}
  }

  Future<void> _showDeviceNotification(String title, String body, String? conversationId) async {
    try {
      await _notifications.show(
        id: _nextId++,
        title: title,
        body: body,
        payload: conversationId,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails('messages', 'Messages',
              channelDescription: 'New customer messages, assignments and mentions',
              importance: Importance.high,
              priority: Priority.high,
              playSound: session.soundOn,
              color: const Color(0xFF25D366),
              tag: conversationId),
          iOS: DarwinNotificationDetails(presentSound: session.soundOn, threadIdentifier: conversationId),
        ),
      );
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) session.realtime.emit('presence:activity');
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
  }
}
