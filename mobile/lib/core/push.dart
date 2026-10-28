import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_badge.dart';
import 'session.dart';

// Push notifications (Firebase Cloud Messaging) for when the app is in the background or closed. The server sends them
// (it holds the Firebase key); this app only registers its device token for the signed-in person and opens the chat
// when a notification is tapped. In the foreground the live Socket.IO connection shows the same events, so pushes that
// arrive then are shown only while that connection is down (nothing shows twice, nothing is missed).
//
// Off unless this build has the Firebase app settings (dart-defines, see env/README.md) AND the server says push is
// configured. They're the app's public Firebase identifiers, not secrets.

const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
// Firebase gives each platform its own API key (google-services.json / GoogleService-Info.plist); FIREBASE_API_KEY is
// used where a platform's own key isn't set
const _androidApiKey = String.fromEnvironment('FIREBASE_ANDROID_API_KEY');
const _iosApiKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');
const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
const _senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
const _androidAppId = String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
const _iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
const _iosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');

/// This build's Firebase settings, or null when it has none (push off)
FirebaseOptions? firebaseOptions({TargetPlatform? platform}) {
  final p = platform ?? defaultTargetPlatform;
  final appId = p == TargetPlatform.iOS ? _iosAppId : (p == TargetPlatform.android ? _androidAppId : '');
  final platformKey = p == TargetPlatform.iOS ? _iosApiKey : (p == TargetPlatform.android ? _androidApiKey : '');
  final apiKey = platformKey.isNotEmpty ? platformKey : _apiKey;
  if (apiKey.isEmpty || _projectId.isEmpty || _senderId.isEmpty || appId.isEmpty) return null;
  return FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: _senderId,
    projectId: _projectId,
    iosBundleId: p == TargetPlatform.iOS && _iosBundleId.isNotEmpty ? _iosBundleId : null,
  );
}

/// The chat a notification opens (the server puts it in the message's data)
String? conversationOf(Map<String, dynamic> data) {
  final id = data['conversationId'];
  return id is String && id.isNotEmpty ? id : null;
}

/// What a push shows: its notification part, or the title and body in its data (a "data-only" push, which the phone
/// doesn't show by itself). Null when it has neither.
({String title, String body})? pushText(String? title, String? body, Map<String, dynamic> data) {
  String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  final t = text(title) ?? text(data['title']);
  final b = text(body) ?? text(data['body']) ?? text(data['message']);
  if (t == null && b == null) return null;
  return (title: t ?? 'TyresCart Support', body: b ?? '');
}

/// Shows a data-only push on the phone, like the system shows one with a notification part: the "Messages" channel,
/// one notification per chat (a newer one replaces it), tapping it opens the chat.
Future<void> showDataPush(String title, String body, String? conversationId, {int? number}) async {
  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_notification'),
      iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
    ),
  );
  await notifications.show(
    id: 1,
    title: title,
    body: body,
    payload: conversationId,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails('messages', 'Messages',
          channelDescription: 'New customer messages, assignments and mentions',
          importance: Importance.high,
          priority: Priority.high,
          color: const Color(0xFF25D366),
          number: number, // the icon's count on launchers that read it from the notification (Samsung…)
          tag: conversationId ?? 'push'),
      iOS: DarwinNotificationDetails(threadIdentifier: conversationId),
    ),
  );
}

/// Messages that arrive while the app is in the background or closed: the icon's number is the server's unread
/// total, asked again for each one (the push itself says nothing reliable about it). One with a notification part is shown by the system itself (showing it here too would make two); a
/// data-only one is shown here, or nothing would appear.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {
  final count = await AppBadge.syncFromServer(Session.unreadTotalInBackground);
  if (message.notification != null) return;
  final text = pushText(null, null, message.data);
  if (text == null) return;
  try {
    await showDataPush(text.title, text.body, conversationOf(message.data), number: count);
  } catch (e) {
    debugPrint('[push] could not show a data-only push: $e');
  }
}

class Push {
  Push(this.session);
  final Session session;

  /// Opens a chat (set by the app once its navigator exists)
  void Function(String conversationId)? openChat;

  /// A push that arrived with the app open (set by the app: shown only if the live connection missed it)
  void Function(String title, String body, String? conversationId, String kind)? onForeground;

