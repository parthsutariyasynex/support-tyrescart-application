// Checks the app's API layer against a running development server, through the website's address (the same path a
// phone uses: Next.js forwards /graphql, /socket.io and the file routes to the API).
//
//   SUPPORT_TEST_SERVER=http://localhost:4000 flutter test test/live_api_test.dart
//
// Skipped without SUPPORT_TEST_SERVER. It creates its own test workspace (development servers allow it), a fake
// customer chat (the dev-only "simulate incoming message"), and never touches other workspaces. Never point it at
// production: workspace creation and simulated messages are refused there anyway.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tyrescart_support/core/api.dart';
import 'package:tyrescart_support/core/realtime.dart';
import 'package:tyrescart_support/core/repo.dart';

final server = Platform.environment['SUPPORT_TEST_SERVER'];

// A 1×1 PNG
final png = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06,
  0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0x00, 0x05, 0x00,
  0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

Future<T> eventually<T>(Future<T> Function() f, bool Function(T) ok, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (true) {
    final v = await f();
    if (ok(v) || DateTime.now().isAfter(end)) return v;
    await Future.delayed(const Duration(milliseconds: 300));
  }
}

void main() {
  if (server == null) {
    test('live API (set SUPPORT_TEST_SERVER to run)', () {}, skip: 'SUPPORT_TEST_SERVER not set');
    return;
  }

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final ownerEmail = 'mobile-test-$stamp@example.test';
  final agentEmail = 'mobile-agent-$stamp@example.test';
  const password = 'MobileTest1234';
  // A valid UAE mobile number (971 50 …): the server checks numbers, so random digits after 9715 may be refused
  final customerWaId = '97150${(stamp % 10000000).toString().padLeft(7, '0')}';

  late Api api;
  late Repo repo;
  late Api agentApi;
  late Repo agentRepo;
  String? conversationId;
  String? contactId;
  String? agentUserId;
  String? ownerUserId;
  final owner = Realtime();
  final agent = Realtime();

  setUpAll(() async {
    api = Api(baseUrl: server!);
    repo = Repo(api);
    agentApi = Api(baseUrl: server!);
    agentRepo = Repo(agentApi);
  });

  tearDownAll(() {
    owner.disconnect();
    agent.disconnect();
  });

  test('health and sign-in errors come back as the server sends them', () async {
    expect(await api.health(), isTrue);
    await expectLater(repo.login('nobody-$stamp@example.test', 'wrong-pass-1'), throwsA(isA<ApiException>()));
  });

  test('a test workspace and sign-in (same JWT as the website)', () async {
    final d = await api.gql(r'mutation R($i: RegisterInput!) { register(input: $i) { token } }', {
      'i': {'name': 'Mobile Test Owner', 'email': ownerEmail, 'password': password, 'workspaceName': 'Mobile app test $stamp'}
    });
    expect(d['register']['token'], isA<String>());
    api.token = await repo.login(ownerEmail, password);
    final me = await repo.me();
    ownerUserId = me['user']['id'];
    expect(me['role'], 'owner');
    expect(me['canManageAssignments'], isTrue);
    expect((await repo.workspaces()).length, greaterThanOrEqualTo(1));
  });

  test('a teammate (agent) is added and signs in', () async {
    final r = await repo.inviteMember({'name': 'Mobile Test Agent', 'email': agentEmail, 'role': 'agent', 'password': password});
    expect(r.invited, isFalse); // a password was given, so no invite email
    agentApi.token = await agentRepo.login(agentEmail, password);
    final me = await agentRepo.me();
    agentUserId = me['user']['id'];
    expect(me['role'], 'agent');
    expect(me['canManageAssignments'], isFalse);
  });

  test('live connection: a customer message arrives as message:new and the chat is listed', () async {
    owner.connect(server!, api.token!);
    agent.connect(server!, agentApi.token!);
    await owner.connection.firstWhere((c) => c).timeout(const Duration(seconds: 10));
    await agent.connection.firstWhere((c) => c).timeout(const Duration(seconds: 10));
    final got = owner.on('message:new').first.timeout(const Duration(seconds: 10));
    await api.gql(r'mutation S($i: SimulateIncomingInput) { simulateIncomingMessage(input: $i) }', {
      'i': {'waId': customerWaId, 'name': 'Test Customer', 'body': 'Hi, I need 4 tyres for my Patrol'}
    });
    final e = await got;
    expect(e.map['message']['body'], 'Hi, I need 4 tyres for my Patrol');
    conversationId = e.map['message']['conversationId'];

    final page = await repo.conversations(const ConversationQuery());
    final c = page.nodes.firstWhere((c) => c.id == conversationId);
    contactId = c.contact.id;
    expect(c.contact.name, 'Test Customer');
    expect(c.unread, 1);
    expect(c.isNewLead, isTrue);
    expect(c.lastInboundAt, isNotNull);
    expect((await repo.conversations(const ConversationQuery(assignee: 'new_leads'))).nodes.map((c) => c.id), contains(conversationId));
    expect((await repo.conversations(const ConversationQuery(search: 'patrol'))).nodes.map((c) => c.id), contains(conversationId));
    expect((await repo.counts()).newLeads, greaterThanOrEqualTo(1));
    expect(await repo.unreadTotal(), greaterThanOrEqualTo(1));
  });

  test('chat screen data: messages, read, details, timeline', () async {
    final m = await repo.messages(conversationId!);
    expect(m.nodes.single.direction, 'in');
    await repo.markRead(conversationId!);
    expect((await repo.conversation(conversationId!)).unread, 0);
    final d = await repo.chatDetails(conversationId!);
    expect(d.lastInboundAt, isNotNull);
    await repo.conversationActivity(conversationId!);
    await repo.chatFiles(conversationId!);
  });

  test('new lead: an agent must take it before replying; anyone can add a note', () async {
    await expectLater(agentRepo.sendText(conversationId!, 'hello'), throwsA(isA<ApiException>()));
    final note = await agentRepo.addRemark(contactId!, 'Customer asked about Patrol tyres');
    expect(note.authorName, 'Mobile Test Agent');
    final a = await agentRepo.claim(conversationId!);
    expect(a?.userId, agentUserId);
    expect((await agentRepo.conversations(const ConversationQuery(assignee: 'me'))).nodes.map((c) => c.id), contains(conversationId));
  });

  test('sending without a connected WhatsApp number is refused by the server (no Meta call from the app)', () async {
    await expectLater(agentRepo.sendText(conversationId!, 'We have them in stock'), throwsA(isA<ApiException>()));
  });

  test('@mention in a note: the teammate gets mention:you, the chat in Mentions and a bell entry', () async {
    final popup = agent.on('mention:you').first.timeout(const Duration(seconds: 10));
    final note = await repo.addRemark(contactId!, '@Mobile Test Agent please call the customer', mentions: [agentUserId!]);
    final e = await popup;
    expect(e.map['conversationId'], conversationId);
    expect((await agentRepo.conversations(const ConversationQuery(assignee: 'mentioned'))).nodes.map((c) => c.id), contains(conversationId));
    final bell = await eventually(agentRepo.notifications, (n) => n.items.any((a) => a.type == 'note_mention'));
    expect(bell.items.any((a) => a.type == 'note_mention'), isTrue);
    // Editing the note away from the mention removes it from Mentions
    await repo.updateRemark(note.id, 'please call the customer');
    final after = await eventually(() => agentRepo.conversations(const ConversationQuery(assignee: 'mentioned')), (p) => !p.nodes.any((c) => c.id == conversationId));
    expect(after.nodes.map((c) => c.id), isNot(contains(conversationId)));
  });

  test('note files: upload, attach, download (team only)', () async {
    final f = await repo.uploadRemarkFile(contactId!, png, 'image/png', 'tyre.png');
    expect(f.mime, 'image/png');
    final note = await repo.addRemark(contactId!, '', files: [f.id]);
    expect(note.files.single.id, f.id);
    final d = await repo.api.download('/inbox/remark-files/${f.id}');
    expect(d.bytes, png);
    final notes = await repo.chatNotes(conversationId!);
    expect(notes.any((n) => n.files.isNotEmpty), isTrue);
    await repo.deleteRemark(note.id);
    // Without a token the file is refused
    await expectLater(Api(baseUrl: server!).download('/inbox/remark-files/${f.id}'), throwsA(isA<ApiException>()));
  });

  test('labels, pin, unread, snooze, close/reopen, collaborators, assignment with reason', () async {
    await repo.createLabel('Mobile VIP $stamp', '#25d366');
    final label = (await repo.labels()).firstWhere((l) => l.name == 'Mobile VIP $stamp');
    expect((await repo.setConversationLabel(conversationId!, label.id, true)).map((l) => l.id), contains(label.id));
    expect((await repo.conversations(ConversationQuery(labelIds: [label.id]))).nodes.map((c) => c.id), contains(conversationId));
    await repo.setConversationLabel(conversationId!, label.id, false);
    await repo.deleteLabel(label.id);

    await repo.setPinned(conversationId!, true);
    expect((await repo.conversation(conversationId!)).pinned, isTrue);
    await repo.setPinned(conversationId!, false);
    await repo.markUnread(conversationId!);
    expect((await repo.conversation(conversationId!)).unread, greaterThan(0));

    await repo.snooze(conversationId!, DateTime.now().add(const Duration(hours: 1)));
    expect((await repo.conversation(conversationId!)).status, 'snoozed');
    await repo.setStatus(conversationId!, true);
    expect((await repo.conversation(conversationId!)).status, 'closed');
    await repo.setStatus(conversationId!, false);
    expect((await repo.conversation(conversationId!)).status, 'open');

    await repo.addCollaborators(conversationId!, [ownerUserId!]);
    expect((await repo.collaborators(conversationId!)).map((m) => m.id), contains(ownerUserId));
    await repo.removeCollaborator(conversationId!, ownerUserId!);

    final assignees = await repo.assignees();
    final ownerMember = assignees.firstWhere((a) => a.userId == ownerUserId);
    await expectLater(repo.assign(conversationId!, assigneeId: ownerMember.id), throwsA(isA<ApiException>())); // reason required
    final a = await repo.assign(conversationId!, assigneeId: ownerMember.id, reason: 'Mobile test handover');
    expect(a?.userId, ownerUserId);
    await expectLater(agentRepo.assign(conversationId!, assigneeId: ownerMember.id, reason: 'x'), throwsA(isA<ApiException>())); // agents can't
    final report = await repo.assignmentReport();
    expect(report.any((r) => r['reason'] == 'Mobile test handover'), isTrue);
  });

  test('contact profile, lists, custom properties, field options', () async {
    final opts = await repo.fieldOptions();
    expect(opts.remarkMaxLength, greaterThan(0));
    final p = await repo.updateContact(contactId!, {'firstName': 'Alice', 'lastName': 'Patel', 'email': 'alice@example.test'});
    expect(p.field('firstName'), 'Alice');
    await repo.customProperties();
    await repo.contactLists();
    await repo.leadStageCounts();
    expect((await repo.contactRemarks(contactId!)).isNotEmpty, isTrue);
  });

  test('typing between teammates arrives live', () async {
    final seen = owner.on('typing').first.timeout(const Duration(seconds: 5));
    // the chat is assigned now and its window is open, so typing is relayed
    agent.emit('typing', {'conversationId': conversationId, 'typing': true});
    final e = await seen;
    expect(e.map['userId'], agentUserId);
    expect(e.map['typing'], isTrue);
  });

  test('new chat by number: reuses an existing chat, never a duplicate', () async {
    final again = await repo.startConversation(customerWaId);
    expect(again.id, conversationId);
    await expectLater(repo.startConversation('123'), throwsA(isA<ApiException>()));
  });

  test('settings reads used by the app', () async {
    await repo.quickReplies();
    await repo.workspaceSettings();
    await repo.automationSettings();
    expect((await repo.members()).length, 2);
    expect((await repo.workspaceMembers()).length, 2);
    // Templates come live from Meta: without a connected number the server says so
    try {
      await repo.approvedTemplates();
    } on ApiException catch (e) {
      expect(e.message, isNotEmpty);
    }
  });

  test('clear chat hides history only for the person who cleared it', () async {
    await repo.clearChat(conversationId!);
    expect((await repo.messages(conversationId!)).nodes, isEmpty);
    expect((await agentRepo.messages(conversationId!)).nodes, isNotEmpty);
  });

  test('deactivated teammates are signed out (their token stops working)', () async {
    await repo.setMemberActive(agentUserId!, false);
    await expectLater(agentRepo.me(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'UNAUTHENTICATED')));
  });
}
