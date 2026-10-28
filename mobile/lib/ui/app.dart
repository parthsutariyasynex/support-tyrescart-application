import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_badge.dart';
import '../core/media_cache.dart';
import '../core/push.dart';
import '../core/session.dart';
import '../state/alerts.dart';
import '../state/workspace_data.dart';
import 'screens/chat_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'theme.dart';
import 'widgets/common.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// Opens a chat from anywhere (a pop-up, a notification, the bell)
void openChat(String conversationId) {
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  nav.popUntil((r) => r.isFirst);
  nav.push(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: conversationId)));
}

class SupportApp extends StatefulWidget {
  const SupportApp({super.key});
  @override
  State<SupportApp> createState() => _SupportAppState();
}

class _SupportAppState extends State<SupportApp> {
  StreamSubscription? _bannerSub;
  String? _loadedFor;
  DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    final alerts = context.read<Alerts>();
    alerts.openChat = openChat;
    context.read<Push>().openChat = openChat; // a tapped push notification opens its chat
    _bannerSub = alerts.banners.listen(_showBanner);
  }

  OverlayEntry? _toast;
  Timer? _toastTimer;

  void _hideToast() {
    _toastTimer?.cancel();
    _toast?.remove();
    _toast = null;
  }

  /// A pop-up floating over the top of the screen (like WhatsApp's in-app notification). It never moves the layout
  /// underneath, so it can't make someone tap the wrong thing while they're typing.
  void _showBanner(AlertBanner b) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _hideToast();
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
            child: Dismissible(
              key: UniqueKey(),
              direction: DismissDirection.up,
              onDismissed: (_) {
                _toast = null;
                _toastTimer?.cancel();
              },
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(14),
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    _hideToast();
                    if (b.conversationId != null) openChat(b.conversationId!);
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                    child: Row(children: [
                      const CircleAvatar(radius: 18, backgroundColor: waAccent, child: Icon(Icons.chat_bubble, color: Colors.white, size: 18)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(b.title, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (b.body.isNotEmpty) Text(b.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                        ]),
                      ),
                      IconButton(tooltip: 'Dismiss', onPressed: _hideToast, icon: const Icon(Icons.close, size: 20)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _toast = entry;
    overlay.insert(entry);
    _toastTimer = Timer(const Duration(seconds: 5), _hideToast);
  }

  @override
  void dispose() {
    _bannerSub?.cancel();
    _hideToast();
    super.dispose();
  }

  /// Any touch counts as activity for the online/away dot (at most one event a minute)
  void _activity() {
    final now = DateTime.now();
    if (now.difference(_lastActivity) < const Duration(minutes: 1)) return;
    _lastActivity = now;
    context.read<Session>().realtime.emit('presence:activity');
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    // Workspace lists load once per signed-in workspace
    if (session.state == SessionState.signedIn && _loadedFor != session.workspaceId) {
      _loadedFor = session.workspaceId;
      context.read<MediaCache>().clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => context.read<WorkspaceData>().refreshAll());
    }
    if (session.state != SessionState.signedIn) _loadedFor = null;
    if (session.state == SessionState.signedOut) unawaited(AppBadge.set(0)); // nobody signed in: no count on the icon

    return Listener(
      onPointerDown: (_) => _activity(),
      child: MaterialApp(
        title: 'TyresCart Support',
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: session.themeMode,
        scrollBehavior: const FitScrollBehavior(),
        home: switch (session.state) {
          SessionState.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
          SessionState.signedOut => const LoginScreen(),
          SessionState.signedIn => HomeScreen(key: ValueKey(session.workspaceId)),
        },
      ),
    );
  }
}
