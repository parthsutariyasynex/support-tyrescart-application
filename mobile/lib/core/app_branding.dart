import 'package:flutter/services.dart';

import 'session.dart';

/// Central branding (app name and logo asset) corresponding to the active flavor / environment.
class AppBranding {
  static const _dartDefinedName = String.fromEnvironment('APP_NAME');

  /// The active flavor ('live', 'demo', or 'crm').
  static String get flavor {
    // 1. Flutter native appFlavor passed via --flavor
    final f = appFlavor?.trim().toLowerCase();
    if (f != null && f.isNotEmpty) {
      if (f.contains('crm')) return 'crm';
      if (f.contains('demo')) return 'demo';
      if (f.contains('live')) return 'live';
    }

    // 2. Fallback to API_BASE_URL defined in env/*.json
    final url = definedServer.toLowerCase();
    if (url.contains('vision') || url.contains('connect')) return 'live'; // TyresVision CRM
    if (url.contains('crm')) return 'crm';       // TyresCart CRM
    if (url.contains('support')) return 'demo';   // TyresCart Demo

    return 'live';
  }

  /// App display name in UI (e.g., 'TyresVision CRM', 'TyresCart CRM', 'TyresCart Demo').
  static String get appName {
    if (_dartDefinedName.isNotEmpty) return _dartDefinedName;
    return switch (flavor) {
      'live' => 'TyresVision CRM',
      'crm' => 'TyresCart CRM',
      'demo' => 'TyresCart Demo',
      _ => 'TyresVision CRM',
    };
  }

  /// In-app logo asset for the active flavor.
  static String get logoAsset {
    final name = appName.toLowerCase();
    if (name.contains('vision')) return 'assets/icon/launcher_crm.png'; // TyresVision purple logo
    if (name.contains('demo')) return 'assets/icon/launcher_demo.png';   // KL demo logo
    return 'assets/icon/launcher_live.png';                             // TyresCart green logo
  }
}