  bool _ready = false; // Firebase initialised for this build
  String? _registeredToken; // registered with the server for the current sign-in
  String? _pendingChat; // tapped before the app was signed in / ready
  final List<StreamSubscription> _subs = [];

  /// Push is working for this sign-in: the app leaves background alerts to it (no second notification of its own)
  bool get active => _registeredToken != null;

  Future<void> init() async {
    final options = firebaseOptions();
    if (options == null) return; // this build has no Firebase settings: push off
    try {
      await Firebase.initializeApp(options: options);
      FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);
      final fm = FirebaseMessaging.instance;
      // No device token until the server says it sends push (signedIn turns this on just before asking for one)
      await fm.setAutoInitEnabled(false);
      // In the foreground the live connection shows alerts: iOS shouldn't add its own banner too
      await fm.setForegroundNotificationPresentationOptions(alert: false, badge: false, sound: false);
      _subs.add(FirebaseMessaging.onMessageOpenedApp.listen((m) => _open(conversationOf(m.data))));
      // The registration token (getToken / onTokenRefresh / deleteToken) is what the server targets with FCM's HTTP v1
      // API (message.token). Their replacements (register / onRegistered) return a Firebase Installation ID for a
      // different send mode, so the token calls are kept on purpose.
      // ignore: deprecated_member_use
      _subs.add(fm.onTokenRefresh.listen((t) {
        if (_registeredToken != null) unawaited(_register(t));
      }));
      // In the foreground Socket.IO normally alerted already; the app decides (onForeground)
      _subs.add(FirebaseMessaging.onMessage.listen((m) {
        final text = pushText(m.notification?.title, m.notification?.body, m.data);
        if (text == null) return;
        onForeground?.call(text.title, text.body, conversationOf(m.data), '${m.data['kind'] ?? ''}');
      }));
      _ready = true;
      final initial = await fm.getInitialMessage(); // the app was opened (cold start) from a notification
      _open(conversationOf(initial?.data ?? const {}));
    } catch (e) {
      _ready = false;
      debugPrint('[push] Firebase unavailable, push off: $e');
    }
  }

  /// A notification the app showed itself (a data-only push) was tapped while the app was closed
  void openFromNotification(String conversationId) => _open(conversationId);

  void _open(String? conversationId) {
    if (conversationId == null) return;
    if (session.state == SessionState.signedIn && openChat != null) {
      openChat!(conversationId);
    } else {
      _pendingChat = conversationId; // opened once signed in
    }
  }

  /// Called when someone is signed in (sign-in, restored session, another workspace): register this phone for them
  Future<void> signedIn() async {
    final chat = _pendingChat;
    _pendingChat = null;
    if (chat != null && openChat != null) openChat!(chat);
    if (!_ready || !session.deviceNotificationsOn) return;
    try {
      if (!await session.repo.pushConfigured()) return; // the server can't send yet: don't hand it a token
      final fm = FirebaseMessaging.instance;
      await fm.setAutoInitEnabled(true);
      final perm = await fm.requestPermission(alert: true, badge: true, sound: true);
      if (perm.authorizationStatus == AuthorizationStatus.denied) return;
      if (Platform.isIOS && await fm.getAPNSToken() == null) {
        // iOS needs its APNs token first (it can take a moment after permission)
        await Future.delayed(const Duration(seconds: 2));
      }
      // ignore: deprecated_member_use
      final token = await fm.getToken();
      if (token != null) await _register(token);
    } catch (e) {
      debugPrint('[push] could not register this device: $e');
    }
  }

  Future<void> _register(String token) async {
    final ok = await session.repo.registerPushDevice(token, Platform.isIOS ? 'ios' : 'android');
    _registeredToken = ok ? token : null;
  }

  /// Called just before signing out (while still signed in): this phone gets no more notifications for this person
  Future<void> signingOut() async {
    final token = _registeredToken;
    _registeredToken = null;
    if (token == null) return;
    try {
      await session.repo.unregisterPushDevice(token).timeout(const Duration(seconds: 4));
    } catch (_) {
      // offline: the server forgets the token when Firebase later reports it gone, or when someone else signs in here
    }
    try {
      // ignore: deprecated_member_use
      await FirebaseMessaging.instance.deleteToken(); // a fresh token for whoever signs in next
    } catch (_) {}
  }

  /// Settings → Notifications → Phone notifications
  Future<void> deviceNotificationsChanged(bool on) => on ? signedIn() : signingOut();

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
  }
}
