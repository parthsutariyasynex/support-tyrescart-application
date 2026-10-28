import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:vivo_badge/vivo_badge.dart';

/// The number on the app's icon (like WhatsApp's): the server's unread customer messages, never a local guess. The app
/// sets it whenever its unread total loads (start, sign-in, workspace switch, new message, chat read, back from the
/// background) and 0 on sign-out; a push that arrives while the app is in the background or closed asks the server
/// again (lib/core/push.dart). iOS and the Android launchers that show counts (Samsung, Xiaomi, Oppo, Vivo, Huawei…)
/// display it; elsewhere Android shows a dot for the notifications instead.
class AppBadge {
  static Future<void> set(int count) async {
    final n = count < 0 ? 0 : count;
    debugPrint('[badge] icon $n');
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        if (await VivoBadge.set(n)) return; // a Vivo / iQOO phone: its launcher's own broadcast
      } catch (_) {}
    }
    try {
      await AppBadgePlus.updateBadge(n);
    } catch (e) {
      debugPrint('[badge] not supported here: $e'); // e.g. tests, or a launcher without counts
    }
  }

  /// A push arrived while the app is in the background or closed: the icon shows the server's unread total. Returns
  /// it, or null when it couldn't be read (signed out, offline): the icon is then left as it was, never guessed.
  static Future<int?> syncFromServer(Future<int?> Function() unreadTotal) async {
    int? n;
    try {
      n = await unreadTotal();
    } catch (e) {
      debugPrint('[badge] unread total unavailable: $e');
    }
    if (n != null) await set(n);
    return n;
  }
}
