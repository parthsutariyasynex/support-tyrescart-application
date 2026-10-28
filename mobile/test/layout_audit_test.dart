// Layout audit on a phone-sized screen (411 × 914, like the Pixel emulator), with and without the keyboard: nothing
// overflows, screens whose content fits don't scroll, and with the keyboard open the controls people need (buttons,
// the end of lists) stay above it. No server is needed: screens show their loading/error states where they fetch.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tyrescart_support/core/media_cache.dart';
import 'package:tyrescart_support/core/session.dart';
import 'package:tyrescart_support/models/models.dart';
import 'package:tyrescart_support/state/chat_controller.dart';
import 'package:tyrescart_support/state/workspace_data.dart';
import 'package:tyrescart_support/ui/screens/chat_sheets.dart';
import 'package:tyrescart_support/ui/screens/filter_sheet.dart';
import 'package:tyrescart_support/ui/screens/login_screen.dart';
import 'package:tyrescart_support/ui/screens/new_chat_sheet.dart';
import 'package:tyrescart_support/ui/screens/template_sheet.dart';
import 'package:tyrescart_support/ui/settings/settings_screen.dart';
import 'package:tyrescart_support/ui/theme.dart';
import 'package:tyrescart_support/ui/widgets/common.dart';
import 'package:tyrescart_support/core/repo.dart';

const phone = Size(411, 914);
const keyboard = 330.0; // Gboard on the emulator, in logical pixels

late Session session;

Widget app(Widget home) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        Provider(create: (_) => MediaCache(session.api)),
        ChangeNotifierProvider(create: (_) => WorkspaceData(session)),
      ],
      child: MaterialApp(theme: buildTheme(Brightness.dark), scrollBehavior: const FitScrollBehavior(), home: home),
    );

Future<void> setScreen(WidgetTester tester, {bool keyboardOpen = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = phone;
  tester.view.viewInsets = keyboardOpen ? const FakeViewPadding(bottom: keyboard) : FakeViewPadding.zero;
  addTearDown(tester.view.reset);
}

/// Opens [sheet] the way the app does (scroll-controlled modal bottom sheet) from a plain page
Future<void> openSheet(WidgetTester tester, Widget sheet) async {
  await tester.pumpWidget(app(Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => sheet),
          child: const Text('open'),
        ),
      ),
    ),
  )));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
}

/// The visible bottom of a widget, in screen coordinates
double bottomOf(WidgetTester tester, Finder f) => tester.getBottomLeft(f.first).dy;

void main() {
  setUp(() => session = Session());

  group('keyboard open: controls stay above the keyboard, nothing overflows', () {
    testWidgets('sign-in', (tester) async {
      await setScreen(tester, keyboardOpen: true);
      await tester.pumpWidget(app(const LoginScreen()));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('new chat sheet', (tester) async {
      await setScreen(tester, keyboardOpen: true);
      await openSheet(tester, const NewChatSheet());
      expect(tester.takeException(), isNull);
      expect(bottomOf(tester, find.text('Start chat')), lessThanOrEqualTo(phone.height - keyboard));
    });

    testWidgets('country picker (search field opens the keyboard)', (tester) async {
      await setScreen(tester, keyboardOpen: true);
      await openSheet(tester, const CountryPicker());
      expect(tester.takeException(), isNull);
      // the end of the list must be reachable above the keyboard
      expect(bottomOf(tester, find.byType(ListView)), lessThanOrEqualTo(phone.height - keyboard + 1));
    });

    testWidgets('forward sheet (search field)', (tester) async {
      await setScreen(tester, keyboardOpen: true);
      await openSheet(tester, ForwardSheet(message: Message.fromJson({'id': 'm', 'conversationId': 'c', 'direction': 'in', 'type': 'text', 'body': 'hi', 'status': 'received', 'createdAt': '2026-10-24T10:00:00Z', 'version': 0})));
      expect(tester.takeException(), isNull);
      expect(bottomOf(tester, find.widgetWithText(FilledButton, 'Forward')), lessThanOrEqualTo(phone.height - keyboard));
    });

    testWidgets('assign sheet (reason field)', (tester) async {
      await setScreen(tester, keyboardOpen: true);
      await openSheet(tester, AssignSheet(chat: ChatController(session, 'c')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('template list (search field)', (tester) async {
      await setScreen(tester, keyboardOpen: true);
      final chat = ChatController(session, 'c');
      await tester.pumpWidget(app(Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () => chooseTemplate(context, chat), child: const Text('open'))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
      expect(bottomOf(tester, find.byType(TextField)), lessThanOrEqualTo(phone.height - keyboard));
      // the sheet (and the end of its list) sits above the keyboard
      expect(bottomOf(tester, find.byType(FutureBuilder<List<MessageTemplate>>)), lessThanOrEqualTo(phone.height - keyboard + 1));
    });

    testWidgets('text prompt dialog with a long text', (tester) async {
      await setScreen(tester, keyboardOpen: true);
      await tester.pumpWidget(app(Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => promptText(context, 'Reply outside working hours', initial: List.generate(10, (i) => 'Line $i of the reply').join('\n'), maxLines: 6, maxLength: 1000),
            child: const Text('open'),
          ),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(bottomOf(tester, find.text('Save')), lessThanOrEqualTo(phone.height - keyboard));
    });
  });

  group('content that fits does not scroll', () {
    testWidgets('sign-in without the keyboard', (tester) async {
      await setScreen(tester);
      await tester.pumpWidget(app(const LoginScreen()));
      await tester.pump();
      final s = tester.state<ScrollableState>(find.byType(Scrollable).first);
      expect(s.position.maxScrollExtent, 0);
    });

    testWidgets('profile form without the keyboard', (tester) async {
      await setScreen(tester);
      await tester.pumpWidget(app(const ProfileScreen()));
      await tester.pump();
      expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent, 0);
    });

    testWidgets('filter sheet', (tester) async {
      await setScreen(tester);
      await openSheet(tester, const FilterSheet(query: ConversationQuery()));
      expect(tester.takeException(), isNull);
    });
  });

  bool stretched(WidgetTester tester) =>
      find.byType(Transform).evaluate().any((e) => (e.widget as Transform).transform.getMaxScaleOnAxis() > 1.0001);

  testWidgets('a list that fits does not stretch when dragged; a long list keeps the effect', (tester) async {
    await setScreen(tester);
    await tester.pumpWidget(app(Scaffold(body: ListView(children: const [ListTile(title: Text('one')), ListTile(title: Text('two'))]))));
    final g = await tester.startGesture(tester.getCenter(find.text('one')));
    await g.moveBy(const Offset(0, 250));
    await tester.pump(const Duration(milliseconds: 50));
    expect(stretched(tester), isFalse, reason: 'a short list stretched');
    await g.up();
    await tester.pumpAndSettle();

    await tester.pumpWidget(app(Scaffold(body: ListView(children: [for (var i = 0; i < 60; i++) ListTile(title: Text('row $i'))]))));
    final g2 = await tester.startGesture(tester.getCenter(find.text('row 2')));
    await g2.moveBy(const Offset(0, 250));
    await tester.pump(const Duration(milliseconds: 50));
    expect(stretched(tester), isTrue, reason: 'a long list should keep the usual stretch at its top');
    await g2.up();
    await tester.pumpAndSettle();
  });
}
