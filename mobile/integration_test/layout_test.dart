// Layout on a real device with the real keyboard, against a DEVELOPMENT server: sheets with a search field stay above
// the keyboard, and screens whose content fits don't stretch when dragged.
//
//   flutter drive -d <emulator> --driver=test_driver/integration_test.dart --target=integration_test/layout_test.dart \
//     --dart-define-from-file=env/dev.json --dart-define=TEST_EMAIL=… --dart-define=TEST_PASSWORD=…
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:tyrescart_support/core/session.dart';
import 'package:tyrescart_support/logic/countries.dart';
import 'package:tyrescart_support/main.dart';
import 'package:tyrescart_support/models/models.dart';
import 'package:tyrescart_support/ui/screens/chat_screen.dart';
import 'package:tyrescart_support/ui/screens/home_screen.dart';
import 'package:tyrescart_support/ui/screens/login_screen.dart';
import 'package:tyrescart_support/ui/screens/new_chat_sheet.dart';
import 'package:tyrescart_support/ui/widgets/chat_tile.dart';

const email = String.fromEnvironment('TEST_EMAIL');
const password = String.fromEnvironment('TEST_PASSWORD');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(WidgetTester tester, Finder f) async {
    for (var i = 0; i < 100 && f.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (f.evaluate().isEmpty) await binding.takeScreenshot('layout_failed_wait');
    expect(f, findsWidgets);
  }

  Future<void> settle(WidgetTester tester, [int frames = 10]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Where the keyboard starts (screen coordinates), once it is up
  Future<double> keyboardTop(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      final view = tester.view;
      final inset = view.viewInsets.bottom / view.devicePixelRatio;
      if (inset > 0) return view.physicalSize.height / view.devicePixelRatio - inset;
      await tester.pump(const Duration(milliseconds: 200));
    }
    fail('the keyboard did not open');
  }

  bool stretched() => find.byType(Transform).evaluate().any((e) => (e.widget as Transform).transform.getMaxScaleOnAxis() > 1.0001);

  Future<void> dragAndCheckNoStretch(WidgetTester tester, Finder target, String what) async {
    final g = await tester.startGesture(tester.getCenter(target.first));
    await g.moveBy(const Offset(0, 120));
    await g.moveBy(const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 60));
    final s = stretched();
    await g.up();
    await settle(tester, 6);
    expect(s, isFalse, reason: '$what stretched although its content fits');
  }

  testWidgets('sheets stay above the real keyboard; fitting screens do not stretch', (tester) async {
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpWidget(await buildApp());
    await waitFor(tester, find.byWidgetPredicate((w) => w is LoginScreen || w is HomeScreen));
    if (find.byType(HomeScreen).evaluate().isNotEmpty) {
      await tester.element(find.byType(HomeScreen)).read<Session>().signOut();
      await waitFor(tester, find.byType(LoginScreen));
    }
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), password);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await waitFor(tester, find.byType(ChatTile));

    // ---------------------------------------------------------------- New chat → country picker (search opens the keyboard)
    await tester.tap(find.byTooltip('New chat'));
    await waitFor(tester, find.text('Start chat'));
    await tester.tap(find.byType(OutlinedButton).first); // the 🇦🇪 +971 button
    await waitFor(tester, find.byType(CountryPicker));
    final top1 = await keyboardTop(tester);
    await settle(tester);
    final list = find.descendant(of: find.byType(CountryPicker), matching: find.byType(ListView));
    expect(tester.getBottomLeft(list).dy, lessThanOrEqualTo(top1 + 1), reason: 'the country list ends behind the keyboard');
    // the last country can be reached
    await tester.scrollUntilVisible(find.text(phoneCountryLastName()), 300, scrollable: find.descendant(of: list, matching: find.byType(Scrollable)));
    expect(tester.getBottomLeft(find.text(phoneCountryLastName())).dy, lessThanOrEqualTo(top1 + 1));
    await binding.takeScreenshot('layout_country_picker_keyboard');
    await tester.tap(find.text(phoneCountryLastName()));
    await settle(tester);
    Navigator.of(tester.element(find.text('Start chat'))).pop();
    await settle(tester);

    // ---------------------------------------------------------------- A short chat: drag doesn't stretch
    await tester.tap(find.byKey(const Key('home-search')));
    await tester.enterText(find.byKey(const Key('home-search')), 'Ahmed');
    await waitFor(tester, find.widgetWithText(ChatTile, 'Ahmed Al Mansoori'));
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);
    await tester.tap(find.widgetWithText(ChatTile, 'Ahmed Al Mansoori'));
    await waitFor(tester, find.byType(ChatScreen));
    await waitFor(tester, find.textContaining('265/65R17'));
    await settle(tester);
    await dragAndCheckNoStretch(tester, find.textContaining('265/65R17'), 'a short chat');

    // ---------------------------------------------------------------- Forward sheet: search + Forward button above the keyboard
    await tester.longPress(find.textContaining('265/65R17').first);
    await settle(tester);
    await tester.tap(find.text('Forward'));
    await waitFor(tester, find.text('Forward to…'));
    await tester.tap(find.widgetWithText(TextField, 'Search chats'));
    final top2 = await keyboardTop(tester);
    await settle(tester);
    expect(tester.getBottomLeft(find.widgetWithText(FilledButton, 'Forward')).dy, lessThanOrEqualTo(top2 + 1), reason: 'Forward button behind the keyboard');
    await binding.takeScreenshot('layout_forward_keyboard');
    Navigator.of(tester.element(find.text('Forward to…'))).pop();
    await settle(tester);

    // ---------------------------------------------------------------- Template list: search + list above the keyboard
    await tester.tap(find.byTooltip('Template'));
    await waitFor(tester, find.text('Templates'));
    await tester.tap(find.widgetWithText(TextField, 'Search templates'));
    final top3 = await keyboardTop(tester);
    await settle(tester);
    expect(tester.getBottomLeft(find.byType(FutureBuilder<List<MessageTemplate>>)).dy, lessThanOrEqualTo(top3 + 1), reason: 'template list behind the keyboard');
    await binding.takeScreenshot('layout_templates_keyboard');
    Navigator.of(tester.element(find.text('Templates'))).pop();
    await settle(tester);
    await tester.tap(find.byTooltip('Back'));
    await settle(tester);

    // ---------------------------------------------------------------- Short home tabs don't stretch
    await tester.tap(find.text('Updates'));
    await settle(tester);
    await dragAndCheckNoStretch(tester, find.text('Updates').first, 'Updates');
    await tester.tap(find.text('Calls'));
    await waitFor(tester, find.text('Call a customer from this phone'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });
}

/// The last entry of the country list, read from the app's own list so the test follows it
String phoneCountryLastName() => phoneCountries.last.name;
