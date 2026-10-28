// The sign-in screen as a production app shows it: no server address anywhere, and a build without API_BASE_URL signs in
// to the built-in (live) server without being told. Run without API_BASE_URL:
//
//   flutter drive -d <emulator> --driver=test_driver/integration_test.dart --target=integration_test/login_test.dart \
//     --dart-define=TEST_EMAIL=… --dart-define=TEST_PASSWORD=…
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tyrescart_support/core/session.dart';
import 'package:tyrescart_support/main.dart';
import 'package:tyrescart_support/ui/screens/home_screen.dart';
import 'package:tyrescart_support/ui/screens/login_screen.dart';

const email = String.fromEnvironment('TEST_EMAIL');
const password = String.fromEnvironment('TEST_PASSWORD');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(WidgetTester tester, Finder f) async {
    for (var i = 0; i < 100 && f.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(f, findsWidgets);
  }

  testWidgets('login screen: no server address shown; debug build reaches the dev server', (tester) async {
    // Without API_BASE_URL a debug build uses the emulator's route to this computer; with it (env/dev.json), that address
    expect(builtInServer, definedServer.isEmpty ? liveServer : definedServer);
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpWidget(await buildApp());
    await waitFor(tester, find.byType(LoginScreen));
    await tester.pump(const Duration(milliseconds: 500));
    await binding.takeScreenshot('login_clean');

    // Only the normal sign-in UI
    expect(find.textContaining('Server'), findsNothing);
    expect(find.textContaining(builtInServer), findsNothing);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.widgetWithText(TextFormField, 'Email'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);

    // Developer-only gesture: long-press the logo
    await tester.longPress(find.byKey(const Key('login-logo')));
    await waitFor(tester, find.text('Server (developer)'));
    expect(find.widgetWithText(TextField, builtInServer), findsOneWidget);
    await binding.takeScreenshot('login_developer_server');
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Server (developer)'), findsNothing);

    // Sign in through the built-in address
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), password);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await waitFor(tester, find.byType(HomeScreen));
    await tester.pump(const Duration(seconds: 1));
    await binding.takeScreenshot('signed_in');
  });
}
