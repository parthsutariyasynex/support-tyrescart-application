// The same cases as the website's tests (client/lib/*.test.ts), so both apps follow the same rules.
import 'package:flutter_test/flutter_test.dart';
import 'package:tyrescart_support/core/api.dart';
import 'package:tyrescart_support/logic/rules.dart';
import 'package:tyrescart_support/logic/time.dart';
import 'package:tyrescart_support/models/models.dart';

MessageTemplate template({List<String> bodyVariables = const [], List<TemplateButton> buttons = const [], TemplateHeader? header}) => MessageTemplate(
      id: 't',
      name: 't',
      language: 'en',
      category: 'UTILITY',
      status: 'APPROVED',
      parameterFormat: 'POSITIONAL',
      header: header,
      body: '',
      bodyVariables: bodyVariables,
      buttons: buttons,
      needsParameters: bodyVariables.isNotEmpty,
      sendable: true,
    );

Message message({String type = 'text', String body = 'hi', String direction = 'out', String? sentById = 'u1', String status = 'sent', String? mime, DateTime? deletedAt}) =>
    Message.fromJson({
      'id': 'm1',
      'conversationId': 'c1',
      'direction': direction,
      'type': type,
      'body': body,
      'status': status,
      'createdAt': '2026-10-23T10:00:00Z',
      'sentById': sentById,
      'version': 1,
      'mediaMime': mime,
      'deletedAt': deletedAt?.toIso8601String(),
    });

Conversation conversation({String? name = 'Alice Patel', String waId = '971501234567', int unread = 0, String status = 'open', Map<String, dynamic>? assignee, DateTime? lastInboundAt}) =>
    Conversation.fromJson({
      'id': 'c1',
      'contact': {'id': 'k1', 'waId': waId, 'name': name},
      'unread': unread,
      'lastMessageAt': '2026-10-23T10:00:00Z',
      'lastInboundAt': lastInboundAt?.toIso8601String(),
      'lastMessage': {'id': 'm1', 'conversationId': 'c1', 'direction': 'in', 'type': 'text', 'body': 'Need 4 tyres for my Patrol', 'status': 'received', 'createdAt': '2026-10-23T10:00:00Z', 'version': 0},
      'labels': [
        {'id': 'l1', 'name': 'VIP', 'color': '#25d366'}
      ],
      'assignee': assignee,
      'status': status,
      'pinned': false,
      'isCollaborator': false,
      'wasAssigned': assignee != null,
    });

