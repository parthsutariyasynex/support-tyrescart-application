// AI Assistant in the app (repo.dart + ui/screens/ai_sheets.dart): only the server's existing GraphQL calls, the same as
// the website's client/lib/ai.ts. A fake Api answers here: nothing reaches a server or an AI service.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tyrescart_support/core/api.dart';
import 'package:tyrescart_support/core/repo.dart';
import 'package:tyrescart_support/ui/screens/ai_sheets.dart';

class FakeApi extends Api {
  FakeApi(this.answer) : super(baseUrl: 'https://test.example');
  final Map<String, dynamic> Function(String query, Map<String, dynamic>? variables) answer;
  final calls = <({String query, Map<String, dynamic>? variables})>[];

  @override
  Future<Map<String, dynamic>> gql(String query, [Map<String, dynamic>? variables]) async {
    calls.add((query: query, variables: variables));
    return answer(query, variables);
  }
}

const _summary = {
  'id': '7',
  'conversationId': 'c1',
  'summary': 'Customer wants 205/55 R16 tyres',
  'lastMessageId': 'm9',
  'createdAt': '2026-10-30T08:00:00.000Z',
  'updatedAt': '2026-10-30T09:30:00.000Z',
  'createdByName': 'Asha',
  'updatedByName': 'Ravi',
  'upToDate': false,
  'addedMessages': 0,
};

void main() {
  group('aiConfigured', () {
    test('asked once per server; the AI chips show only when it says yes', () async {
      final api = FakeApi((_, _) => {'aiConfigured': true});
      final repo = Repo(api);
      expect(await repo.aiConfigured(), isTrue);
      expect(await repo.aiConfigured(), isTrue);
      expect(api.calls, hasLength(1));
      api.baseUrl = 'https://other.example';
      await repo.aiConfigured();
      expect(api.calls, hasLength(2), reason: 'another server is asked again');
    });

    test('a server without the AI Assistant counts as off, and is asked again next time', () async {
      var fail = true;
      final api = FakeApi((_, _) => fail ? throw ApiException('Cannot query field "aiConfigured"', code: 'GRAPHQL_VALIDATION_FAILED') : {'aiConfigured': true});
      final repo = Repo(api);
      expect(await repo.aiConfigured(), isFalse);
      fail = false;
      expect(await repo.aiConfigured(), isTrue);
    });
  });

  group('AI Summary', () {
    test('the saved summary is read with the fields the sheet shows', () async {
      final api = FakeApi((_, _) => {'conversationSummary': _summary});
      final s = await Repo(api).conversationSummary('c1');
      expect(api.calls.single.variables, {'conversationId': 'c1'});
      expect(s!.summary, 'Customer wants 205/55 R16 tyres');
      expect(s.updatedByName, 'Ravi');
      expect(s.upToDate, isFalse);
      expect(s.addedMessages, 0);
      expect(s.updatedAt, DateTime.utc(2026, 10, 30, 9, 30));
    });

    test('none yet: null', () async {
      expect(await Repo(FakeApi((_, _) => {'conversationSummary': null})).conversationSummary('c1'), isNull);
    });

    test('Generate / Regenerate uses the server mutation', () async {
      final api = FakeApi((_, _) => {'generateConversationSummary': {..._summary, 'upToDate': true, 'addedMessages': 4}});
      final s = await Repo(api).generateConversationSummary('c1');
      expect(api.calls.single.query, contains('generateConversationSummary(conversationId: \$conversationId)'));
      expect(s.addedMessages, 4);
      expect(s.upToDate, isTrue);
    });
  });

  group('AI Reply', () {
    test('a suggestion only: suggestReply returns text, nothing is sent', () async {
      final api = FakeApi((_, _) => {'suggestReply': 'Thanks, we will check the price for you.'});
      expect(await Repo(api).suggestReply('c1'), 'Thanks, we will check the price for you.');
      expect(api.calls.single.query, isNot(contains('sendTextMessage')));
    });

    test('sent after confirming: marked aiGenerated; an ordinary reply is not', () async {
      final api = FakeApi((_, _) => {
            'sendTextMessage': {'id': 'm1', 'conversationId': 'c1', 'direction': 'out', 'type': 'text', 'body': 'Hi', 'status': 'sent', 'createdAt': '2026-10-30T09:30:00.000Z'},
          });
      final repo = Repo(api);
      await repo.sendText('c1', 'Hi', aiGenerated: true);
      await repo.sendText('c1', 'Hi');
      expect((api.calls[0].variables!['input'] as Map)['aiGenerated'], isTrue);
      expect((api.calls[1].variables!['input'] as Map).containsKey('aiGenerated'), isFalse);
    });

    testWidgets('"Send this AI reply?" shows the exact text; Send or Edit first', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(onPressed: () async => result = await confirmAiSend(context, 'Thanks, we will check.'), child: const Text('open')),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Send this AI reply?'), findsOneWidget);
      expect(find.text('Thanks, we will check.'), findsOneWidget);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(result, isTrue);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit first'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });
}
