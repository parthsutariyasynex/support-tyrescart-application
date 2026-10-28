import 'package:flutter/services.dart';

/// The app icon's number on Vivo / iQOO phones (does nothing elsewhere). Works in the background isolate too.
class VivoBadge {
  static const _channel = MethodChannel('tech.synex/vivo_badge');

  /// Sets the number; returns whether this is a Vivo phone (the broadcast was sent)
  static Future<bool> set(int count) async => await _channel.invokeMethod<bool>('set', {'count': count}) ?? false;
}