void main() {
  group('24-hour window on the chat screen', () {
    final now = DateTime.parse('2026-10-23T12:00:00Z');
    DateTime ago(double h) => now.subtract(Duration(milliseconds: (h * 3600000).round()));

    test('open within 24 hours of the last customer message, closed after; closed when they never wrote', () {
      expect(windowOpen(ago(23), now), isTrue);
      expect(windowOpen(now.subtract(windowLength), now), isFalse);
      expect(windowOpen(ago(30), now), isFalse);
      expect(windowOpen(null, now), isFalse);
    });

    test('time left until it closes, for the timer that switches the box to templates', () {
      expect(timeUntilClose(ago(23), now), const Duration(hours: 1));
      expect(timeUntilClose(ago(25), now), isNull);
      expect(timeUntilClose(null, now), isNull);
    });

    test('a server refusal for the closed window is recognised (GraphQL code or upload message)', () {
      expect(isWindowClosedError(ApiException('x', code: 'WINDOW_CLOSED')), isTrue);
      expect(isWindowClosedError(ApiException('24-hour window closed. Send an approved template instead.')), isTrue);
      expect(isWindowClosedError(ApiException('This chat is closed. Reopen it to reply.', code: 'CONVERSATION_CLOSED')), isFalse);
    });
  });

  group('@mentions in notes', () {
    test('@ at the start or after a space opens the list; an email address does not', () {
      expect(mentionAt('@', 1), (start: 0, query: ''));
      expect(mentionAt('please call @dee', 16), (start: 12, query: 'dee'));
      expect(mentionAt('line one\n@ana', 13), (start: 9, query: 'ana'));
      expect(mentionAt('mail me at a@b.com', 18), isNull);
      expect(mentionAt('@deep patel ', 12), isNull);
      expect(mentionAt('hello', 5), isNull);
    });

    test('teammates by name (start, then any word) or email', () {
      final members = [
        (name: 'deep patel', email: 'deep@tyrescart.ae'),
        (name: 'Nikhil Shah', email: 'nikhil@tyrescart.ae'),
        (name: 'patel Parth', email: 'parthsutariya.synex@gmail.com'),
      ];
      List<String> names(String q) => matchMembers(members, q, (m) => m.name, (m) => m.email).map((m) => m.name).toList();
      expect(names(''), ['deep patel', 'Nikhil Shah', 'patel Parth']);
      expect(names('pat'), ['patel Parth', 'deep patel']);
      expect(names('synex'), ['patel Parth']);
      expect(names('zzz'), isEmpty);
    });

    test('picking one puts "@Name " at the cursor, keeping the rest', () {
      expect(insertMention('@', (start: 0, query: ''), 'deep patel'), (text: '@deep patel ', caret: 12));
      expect(insertMention('please call @dee today', (start: 12, query: 'dee'), 'deep patel'), (text: 'please call @deep patel today', caret: 24));
    });

    test('mentions in a note are found for highlighting (full names, longest first, word start only)', () {
      final names = ['deep', 'deep patel', 'Nikhil Shah'];
      expect(mentionPieces('@deep patel please call, cc @Nikhil Shah.', names), [
        (text: '@deep patel', mention: true),
        (text: ' please call, cc ', mention: false),
        (text: '@Nikhil Shah', mention: true),
        (text: '.', mention: false),
      ]);
      expect(mentionPieces('mail a@deep.com', names), [(text: 'mail a@deep.com', mention: false)]);
      expect(mentionPieces('@deepak is new', names), [(text: '@deepak is new', mention: false)]);
      expect(mentionPieces('no mentions', []), [(text: 'no mentions', mention: false)]);
    });

    test('only mentions still in the text are sent (a picked name deleted again is not)', () {
      expect(mentionedIds('@deep patel call him', {'u1': 'deep patel', 'u2': 'Nikhil Shah'}), ['u1']);
      expect(mentionedIds('nothing', {'u1': 'deep patel'}), isEmpty);
    });
  });

  group('templates', () {
    test('template names: saved first/last name, else the WhatsApp name; unknown stays empty (never guessed)', () {
      expect(customerNames(firstName: 'Alice', lastName: 'Patel', name: 'Ali P'), (first: 'Alice', last: 'Patel'));
      expect(customerNames(name: '  Alice   Mary Patel '), (first: 'Alice', last: 'Mary Patel'));
      expect(customerNames(firstName: ' ', lastName: null, name: 'Alice Patel'), (first: 'Alice', last: 'Patel'));
      expect(customerNames(name: 'Alice'), (first: 'Alice', last: ''));
      expect(customerNames(name: null), (first: '', last: ''));
    });

    test('{{1}} first name, {{2}} last name (named: first_name / last_name); others by hand', () {
      expect(nameFor('1'), 'first');
      expect(nameFor('2'), 'last');
      expect(nameFor('first_name'), 'first');
      expect(nameFor('LastName'), 'last');
      expect(nameFor('3'), isNull);
      expect(nameFor('order_id'), isNull);
      final t = template(bodyVariables: ['1', '2', '3']);
      expect(autoFillValues(t, (first: 'Alice', last: 'Patel'))['body'], {'1': 'Alice', '2': 'Patel'});
      final partial = autoFillValues(t, (first: 'Alice', last: ''));
      expect(partial['body'], {'1': 'Alice', '2': noName});
      expect(missingValues(t, partial), ['{{3}}']);
    });

    test('the message as the agent reads it: names filled in; no name is left out, never {{1}} or a made-up name', () {
      const body = 'Hello {{1}} 👋, I just wanted to follow up regarding your earlier inquiry.';
      expect(readableMessage(body, {'1': 'Parth patel'}), 'Hello Parth patel 👋, I just wanted to follow up regarding your earlier inquiry.');
      expect(readableMessage(body, {}), 'Hello 👋, I just wanted to follow up regarding your earlier inquiry.');
      expect(readableMessage('Hi {{1}}, thanks!', {}), 'Hi, thanks!');
      expect(readableMessage('Dear {{1}} {{2}},\nYour tyres are ready.', {'1': 'Alice'}), 'Dear Alice,\nYour tyres are ready.');
    });

    test('a customer without a name: the template still goes, with an invisible value instead of a name', () {
      final t = template(bodyVariables: ['1']);
      final none = autoFillValues(t, customerNames(name: null));
      expect(none['body'], {'1': noName});
      expect(missingValues(t, none), isEmpty);
      expect(noName.trim(), noName);
    });

    test('media headers and button values are required', () {
      final t = template(header: TemplateHeader(format: 'IMAGE', text: '', variables: []), buttons: [
        TemplateButton(type: 'URL', text: 'Track', url: 'https://x/{{1}}', variables: ['1']),
        TemplateButton(type: 'COPY_CODE', text: '', variables: []),
      ]);
      expect(missingValues(t, emptyValues()), ['header image', 'link for "Track"', 'coupon code']);
      expect(missingValues(t, {'header': {}, 'body': {}, 'buttons': {'0': 'abc', '1': 'SAVE10'}}, hasFile: true), isEmpty);
    });
  });

  group('files', () {
    test('JPEG/PNG up to 5 MB, documents up to 100 MB, by type or extension', () {
      expect(checkFile('a.jpg', null, 100), isA<FileOk>().having((f) => f.image, 'image', isTrue));
      expect(checkFile('quote.docx', null, 100), isA<FileOk>().having((f) => f.mime, 'mime', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'));
      expect(checkFile('clip.mov', 'video/quicktime', 100), isA<FileProblem>());
      expect(checkFile('big.png', 'image/png', 6 * 1024 * 1024), isA<FileProblem>().having((f) => f.message, 'message', contains('5 MB')));
      expect(checkFile('empty.pdf', 'application/pdf', 0), isA<FileProblem>());
    });

    test('placeholders and previews', () {
      expect(isMediaPlaceholder('[image]'), isTrue);
      expect(isMediaPlaceholder('my photo'), isFalse);
      expect(filePreview('image', '[image]'), '📷 Photo');
      expect(filePreview('image', 'front tyre'), '📷 front tyre');
      expect(filePreview('document', '[document]', 'invoice.pdf'), '📄 invoice.pdf');
      expect(filePreview('voice', '[audio]'), '🎤 Voice message');
      expect(filePreview('location', '[location]'), '📍 Location');
      expect(filePreview('contacts', '[contacts]'), '👤 Contact');
      expect(filePreview('text', 'hi'), isNull);
      expect(formatSize(2048), '2 KB');
      expect(formatSize(5 * 1024 * 1024), '5.0 MB');
    });
  });

  group('message actions', () {
    test('own text messages can be edited and deleted; admins any; customers\' never', () {
      final mine = message();
      expect(messageActions(mine, userId: 'u1', isAdmin: false, canReply: true), containsAll([MessageAction.reply, MessageAction.edit, MessageAction.delete, MessageAction.copy]));
      expect(messageActions(message(sentById: 'u2'), userId: 'u1', isAdmin: false, canReply: true), isNot(contains(MessageAction.edit)));
      expect(messageActions(message(sentById: 'u2'), userId: 'u1', isAdmin: true, canReply: true), contains(MessageAction.delete));
      final customer = message(direction: 'in', sentById: null);
      expect(messageActions(customer, userId: 'u1', isAdmin: true, canReply: true), isNot(contains(MessageAction.delete)));
      expect(messageActions(message(deletedAt: DateTime.now()), userId: 'u1', isAdmin: true, canReply: true), isEmpty);
      expect(messageActions(mine, userId: 'u1', isAdmin: false, canReply: false), isNot(contains(MessageAction.reply)));
    });

    test('forwarding: only what this app can send', () {
      expect(forwardKind(message()), 'text');
      expect(forwardKind(message(type: 'image', body: '[image]', mime: 'image/jpeg')), 'image');
      expect(forwardKind(message(type: 'video', body: '[video]', mime: 'video/mp4')), isNull);
      expect(forwardKind(message(type: 'voice', mime: 'audio/ogg; codecs=opus')), 'voice');
      expect(forwardKind(message(body: '[template] hello')), isNull);
    });
  });

  group('chat list', () {
    test('search: name, phone digits, last message, label, status words', () {
      final c = conversation(unread: 2);
      expect(matchesSearch(c, 'alice'), isTrue);
      expect(matchesSearch(c, '50123'), isTrue);
      expect(matchesSearch(c, 'patrol'), isTrue);
      expect(matchesSearch(c, 'vip'), isTrue);
      expect(matchesSearch(c, 'unread'), isTrue);
      expect(matchesSearch(c, 'unassigned'), isTrue);
      expect(matchesSearch(c, 'closed'), isFalse);
      expect(matchesSearch(c, 'zzz'), isFalse);
    });

    test('bold row: unread, or assigned to you and not opened yet', () {
      expect(needsAttention(conversation(unread: 1), 'u1'), isTrue);
      final mineNew = conversation(assignee: {'id': 'm1', 'name': 'Me', 'color': '#000000', 'userId': 'u1'});
      expect(needsAttention(mineNew, 'u1'), isTrue);
      mineNew.assigneeOpenedAt = DateTime.now();
      expect(needsAttention(mineNew, 'u1'), isFalse);
    });

    test('new leads are open chats nobody holds', () {
      expect(conversation().isNewLead, isTrue);
      expect(conversation(status: 'closed').isNewLead, isFalse);
      expect(conversation(assignee: {'id': 'm1', 'name': 'A', 'color': '#000000'}).isNewLead, isFalse);
    });

    test('forward targets follow the window and closed chats', () {
      final now = DateTime.parse('2026-10-23T12:00:00Z');
      expect(forwardBlocked(conversation(lastInboundAt: now.subtract(const Duration(hours: 2))), now), '');
      expect(forwardBlocked(conversation(lastInboundAt: now.subtract(const Duration(hours: 30))), now), contains('24-hour'));
      expect(forwardBlocked(conversation(status: 'closed', lastInboundAt: now), now), contains('Closed'));
    });
  });

  group('Dubai time', () {
    final now = DateTime.parse('2026-10-15T10:30:00Z'); // Thursday 15 Oct 2026, 14:30 in Dubai
    test('1 hour and 3 hours are relative; tomorrow and Monday are 9:00 in Dubai', () {
      final c = {for (final x in snoozeChoices(now)) x.label: x.until};
      expect(c['1 hour']!.difference(now), const Duration(hours: 1));
      expect(c['3 hours']!.difference(now), const Duration(hours: 3));
      expect(c['Tomorrow']!.toIso8601String(), '2026-10-16T05:00:00.000Z');
      expect(c['Monday']!.toIso8601String(), '2026-10-19T05:00:00.000Z');
    });

    test('on a Monday, "Monday" means next week; late at night, "tomorrow" is the next Dubai day', () {
      final monday = DateTime.parse('2026-10-19T04:00:00Z');
      expect(snoozeChoices(monday).firstWhere((x) => x.label == 'Monday').until.toIso8601String(), '2026-10-26T05:00:00.000Z');
      final lateNight = DateTime.parse('2026-10-15T21:30:00Z');
      expect(snoozeChoices(lateNight).firstWhere((x) => x.label == 'Tomorrow').until.toIso8601String(), '2026-10-17T05:00:00.000Z');
    });

    test('labels', () {
      expect(snoozedUntilText(DateTime.parse('2026-10-15T10:16:00Z')), '15 Oct, 14:16');
      expect(formatTime(DateTime.parse('2026-10-15T21:30:00Z')), '01:30');
      expect(dayLabel(DateTime.parse('2026-10-15T08:00:00Z'), now), 'Today');
      expect(dayLabel(DateTime.parse('2026-10-14T08:00:00Z'), now), 'Yesterday');
      expect(dayLabel(DateTime.parse('2026-10-10T08:00:00Z'), now), 'Sat, 10 Oct');
      expect(dayLabel(DateTime.parse('2025-10-10T08:00:00Z'), now), 'Fri, 10 Oct 2025');
      // 21:30 UTC on the 14th is already the 15th in Dubai
      expect(listTimestamp(DateTime.parse('2026-10-14T21:30:00Z'), now), '01:30');
      expect(listTimestamp(DateTime.parse('2026-10-13T08:00:00Z'), now), '13 Oct');
    });
  });

  group('models', () {
    test('a newer copy of a message wins; an older one only updates its status', () {
      final v1 = message(status: 'sent');
      final v2 = Message.fromJson({'id': 'm1', 'conversationId': 'c1', 'direction': 'out', 'type': 'text', 'body': 'edited', 'status': 'sent', 'createdAt': '2026-10-23T10:00:00Z', 'version': 2});
      expect(v1.newer(v2).body, 'edited');
      final old = Message.fromJson({'id': 'm1', 'conversationId': 'c1', 'direction': 'out', 'type': 'text', 'body': 'old', 'status': 'read', 'createdAt': '2026-10-23T10:00:00Z', 'version': 0});
      final kept = v2.newer(old);
      expect(kept.body, 'edited');
      expect(kept.status, 'read');
    });

    test('contact display: name, else the number', () {
      expect(conversation().contact.display, 'Alice Patel');
      expect(conversation(name: null).contact.display, '+971501234567');
      expect(conversation(name: '  ').contact.display, '+971501234567');
    });
  });

  group('search in conversation', () {
    test('matches loaded messages (not deleted ones), oldest first; highlighting keeps the casing', () {
      final a = message(body: 'Michelin Pilot Sport 4');
      final b = Message.fromJson({'id': 'm2', 'conversationId': 'c1', 'direction': 'in', 'type': 'text', 'body': 'michelin price?', 'status': 'received', 'createdAt': '2026-10-23T11:00:00Z', 'version': 0});
      final gone = Message.fromJson({'id': 'm3', 'conversationId': 'c1', 'direction': 'out', 'type': 'text', 'body': 'michelin', 'status': 'sent', 'createdAt': '2026-10-23T12:00:00Z', 'version': 1, 'deletedAt': '2026-10-23T12:01:00Z'});
      expect(findMessageMatches([a, b, gone], 'MICHELIN'), ['m1', 'm2']);
      expect(findMessageMatches([a], '  '), isEmpty);
      expect(highlightSegments('Michelin Pilot', 'pilot'), [(text: 'Michelin ', match: false), (text: 'Pilot', match: true)]);
      expect(highlightSegments('abc', ''), [(text: 'abc', match: false)]);
    });
  });

  group('activity text', () {
    Activity a(String type, Map<String, dynamic> data, {String? actorId = 'u2'}) => Activity(
        id: 'a', type: type, actorId: actorId, actorName: 'Deep', contactName: 'Alice', data: data.isEmpty ? null : _json(data), createdAt: DateTime.now());
    test('timeline and bell wording', () {
      expect(activityText(a('assigned', {'assignee': 'Nikhil'}), 'u1'), 'Deep assigned this chat to Nikhil');
      expect(activityText(a('assigned', {'assignee': 'Me', 'assigneeUserId': 'u1'}), 'u1'), 'Deep assigned this chat to you');
      expect(activityText(a('conversation_closed', {}, actorId: 'u1'), 'u1'), 'You closed this chat');
      expect(activityText(a('label_added', {'label': 'VIP'}), 'u1', bell: true), 'Deep added label "VIP" to the chat with Alice');
      expect(activityText(a('note_mention', {'text': 'call him'}), 'u1', bell: true), 'Deep mentioned you in a note on the chat with Alice: call him');
    });
  });
}

String _json(Map<String, dynamic> m) => '{${m.entries.map((e) => '"${e.key}":"${e.value}"').join(',')}}';
