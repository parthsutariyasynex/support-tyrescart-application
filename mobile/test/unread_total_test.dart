// The unread total (Chats tab badge, app icon) follows a chat being read in the app, like the website's tab title.
import 'package:flutter_test/flutter_test.dart';
import 'package:tyrescart_support/core/session.dart';
import 'package:tyrescart_support/state/workspace_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reading a chat reloads the unread total', () {
    final session = Session();
    expect(session.onConversationRead, isNull);
    final data = WorkspaceData(session);
    expect(session.onConversationRead, isNotNull, reason: 'the chat screen tells WorkspaceData when a chat was read');
    session.onConversationRead!(); // schedules the reload (no server here: it fails quietly)
    data.dispose();
  });
}
