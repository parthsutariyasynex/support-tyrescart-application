// Chat screen layout and scrolling on a real device, against a DEVELOPMENT server: empty, short and long conversations,
// a new message arriving while older ones are being read, and the keyboard open.
//
//   flutter drive -d <emulator> --driver=test_driver/integration_test.dart --target=integration_test/chat_scroll_test.dart \
//     --dart-define-from-file=env/dev.json --dart-define=TEST_EMAIL=… --dart-define=TEST_PASSWORD=…
//
// The account's workspace gets a test customer with 40 simulated messages and an empty chat (development servers only).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:tyrescart_support/core/api.dart';
import 'package:tyrescart_support/core/repo.dart';
import 'package:tyrescart_support/core/session.dart';
import 'package:tyrescart_support/main.dart';
import 'package:tyrescart_support/ui/screens/chat_screen.dart';
import 'package:tyrescart_support/ui/screens/home_screen.dart';
import 'package:tyrescart_support/ui/screens/login_screen.dart';
import 'package:tyrescart_support/ui/widgets/chat_tile.dart';

const email = String.fromEnvironment('TEST_EMAIL');
const password = String.fromEnvironment('TEST_PASSWORD');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(WidgetTester tester, Finder f, {int tries = 100}) async {
    for (var i = 0; i < tries && f.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (f.evaluate().isEmpty) await binding.takeScreenshot('failed_wait');
    expect(f, findsWidgets);
  }

  Future<void> settle(WidgetTester tester, [int frames = 8]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // The chat's message list (reversed: offset 0 = newest at the bottom)
  ScrollPosition listPosition(WidgetTester tester) =>
      tester.state<ScrollableState>(find.descendant(of: find.byType(ChatScreen), matching: find.byType(Scrollable)).first).position;

  Future<void> searchChats(WidgetTester tester, String text) async {
    final clear = find.byTooltip('Clear search');
    if (clear.evaluate().isNotEmpty) {
      await tester.tap(clear);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.byKey(const Key('home-search')));
    await tester.enterText(find.byKey(const Key('home-search')), text);
    await tester.pump(const Duration(milliseconds: 500));
  }

  bool onScreen(WidgetTester tester, String text) => find.textContaining(text, findRichText: true).hitTestable().evaluate().isNotEmpty;

  testWidgets('chat screen: empty, short and long conversations; new messages; keyboard', (tester) async {
    await binding.convertFlutterSurfaceToImage();

    // ---------------------------------------------------------------- Test data (development server)
    final api = Api(baseUrl: builtInServer);
    final repo = Repo(api);
    api.token = await repo.login(email, password);
    final stamp = DateTime.now().millisecondsSinceEpoch % 10000000;
    final longWa = '97150${stamp.toString().padLeft(7, '0')}';
    final emptyWa = '97155${stamp.toString().padLeft(7, '0')}';
    Future<void> customerSays(String body) => api.gql(r'mutation S($i: SimulateIncomingInput) { simulateIncomingMessage(input: $i) }', {
          'i': {'waId': longWa, 'name': 'Long Chat $stamp', 'body': body}
        });
    for (var i = 1; i <= 40; i++) {
      await customerSays('Long message $i of the test');
    }
    await repo.startConversation(emptyWa, name: 'Empty Chat $stamp');

    // ---------------------------------------------------------------- Sign in
    await tester.pumpWidget(await buildApp());
    await waitFor(tester, find.byWidgetPredicate((w) => w is LoginScreen || w is HomeScreen));
    if (find.byType(HomeScreen).evaluate().isNotEmpty) {
      // Signed in from an earlier session (maybe another account): start from the sign-in screen
      await tester.element(find.byType(HomeScreen)).read<Session>().signOut();
      await waitFor(tester, find.byType(LoginScreen));
    }
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), password);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await waitFor(tester, find.byType(HomeScreen));
    await waitFor(tester, find.widgetWithText(ChatTile, 'Long Chat $stamp'));

    // ---------------------------------------------------------------- Empty conversation
    await searchChats(tester, 'Empty Chat $stamp');
    await waitFor(tester, find.widgetWithText(ChatTile, 'Empty Chat $stamp'));
    await tester.tap(find.widgetWithText(ChatTile, 'Empty Chat $stamp').first);
    await waitFor(tester, find.byType(ChatScreen));
    await waitFor(tester, find.text('No messages yet'));
    expect(find.byTooltip('Latest messages'), findsNothing);
    await binding.takeScreenshot('chat_empty');
    await tester.tap(find.byTooltip('Back'));
    await settle(tester);

    // ---------------------------------------------------------------- Short conversation: fits, nothing to scroll
    await searchChats(tester, 'Ahmed');
    await waitFor(tester, find.widgetWithText(ChatTile, 'Ahmed Al Mansoori'));
    await tester.tap(find.widgetWithText(ChatTile, 'Ahmed Al Mansoori').first);
    await waitFor(tester, find.byType(ChatScreen));
    await waitFor(tester, find.textContaining('265/65R17'));
    await settle(tester);
    expect(listPosition(tester).maxScrollExtent, lessThanOrEqualTo(0), reason: 'a short chat must not scroll');
    await tester.drag(find.textContaining('265/65R17').first, const Offset(0, 300));
    await settle(tester);
    expect(listPosition(tester).pixels, 0, reason: 'dragging a short chat moves nothing');
    expect(find.byTooltip('Latest messages'), findsNothing);
    await binding.takeScreenshot('chat_short');
    await tester.tap(find.byTooltip('Back'));
    await settle(tester);

    // ---------------------------------------------------------------- Long conversation: opens at the latest message
    await searchChats(tester, 'Long Chat $stamp');
    await waitFor(tester, find.widgetWithText(ChatTile, 'Long Chat $stamp'));
    await tester.tap(find.widgetWithText(ChatTile, 'Long Chat $stamp').first);
    await waitFor(tester, find.byType(ChatScreen));
    await waitFor(tester, find.textContaining('Long message 40 '));
    await settle(tester);
    expect(onScreen(tester, 'Long message 40 '), isTrue, reason: 'opens at the newest message');
    expect(onScreen(tester, 'Long message 1 '), isFalse);
    expect(listPosition(tester).pixels, 0);
    expect(listPosition(tester).maxScrollExtent, greaterThan(0));
    await binding.takeScreenshot('chat_long_opened');

    // Reading older messages
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(ChatScreen), const Offset(0, 500));
      await settle(tester, 4);
    }
    expect(onScreen(tester, 'Long message 40 '), isFalse);
    await waitFor(tester, find.byTooltip('Latest messages'));
    // Let the drag's glide finish, and make sure the list is standing still before the message arrives
    await settle(tester, 25);
    final reading = List.generate(40, (i) => 'Long message ${i + 1} ').firstWhere((t) => onScreen(tester, t));
    final before = tester.getTopLeft(find.textContaining(reading).first);
    final offsetBefore = listPosition(tester).pixels;
    await settle(tester, 10);
    expect(listPosition(tester).pixels, offsetBefore, reason: 'the list is still before the new message');

    // A new customer message arrives: the view stays put, the button counts it
    await customerSays('Long message 41 of the test');
    await waitFor(tester, find.text('1'));
    await settle(tester);
    expect(tester.getTopLeft(find.textContaining(reading).first).dy, closeTo(before.dy, 2), reason: 'what you are reading does not move');
    // (the offset itself grows by the new row's height: that's what keeps the text still in a list that grows upward)
    expect(listPosition(tester).pixels, greaterThan(offsetBefore));
    expect(onScreen(tester, 'Long message 41 '), isFalse);
    await binding.takeScreenshot('chat_long_new_message_while_reading');

    // Back to the latest
    await tester.tap(find.byTooltip('Latest messages'));
    await settle(tester, 10);
    expect(listPosition(tester).pixels, 0);
    expect(onScreen(tester, 'Long message 41 '), isTrue);
    expect(find.byTooltip('Latest messages'), findsNothing);

    // At the bottom, a new message simply shows
    await customerSays('Long message 42 of the test');
    await waitFor(tester, find.textContaining('Long message 42 '));
    await settle(tester);
    expect(onScreen(tester, 'Long message 42 '), isTrue);
    expect(listPosition(tester).pixels, 0);

    // ---------------------------------------------------------------- Keyboard open, a long text: header and composer stay, nothing overflows
    final box = find.descendant(of: find.byType(ChatScreen), matching: find.byType(TextField)).last;
    await tester.tap(box);
    await tester.enterText(box, List.generate(12, (i) => 'line ${i + 1}').join('\n'));
    await settle(tester, 15);
    expect(tester.takeException(), isNull);
    expect(find.text('Long Chat $stamp'), findsWidgets, reason: 'the header stays at the top');
    expect(onScreen(tester, 'Long message 42 '), isTrue, reason: 'the latest message stays visible above the composer');
    await binding.takeScreenshot('chat_long_keyboard');
    await tester.enterText(box, '');
    await settle(tester);
  });
}
