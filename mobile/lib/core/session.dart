import 'dart:async';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'realtime.dart';
import 'repo.dart';

/// The server address built into this build (flutter build apk --dart-define=API_BASE_URL=https://support.example.com).
/// It's the website's address: its Next.js server forwards /graphql, /socket.io and the file routes to the API.
const definedServer = String.fromEnvironment('API_BASE_URL');

/// The live support website, used by every build unless API_BASE_URL says otherwise
const liveServer = 'https://connect.tyrescart.ae';

/// Without API_BASE_URL the app uses the live server (debug and release alike)
final String builtInServer = definedServer.isNotEmpty ? definedServer : liveServer;

String normalizeServer(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

enum SessionState { loading, signedOut, signedIn }

/// Who is signed in, to which workspace, with what role. The token lives in the phone's secure storage.
class Session extends ChangeNotifier {
  Session() {
    api = Api(baseUrl: builtInServer, onUnauthorized: () => unawaited(signOut(reason: 'Your session ended. Please sign in again.')));
    repo = Repo(api);
    _subs.add(realtime.on('member:permissions').listen((e) {
      if (e.map['userId'] == userId) unawaited(refreshMe());
    }));
    _subs.add(realtime.on('member:removed').listen((e) {
      if (e.map['userId'] == userId) unawaited(signOut(reason: 'You were removed from this workspace.'));
    }));
    _subs.add(realtime.onAny({'workspace:renamed', 'workspace:settings'}).listen((_) => unawaited(refreshMe())));
  }

  static const _tokenKey = 'auth_token';
  /// Only the developer override (long-press on the sign-in logo) is saved; otherwise the build's address is used, so
  /// a new build with another API_BASE_URL is never held back by an address saved earlier
  static const _serverKey = 'server_override';
  static const _lastWorkspaceKey = 'last_workspace';
  static const _soundKey = 'notify_sound';
  static const _notifyKey = 'notify_device';
  static const _themeKey = 'theme_mode';

  final _storage = const FlutterSecureStorage();
  final realtime = Realtime();
  final List<StreamSubscription> _subs = [];
  late final Api api;
  late final Repo repo;

  SessionState state = SessionState.loading;
  String? signOutReason;

  String server = builtInServer;
  String? userId;
  String userName = '';
  String userEmail = '';
  String? phone;
  String? jobTitle;
  String? workspaceId;
  String workspaceName = '';
  String? whatsappPhone;
  String role = 'agent';
  bool canManageLabels = false;
  bool canManageAssignments = false;
  int businessDayStartHour = 9;

  /// Dark by default (WhatsApp's look); Settings → Theme changes it
  ThemeMode themeMode = ThemeMode.dark;
  bool soundOn = true;
  bool deviceNotificationsOn = true;

  /// Push notifications (lib/core/push.dart): told when someone is signed in, just before signing out (while the
  /// token still works), and when Settings → Notifications → Phone notifications changes
  void Function()? onSignedIn;
  /// A chat was marked read on the server (opened here): the unread total (Chats tab, app icon) follows
  void Function()? onConversationRead;
  Future<void> Function()? beforeSignOut;
  void Function(bool on)? onDeviceNotificationsChanged;

  bool get isAdmin => role == 'owner' || role == 'admin';
  bool get isSupervisorOrAbove => isAdmin || role == 'supervisor';

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    server = prefs.getString(_serverKey) ?? builtInServer;
    soundOn = prefs.getBool(_soundKey) ?? true;
    deviceNotificationsOn = prefs.getBool(_notifyKey) ?? true;
    themeMode = ThemeMode.values.where((m) => m.name == prefs.getString(_themeKey)).firstOrNull ?? ThemeMode.dark;
    api.baseUrl = server;
    String? token;
    try {
      // Some emulators/phones answer the keystore slowly: never hold the first screen for it
      token = await _storage.read(key: _tokenKey).timeout(const Duration(seconds: 8));
    } catch (_) {
      token = null; // keystore reset (e.g. app data restored to a new phone) or no answer: sign in again
    }
    if (token == null || server.isEmpty) {
      state = SessionState.signedOut;
      notifyListeners();
      return;
    }
    api.token = token;
    try {
      await refreshMe().timeout(const Duration(seconds: 12));
      _connect();
      state = SessionState.signedIn;
    } on NetworkException {
      // Offline at start: keep the session; screens show their own retry
      state = SessionState.signedIn;
      _connect();
    } on TimeoutException {
      // A slow server is not a signed-out user: keep the session, the screens retry
      state = SessionState.signedIn;
      _connect();
    } catch (_) {
      await _clearToken();
      state = SessionState.signedOut;
    }
    notifyListeners();
    if (state == SessionState.signedIn) onSignedIn?.call();
  }

  /// Developer-only server change (hidden gesture on the sign-in screen); empty = back to the built-in address
  Future<void> setServer(String raw) async {
    final s = raw.trim().isEmpty ? builtInServer : normalizeServer(raw);
    server = s;
    api.baseUrl = s;
    final prefs = await SharedPreferences.getInstance();
    if (raw.trim().isEmpty) {
      await prefs.remove(_serverKey);
    } else {
      await prefs.setString(_serverKey, s);
    }
    notifyListeners();
  }

  Future<void> signIn(String serverAddress, String email, String password) async {
    final s = normalizeServer(serverAddress);
    if (s.isEmpty) throw ApiException('This app has no server address. Build it with --dart-define=API_BASE_URL=https://your-support-site.');
    api.baseUrl = s;
    api.token = null;
    final prefs = await SharedPreferences.getInstance();
    final token = await repo.login(email.trim(), password, workspaceId: prefs.getString(_lastWorkspaceKey));
    server = s;
    await _useToken(token);
  }

  Future<void> switchWorkspace(String id) async {
    final token = await repo.switchWorkspace(id);
    await _useToken(token);
  }

  /// changeMyPassword returns a fresh token for this session (others are signed out)
  Future<void> useToken(String token) => _useToken(token);

  Future<void> _useToken(String token) async {
    api.token = token;
    await _storage.write(key: _tokenKey, value: token);
    await refreshMe();
    final prefs = await SharedPreferences.getInstance();
    if (workspaceId != null) await prefs.setString(_lastWorkspaceKey, workspaceId!);
    signOutReason = null;
    _connect();
    state = SessionState.signedIn;
    notifyListeners();
    onSignedIn?.call();
  }

  void _connect() {
    if (api.token != null && server.isNotEmpty) realtime.connect(server, api.token!);
  }

  Future<void> refreshMe() async {
    final me = await repo.me();
    final user = me['user'] as Map;
    final ws = me['workspace'] as Map;
    userId = user['id'];
    userName = user['name'] ?? '';
    userEmail = user['email'] ?? '';
    phone = user['phone'];
    jobTitle = user['jobTitle'];
    workspaceId = ws['id'];
    workspaceName = ws['name'] ?? '';
    whatsappPhone = (ws['whatsapp'] as Map?)?['displayPhone'];
    businessDayStartHour = ((ws['settings'] as Map?)?['businessDayStartHour'] as num?)?.toInt() ?? 9;
    role = me['role'] ?? 'agent';
    canManageLabels = me['canManageLabels'] == true;
    canManageAssignments = me['canManageAssignments'] == true;
    notifyListeners();
  }

  Future<void> setSound(bool v) async {
    soundOn = v;
    (await SharedPreferences.getInstance()).setBool(_soundKey, v);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_themeKey, m.name);
  }

  Future<void> setDeviceNotifications(bool v) async {
    deviceNotificationsOn = v;
    (await SharedPreferences.getInstance()).setBool(_notifyKey, v);
    notifyListeners();
    onDeviceNotificationsChanged?.call(v);
  }

  /// The signed-in person's unread total, straight from the server, for a push handled while the app is in the
  /// background or closed (no Session there). Null when nobody is signed in or the server can't be reached.
  static Future<int?> unreadTotalInBackground() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final server = prefs.getString(_serverKey) ?? builtInServer;
    final token = await const FlutterSecureStorage().read(key: _tokenKey).timeout(const Duration(seconds: 8));
    if (token == null || server.isEmpty) return null;
    final api = Api(baseUrl: server)..token = token;
    return Repo(api).unreadTotal().timeout(const Duration(seconds: 15));
  }

  Future<void> _clearToken() async {
    api.token = null;
    try {
      await _storage.delete(key: _tokenKey);
    } catch (_) {}
  }

  Future<void> signOut({String? reason}) async {
    if (state == SessionState.signedOut) return;
    try {
      await beforeSignOut?.call();
    } catch (_) {}
    if (state == SessionState.signedOut) return; // signed out meanwhile
    realtime.disconnect();
    await _clearToken();
    userId = null;
    workspaceId = null;
    signOutReason = reason;
    state = SessionState.signedOut;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    realtime.disconnect();
    super.dispose();
  }
}
