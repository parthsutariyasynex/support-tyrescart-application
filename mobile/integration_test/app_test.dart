// End-to-end test of the real app on a phone or emulator against a development server, driven by widgets (not screen
// coordinates). Run it with tool/e2e.sh, which creates a throwaway workspace with a few simulated customer chats.
//
// Needs: --dart-define=API_BASE_URL=… TEST_EMAIL=… TEST_PASSWORD=…
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tyrescart_support/main.dart';
import 'package:tyrescart_support/ui/screens/chat_screen.dart';
import 'package:tyrescart_support/ui/screens/contact_screen.dart';
import 'package:tyrescart_support/ui/screens/home_screen.dart';
import 'package:tyrescart_support/ui/screens/login_screen.dart';
import 'package:tyrescart_support/ui/widgets/bubbles.dart';

const email = String.fromEnvironment('TEST_EMAIL');
const password = String.fromEnvironment('TEST_PASSWORD');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var shots = 0;

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 300));
    await binding.takeScreenshot('${(++shots).toString().padLeft(2, '0')}_$name');
  }

  /// Pumps frames until [finder] matches (spinners never "settle", so pumpAndSettle can't be used)
  Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isNotEmpty) return;
    }
    await binding.takeScreenshot('timeout_${shots + 1}');
    throw TestFailure('Timed out waiting for $finder');
  }

  Future<void> waitGone(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isEmpty) return;
    }
    throw TestFailure('Still showing $finder');
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await waitFor(tester, f);
    await tester.ensureVisible(f.first);
    await tester.tap(f.first);
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Taps an item further down the visible list (lists only build what's on screen)
  Future<void> tapInList(WidgetTester tester, Finder f) async {
    final list = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable().first;
    await tester.scrollUntilVisible(f, 250, scrollable: list);
    await tap(tester, f);
  }

  Future<void> chatMenu(WidgetTester tester, String item) async {
    await tap(tester, find.byTooltip('Show menu'));
    await tap(tester, find.text(item));
    await waitGone(tester, find.byType(PopupMenuItem<String>)); // the menu has closed and run the action
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('support app end to end', (tester) async {
    expect(email, isNotEmpty, reason: 'pass --dart-define=TEST_EMAIL=…');
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpWidget(await buildApp());
    // The saved sign-in is restored in the background: wait for the sign-in screen or the chats
    await waitFor(tester, find.byWidgetPredicate((w) => w is LoginScreen || w is HomeScreen));

    // A previous run may still be signed in: start from the sign-in screen
    if (find.byType(HomeScreen).evaluate().isNotEmpty) {
      await tap(tester, find.text('Tools'));
      await tapInList(tester, find.text('Sign out'));
      await tap(tester, find.widgetWithText(FilledButton, 'Sign out'));
    }

    // ---------------------------------------------------------------- Sign in
    await waitFor(tester, find.byType(LoginScreen));
    await shot(tester, 'login');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), password);
    await tap(tester, find.widgetWithText(FilledButton, 'Sign in'));

    // ---------------------------------------------------------------- Inbox
    await waitFor(tester, find.text('Rahul Mehta'));
    await waitFor(tester, find.text('Sarah Johnson'));
    // WhatsApp-style home: title bar with camera and menu, search bar, chips, bottom navigation
    expect(find.text('TyresCart Support'), findsOneWidget);
    expect(find.byTooltip('Camera'), findsOneWidget);
    for (final t in ['Chats', 'Calls', 'Updates', 'Tools', 'All', 'Unread', 'My chats']) {
      expect(find.textContaining(t), findsWidgets, reason: t); // chips may carry a count, e.g. "New leads 4"
    }
    // The rest of the chip row scrolls sideways: the other lists, the lifecycle stages and the statuses
    final chipRow = find.byKey(const Key('home-chips'));
    for (final t in ['New leads', 'Mentions', 'Collaborations', 'Open', 'Snoozed', 'Closed']) {
      final chip = find.descendant(of: chipRow, matching: find.textContaining(t));
      for (var i = 0; i < 12 && chip.evaluate().isEmpty; i++) {
        await tester.drag(chipRow, const Offset(-150, 0));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(chip, findsWidgets, reason: t);
    }
    for (var i = 0; i < 12 && find.descendant(of: chipRow, matching: find.text('All')).evaluate().isEmpty; i++) {
      await tester.drag(chipRow, const Offset(400, 0));
      await tester.pump(const Duration(milliseconds: 300));
    }
    // This test workspace has no WhatsApp number: the banner says so, and can be dismissed
    await waitFor(tester, find.text('No WhatsApp number connected'));
    await shot(tester, 'inbox');
    await tap(tester, find.descendant(of: find.byKey(const Key('home-banner-whatsapp')), matching: find.byTooltip('Dismiss')));
    await waitGone(tester, find.text('No WhatsApp number connected'));

    // Search (applied at once on screen, then by the server)
    await tester.enterText(find.byKey(const Key('home-search')), 'alignment');
    await waitGone(tester, find.text('Rahul Mehta'));
    expect(find.text('Priya Nair'), findsOneWidget);
    await shot(tester, 'search');
    await tap(tester, find.byTooltip('Clear search'));
    await waitFor(tester, find.text('Rahul Mehta'));

    // Filter sheet (three-dot menu) opens with the workspace's real labels/teammates and applies
    await tap(tester, find.byTooltip('Menu'));
    await tap(tester, find.text('Filter by'));
    await waitFor(tester, find.text('Filter by'));
    await shot(tester, 'filters');
    await tap(tester, find.text('Apply'));
    await waitGone(tester, find.text('Filter by'));

    // ---------------------------------------------------------------- Chat
    await tap(tester, find.text('Rahul Mehta'));
    await waitFor(tester, find.byType(ChatScreen));
    await waitFor(tester, find.textContaining('Michelin Pilot Sport 4'));
    await shot(tester, 'chat');

    // Search in this chat
    await chatMenu(tester, 'Search in chat');
    await waitFor(tester, find.byKey(const Key('chat-search')));
    await tester.enterText(find.byKey(const Key('chat-search')), 'pilot sport');
    await waitFor(tester, find.text('1/1'));
    await shot(tester, 'search_in_chat');
    await tap(tester, find.byTooltip('Close search'));

    // Internal note (never sent to WhatsApp)
    await tap(tester, find.text('Add note'));
    await tester.enterText(find.byType(TextField).last, 'Quote him the 225/45R18 price incl. fitting');
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, 'note_typing');
    await tap(tester, find.byIcon(Icons.sticky_note_2));
    await waitFor(tester, find.byType(NoteBubble));
    await waitFor(tester, find.textContaining('Quote him the 225/45R18', findRichText: true));
    await shot(tester, 'note_saved');

    // @mention a teammate: typing @ suggests them, picking one puts "@Name " in the note
    await tap(tester, find.text('Add note'));
    await tester.enterText(find.byType(TextField).last, 'Please call him @Nik');
    await tester.pump(const Duration(milliseconds: 500));
    await waitFor(tester, find.text('Nikhil Shah'));
    await shot(tester, 'mention_suggestions');
    await tap(tester, find.text('Nikhil Shah'));
    expect(find.text('Please call him @Nikhil Shah '), findsOneWidget);
    await tap(tester, find.byIcon(Icons.sticky_note_2));
    await waitFor(tester, find.textContaining('Please call him @Nikhil Shah', findRichText: true));
    await shot(tester, 'mention_saved');

    // Edit a note (long-press → Edit note)
    await tester.longPress(find.textContaining('Quote him the 225/45R18', findRichText: true).first);
    await tester.pump(const Duration(milliseconds: 500));
    await tap(tester, find.text('Edit note'));
    await tester.enterText(find.byType(TextField).last, 'Quote him the 225/45R18 price incl. fitting and balancing');
    await tap(tester, find.byIcon(Icons.check));
    await waitFor(tester, find.textContaining('fitting and balancing', findRichText: true));

    // A customer message's actions (long-press)
    await tester.longPress(find.textContaining('Michelin Pilot Sport 4').first);
    await tester.pump(const Duration(milliseconds: 500));
    await waitFor(tester, find.text('Copy'));
    await shot(tester, 'message_actions');
    await tap(tester, find.text('Copy'));
    await waitGone(tester, find.byType(SnackBar));

    // A reply: this test workspace has no WhatsApp number, so the server refuses and the message shows why
    await tap(tester, find.text('Reply'));
    await tester.enterText(find.byType(TextField).last, 'Hello Rahul, we have it in stock.');
    await tester.pump(const Duration(milliseconds: 300));
    await tap(tester, find.byIcon(Icons.send));
    await waitFor(tester, find.text('Remove'));
    await shot(tester, 'reply_refused_no_whatsapp');
    await tap(tester, find.text('Remove'));

    // Quick replies: "/" lists the workspace's saved replies (none in a new workspace is fine)
    await tester.enterText(find.byType(TextField).last, '/');
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField).last, '');

    // Assign to me
    await chatMenu(tester, 'Assign to me');
    await waitFor(tester, find.text('Assigned to you'));

    // Labels: create one and put it on the chat
    await chatMenu(tester, 'Labels');
    await tap(tester, find.text('New'));
    await tester.enterText(find.byType(TextField).last, 'Price quote');
    await tap(tester, find.text('Create'));
    await waitFor(tester, find.widgetWithText(CheckboxListTile, 'Price quote'));
    await tap(tester, find.widgetWithText(CheckboxListTile, 'Price quote'));
    await waitFor(tester, find.byWidgetPredicate((w) => w is CheckboxListTile && w.value == true));
    await shot(tester, 'labels');
    await tester.tapAt(const Offset(20, 60)); // close the sheet
    await tester.pump(const Duration(milliseconds: 600));

    // Snooze, then unsnooze
    await chatMenu(tester, 'Snooze…');
    await tap(tester, find.text('1 hour'));
    await waitFor(tester, find.textContaining('Snoozed until'));
    await shot(tester, 'snoozed');
    await tap(tester, find.text('Unsnooze'));
    await waitGone(tester, find.text('Unsnooze'));

    // Close, then reopen
    await chatMenu(tester, 'Close chat');
    await waitFor(tester, find.text('This chat is closed.'));
    await tap(tester, find.text('Reopen'));
    await waitGone(tester, find.text('This chat is closed.'));

    // Collaborators sheet loads the team
    await chatMenu(tester, 'Collaborators');
    await waitFor(tester, find.text('No collaborators yet'));
    await tester.tapAt(const Offset(20, 60));
    await tester.pump(const Duration(milliseconds: 600));

    // ---------------------------------------------------------------- Contact info
    await chatMenu(tester, 'Contact info');
    await waitFor(tester, find.byType(ContactScreen));
    await waitFor(tester, find.text('First name'));
    await tap(tester, find.text('First name'));
    await tester.enterText(find.byType(TextField).last, 'Rahul');
    await tap(tester, find.text('Save'));
    await waitFor(tester, find.text('Rahul'));
    await shot(tester, 'contact_info');
    await tap(tester, find.byTooltip('Back'));
    await tap(tester, find.byTooltip('Back'));

    // ---------------------------------------------------------------- Chips: My chats (it's assigned to me now), Unread
    await waitFor(tester, find.byType(HomeScreen));
    await tap(tester, find.text('My chats'));
    await waitFor(tester, find.text('Rahul Mehta'));
    await waitGone(tester, find.text('Sarah Johnson'));
    await shot(tester, 'my_chats');
    await tap(tester, find.text('Unread'));
    await waitFor(tester, find.text('Sarah Johnson'));
    await waitGone(tester, find.text('Rahul Mehta')); // opened, so no longer unread
    await shot(tester, 'unread');
    await tap(tester, find.text('All'));
    await waitFor(tester, find.text('Rahul Mehta'));

    // ---------------------------------------------------------------- Calls: customers, called with the phone's dialer
    await tap(tester, find.text('Calls'));
    await waitFor(tester, find.text('Call a customer from this phone'));
    await waitFor(tester, find.byTooltip('Call Rahul Mehta'));
    await shot(tester, 'calls');

    // ---------------------------------------------------------------- Updates (the bell)
    await tap(tester, find.text('Updates'));
    await tester.pump(const Duration(seconds: 1));
    await shot(tester, 'updates');

    // ---------------------------------------------------------------- Tools
    await tap(tester, find.text('Tools'));
    await waitFor(tester, find.text('User management'));
    await shot(tester, 'tools');

    // ---------------------------------------------------------------- New chat with an existing number opens that chat
    await tap(tester, find.text('Chats'));
    await tap(tester, find.byTooltip('New chat'));
    await waitFor(tester, find.text('Start chat'));
    await tester.enterText(find.widgetWithText(TextField, 'Phone number'), '501112233');
    await shot(tester, 'new_chat');
    await tap(tester, find.text('Start chat'));
    await waitFor(tester, find.byType(ChatScreen));
    await waitFor(tester, find.text('Ahmed Al Mansoori'));
    await shot(tester, 'new_chat_opened_existing');
    await tap(tester, find.byTooltip('Back'));

    // ---------------------------------------------------------------- Settings
    await tap(tester, find.text('Tools'));
    await tapInList(tester, find.text('Settings'));
    await waitFor(tester, find.text('Your preferences'));
    await shot(tester, 'settings');
    await tapInList(tester, find.text('Labels'));
    await waitFor(tester, find.text('Price quote'));
    await tap(tester, find.byTooltip('Back'));
    await tapInList(tester, find.text('User management'));
    await waitFor(tester, find.textContaining('(owner)'));
    await shot(tester, 'team');
    await tap(tester, find.byTooltip('Back'));
    await tap(tester, find.byTooltip('Back'));
    await waitFor(tester, find.byType(HomeScreen));

    // ---------------------------------------------------------------- Theme: dark by default; Light from Settings
    Future<void> setTheme(String label) async {
      await tapInList(tester, find.text('Settings'));
      await tapInList(tester, find.text('Theme'));
      await tap(tester, find.text(label));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100)); // let the theme animation finish
      }
      await tap(tester, find.byTooltip('Back'));
    }

    await tap(tester, find.text('Chats'));
    await tap(tester, find.text('Rahul Mehta'));
    await waitFor(tester, find.byType(NoteBubble));
    await shot(tester, 'dark_chat');
    await tap(tester, find.byTooltip('Back'));
    await tap(tester, find.text('Tools'));
    await setTheme('Light');
    await tap(tester, find.text('Chats'));
    await shot(tester, 'light_inbox');
    await tap(tester, find.text('Tools'));
    await setTheme('Dark');
  });
}
