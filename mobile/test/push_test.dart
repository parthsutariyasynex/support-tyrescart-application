// Push notifications in the app: off without this build's Firebase settings (nothing is registered, the app's own
// background alerts stay on), and a tapped notification's chat is read from its data.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tyrescart_support/core/app_badge.dart';
import 'package:tyrescart_support/core/push.dart';
import 'package:tyrescart_support/core/session.dart';
import 'package:tyrescart_support/state/alerts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no Firebase settings in this build: push is off', () async {
    expect(firebaseOptions(platform: TargetPlatform.android), isNull);
    expect(firebaseOptions(platform: TargetPlatform.iOS), isNull);
    final session = Session();
    final push = Push(session);
    await push.init(); // does nothing (no Firebase)
    await push.signedIn(); // no device registration, no server call
    expect(push.active, isFalse);
    await push.signingOut(); // nothing to remove
  });

  test('a tapped notification opens its chat (from the data the server sends)', () {
    expect(conversationOf({'conversationId': 'c123', 'kind': 'message'}), 'c123');
    expect(conversationOf({'kind': 'message'}), isNull);
    expect(conversationOf({'conversationId': ''}), isNull);
  });

  test('a data-only push is shown from its data (the phone shows nothing for it by itself)', () {
    expect(pushText('Ali', 'Hi', {'title': 'x', 'body': 'y'}), (title: 'Ali', body: 'Hi')); // notification part first
    expect(pushText(null, null, {'title': 'Ali', 'body': 'Hi', 'conversationId': 'c1'}), (title: 'Ali', body: 'Hi'));
    expect(pushText(null, null, {'message': 'Hi'}), (title: 'TyresCart Support', body: 'Hi'));
    expect(pushText(null, ' ', {'conversationId': 'c1', 'kind': 'message'}), isNull); // nothing to show
  });

  test('the icon number is the server\'s unread total, never counted up from pushes', () async {
    var total = 5;
    final shown = <int?>[];
    Future<int?> server() async => total;
    shown.add(await AppBadge.syncFromServer(server)); // 5 unread on the server
    shown.add(await AppBadge.syncFromServer(server)); // the same push delivered twice: still 5, not 6
    total = 2; // two chats read on the website meanwhile
    shown.add(await AppBadge.syncFromServer(server));
    shown.add(await AppBadge.syncFromServer(() async => null)); // signed out: nothing to show, nothing guessed
    shown.add(await AppBadge.syncFromServer(() async => throw Exception('offline'))); // offline: icon left as it was
    expect(shown, [5, 5, 2, null, null]);
  });

  test('a push that arrives with the app open shows only when the live connection missed it', () async {
    final session = Session();
    final alerts = Alerts(session);
    final shown = <AlertBanner>[];
    final sub = alerts.banners.listen(shown.add);
    session.realtime.isConnected = true; // the live connection already alerted: the push is not shown again
    alerts.fromPush('Chat assigned to you', 'Hello', 'c1', 'assigned'); // (no sound: no audio plugin in unit tests)
    session.realtime.isConnected = false; // reconnecting: the push is the only alert, so it shows
    alerts.fromPush('Chat assigned to you', 'Hello again', 'c1', 'assigned');
    alerts.openConversationId = 'c2'; // reading that chat: no pop-up for it
    alerts.fromPush('Mentioned you', 'Hi', 'c2', 'mention');
    await Future<void>.delayed(Duration.zero);
    expect(shown.map((b) => b.body), ['Hello again']);
    expect(shown.single.conversationId, 'c1');
    await sub.cancel();
  });

  test('while push is off, background alerts still come from the app itself', () {
    final alerts = Alerts(Session());
    expect(alerts.pushActive(), isFalse);
  });
}
