import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/media_cache.dart';
import 'core/push.dart';
import 'core/session.dart';
import 'state/alerts.dart';
import 'state/workspace_data.dart';
import 'ui/app.dart';

/// The whole app with its services (also used by the integration tests). It is returned at once, showing a loading
/// screen, and restores the saved sign-in in the background: nothing slow (keystore, notification permission, the
/// server) may hold the first frame, or the phone shows a blank screen.
Future<Widget> buildApp() async {
  final session = Session();
  final alerts = Alerts(session);
  final push = Push(session);
  // Push notifications follow the sign-in; background alerts come from them when they work (never both)
  session.onSignedIn = () => unawaited(push.signedIn());
  session.beforeSignOut = push.signingOut;
  session.onDeviceNotificationsChanged = (on) => unawaited(push.deviceNotificationsChanged(on));
  alerts.pushActive = () => push.active;
  push.onForeground = alerts.fromPush;
  alerts.launchedFrom = push.openFromNotification;
  unawaited(() async {
    try {
      await alerts.init();
    } catch (_) {
      // alerts unavailable: the app still works
    }
    // Before restoring the sign-in: a notification that opened the app is remembered and its chat opened once signed in
    await push.init();
    try {
      await session.restore();
    } catch (_) {
      // Never stay on the loading screen: anything unexpected falls back to signing in
      if (session.state == SessionState.loading) await session.signOut();
    }
  }());
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: session),
      Provider.value(value: alerts),
      Provider.value(value: push),
      Provider(create: (_) => MediaCache(session.api)),
      ChangeNotifierProvider(create: (_) => WorkspaceData(session)),
    ],
    child: const SupportApp(),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(await buildApp());
}
