// The app's Firebase settings (env/prod.json) match the files Firebase gave for this app. Run with the settings:
//   flutter test test/firebase_config_test.dart --dart-define-from-file=env/prod.json
// Without them (a plain `flutter test`) push is off and this only checks that.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tyrescart_support/core/push.dart';

const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

void main() {
  test('Firebase options for Android and iOS come from google-services.json / GoogleService-Info.plist', () async {
    final android = firebaseOptions(platform: TargetPlatform.android);
    final ios = firebaseOptions(platform: TargetPlatform.iOS);
    if (projectId.isEmpty) {
      expect(android, isNull);
      expect(ios, isNull);
      return;
    }
    final g = jsonDecode(File('android/app/google-services.json').readAsStringSync()) as Map;
    final client = (g['client'] as List).first as Map;
    expect(client['client_info']['android_client_info']['package_name'], 'tech.synex.tyrescart_support');
    expect(android, isNotNull);
    expect(android!.projectId, g['project_info']['project_id']);
    expect(android.messagingSenderId, g['project_info']['project_number']);
    expect(android.appId, client['client_info']['mobilesdk_app_id']);
    expect(android.apiKey, client['api_key'][0]['current_key']);

    // plutil turns the plist into JSON (macOS)
    final plist = jsonDecode((await Process.run('plutil', ['-convert', 'json', '-o', '-', 'ios/Runner/GoogleService-Info.plist'])).stdout as String) as Map;
    expect(plist['BUNDLE_ID'], 'tech.synex.tyrescartSupport');
    expect(ios, isNotNull);
    expect(ios!.appId, plist['GOOGLE_APP_ID']);
    expect(ios.apiKey, plist['API_KEY']);
    expect(ios.iosBundleId, plist['BUNDLE_ID']);
    expect(ios.projectId, plist['PROJECT_ID']);
    expect(ios.messagingSenderId, plist['GCM_SENDER_ID']);
  });
}
