import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';
import 'api.dart';

// Every backend call the app makes. Field lists match the website's (client/lib/*.ts), so both see the same data.

const _baseMessageFields =
    'id conversationId direction type body status error createdAt sentById senderName editedAt deletedAt version mediaMime mediaSize mediaName customerReaction teamReaction teamReactionById automation';
const _messageFields = '$_baseMessageFields replyToId replyTo { id direction type body senderName deleted mediaMime mediaName }';
const _conversationFields =
    'id unread lastMessageAt lastInboundAt contact { id waId name leadStage country } lastMessage { $_baseMessageFields } labels { id name color } assignee { id name color userId } assigneeOpenedAt status closedAt closedById snoozedUntil pinned isCollaborator wasAssigned';
const _remarkFields = 'id contactId body createdById authorName createdAt editedAt files { id name mime size }';
const _contactFields =
    'id waId name firstName lastName email companyName jobTitle leadStage leadSource priority country phoneCountry subscribed waBsuid waUsername lists { id name } customValues { propertyId value } conversationId createdAt updatedAt';
const _templateFields =
    'id name language category status rejectedReason parameterFormat header { format text variables } body bodyVariables footer buttons { type text url phoneNumber variables } needsParameters sendable unsupportedReason';
const _activityFields = 'id type conversationId actorId actorName contactName data createdAt';
const _meFields =
    'user { id name email phone jobTitle timeZone avatarUpdatedAt } workspace { id name whatsapp { displayPhone } settings { defaultTimeZone defaultCountry businessDayStartHour } }';
const _memberFields = 'userId name email role isOwner canManageLabels active status';
const _stageFields = 'id value label color closed isDefault';

/// Meta's sample template is never offered in the chat (the server leaves it out too)
const metaSampleTemplates = ['hello_world'];

/// Filters of the chat list (server arguments of `conversations`)
class ConversationQuery {
  const ConversationQuery({
    this.assignee,
    this.status,
    this.search,
    this.sort,
    this.labelIds = const [],
    this.assigneeIds = const [],
    this.from,
    this.to,
    this.leadStage,
    this.leadStages = const [],
  });
  final String? assignee; // member id | unassigned | me | collaborating | mentioned | new_leads
  final String? status; // open | closed | snoozed
  final String? search;
  final String? sort; // newest | oldest
  final List<String> labelIds;
  final List<String> assigneeIds;
  final DateTime? from;
  final DateTime? to;
  final String? leadStage;
  final List<String> leadStages;

  Map<String, dynamic> toVariables() => {
    'assignee': assignee,
    'status': status,
    'search': (search?.trim().isEmpty ?? true) ? null : search!.trim(),
    'sort': sort,
    'labelIds': labelIds.isEmpty ? null : labelIds,
    'assigneeIds': assigneeIds.isEmpty ? null : assigneeIds,
    'from': from?.toUtc().toIso8601String(),
    'to': to?.toUtc().toIso8601String(),
    'leadStage': leadStage,
    'leadStages': leadStages.isEmpty ? null : leadStages,
  };

  ConversationQuery copyWith({
    String? search,
    String? status,
    bool clearStatus = false,
    String? sort,
    List<String>? labelIds,
    List<String>? assigneeIds,
    DateTime? from,
    DateTime? to,
    bool clearDates = false,
    List<String>? leadStages,
  }) => ConversationQuery(
    assignee: assignee,
    status: clearStatus ? null : (status ?? this.status),
    search: search ?? this.search,
    sort: sort ?? this.sort,
    labelIds: labelIds ?? this.labelIds,
    assigneeIds: assigneeIds ?? this.assigneeIds,
    from: clearDates ? null : (from ?? this.from),
    to: clearDates ? null : (to ?? this.to),
    leadStage: leadStage,
    leadStages: leadStages ?? this.leadStages,
  );

  int get activeMenuFilters =>
      (labelIds.isNotEmpty ? 1 : 0) + (assigneeIds.isNotEmpty ? 1 : 0) + (from != null || to != null ? 1 : 0) + (leadStages.isNotEmpty ? 1 : 0);
}

class Repo {
  Repo(this.api);
  final Api api;

  static const pageSize = 50;

  Future<Map<String, dynamic>> _g(String q, [Map<String, dynamic>? v]) => api.gql(q, v);

  // ---------------------------------------------------------------- Auth and session

  Future<String> login(String email, String password, {String? workspaceId}) async {
    final d = await _g(r'mutation Login($input: LoginInput!) { login(input: $input) { token } }', {
      'input': {'email': email, 'password': password, 'workspaceId': ?workspaceId},
    });
    return d['login']['token'] as String;
  }

  Future<void> requestPasswordReset(String email) async {
    await _g(r'mutation RequestReset($email: String!) { requestPasswordReset(email: $email) }', {'email': email});
  }

  Future<Map<String, dynamic>> me() async =>
      Map<String, dynamic>.from((await _g('query Me { me { $_meFields role canManageLabels canManageAssignments } }'))['me']);

  Future<List<WorkspaceSummary>> workspaces() async => ((await _g('query Workspaces { workspaces { id name role } }'))['workspaces'] as List)
      .map((e) => WorkspaceSummary.fromJson(Map<String, dynamic>.from(e)))
      .toList();

  Future<String> switchWorkspace(String id) async =>
      (await _g(r'mutation SwitchWorkspace($id: ID!) { switchWorkspace(id: $id) { token } }', {'id': id}))['switchWorkspace']['token'];

  Future<String> changeMyPassword(String current, String next) async => (await _g(
    r'mutation ChangeMyPassword($c: String!, $n: String!) { changeMyPassword(currentPassword: $c, newPassword: $n) { token } }',
    {'c': current, 'n': next},
  ))['changeMyPassword']['token'];

  Future<void> updateMyProfile(Map<String, String> input) async {
    await _g(r'mutation UpdateMyProfile($i: MyProfileInput!) { updateMyProfile(input: $i) { name phone jobTitle timeZone } }', {'i': input});
  }

  // ---------------------------------------------------------------- Chat list

  Future<Page<Conversation>> conversations(ConversationQuery q, {String? after}) async {
    const query = r'''query Conversations($first: Int, $after: String, $assignee: ID, $status: String, $search: String, $sort: String, $labelIds: [ID!], $assigneeIds: [ID!], $from: DateTime, $to: DateTime, $leadStage: String, $leadStages: [String!]) {
      conversations(first: $first, after: $after, assignee: $assignee, status: $status, search: $search, sort: $sort, labelIds: $labelIds, assigneeIds: $assigneeIds, from: $from, to: $to, leadStage: $leadStage, leadStages: $leadStages) { nodes { FIELDS } pageInfo { hasNextPage endCursor } }
    }''';
    final d = await _g(query.replaceFirst('FIELDS', _conversationFields), {'first': pageSize, 'after': after, ...q.toVariables()});
    final c = d['conversations'];
    return Page(
      (c['nodes'] as List).map((e) => Conversation.fromJson(Map<String, dynamic>.from(e))).toList(),
      c['pageInfo']['hasNextPage'] == true,
      c['pageInfo']['endCursor'] as String?,
    );
  }

  Future<Conversation> conversation(String id) async => Conversation.fromJson(
    Map<String, dynamic>.from((await _g('query Conversation(\$id: ID!) { conversation(id: \$id) { $_conversationFields } }', {'id': id}))['conversation']),
  );

  Future<ConversationCounts> counts() async => ConversationCounts.fromJson(
    Map<String, dynamic>.from(
      (await _g('query Counts { conversationCounts { open closed closedWithUnread unassigned snoozed newLeads } }'))['conversationCounts'],
    ),
  );

  Future<Map<String?, int>> leadStageCounts() async {
    final d = await _g(r'query StageCounts($c: Boolean) { leadStageCounts(chats: $c) { stage count } }', {'c': true});
    return {for (final r in d['leadStageCounts'] as List) r['stage'] as String?: (r['count'] as num).toInt()};
  }

  Future<int> unreadTotal() async => ((await _g('query UnreadTotal { unreadTotal }'))['unreadTotal'] as num).toInt();

  // ---------------------------------------------------------------- Messages

  Future<Page<Message>> messages(String conversationId, {String? after}) async {
    final d = await _g(
      'query Messages(\$id: ID!, \$first: Int, \$after: String) { messages(conversationId: \$id, first: \$first, after: \$after) { nodes { $_messageFields } pageInfo { hasNextPage endCursor } } }',
      {'id': conversationId, 'first': pageSize, 'after': after},
    );
    final m = d['messages'];
    return Page(
      (m['nodes'] as List).map((e) => Message.fromJson(Map<String, dynamic>.from(e))).toList(),
      m['pageInfo']['hasNextPage'] == true,
      m['pageInfo']['endCursor'] as String?,
    );
  }

  Future<void> markRead(String id) async {
    await _g(r'mutation MarkRead($id: ID!) { markConversationRead(id: $id) { id unread } }', {'id': id});
  }

  Future<Message> sendText(String conversationId, String body, {String? replyToId}) async => Message.fromJson(
    Map<String, dynamic>.from(
      (await _g('mutation SendText(\$input: SendTextInput!) { sendTextMessage(input: \$input) { $_messageFields } }', {
        'input': {'conversationId': conversationId, 'body': body, 'replyToId': ?replyToId},
      }))['sendTextMessage'],
    ),
  );

  /// Photo (JPEG/PNG) or document: the file is the body, as the website sends it
  Future<Message> sendFile(
    String conversationId, {
    required Uint8List bytes,
    required String mime,
    required bool image,
    String? name,
    String caption = '',
    String? replyToId,
  }) async {
    final q = <String, String>{if (caption.trim().isNotEmpty) 'caption': caption.trim(), if (!image && name != null) 'name': name, 'replyTo': ?replyToId};
    final json = await api.upload('/inbox/conversations/${Uri.encodeComponent(conversationId)}/${image ? 'images' : 'documents'}', bytes, mime, query: q);
    return Message.fromJson(json);
  }

  Future<Message> sendVoice(String conversationId, Uint8List bytes, String mime, {String? replyToId}) async {
    final json = await api.upload('/inbox/conversations/${Uri.encodeComponent(conversationId)}/voice', bytes, mime, query: {'replyTo': ?replyToId});
    return Message.fromJson(json);
  }

  Future<Message> editMessage(String id, String body, int version) async => Message.fromJson(
    Map<String, dynamic>.from(
      (await _g('mutation EditMessage(\$input: EditMessageInput!) { editMessage(input: \$input) { $_messageFields } }', {
        'input': {'messageId': id, 'body': body, 'version': version},
      }))['editMessage'],
    ),
  );

  Future<Message> react(String id, String? emoji) async => Message.fromJson(
    Map<String, dynamic>.from(
      (await _g('mutation React(\$id: ID!, \$e: String) { reactToMessage(messageId: \$id, emoji: \$e) { $_messageFields } }', {
        'id': id,
        'e': emoji,
      }))['reactToMessage'],
    ),
  );

  Future<Message> deleteMessage(String id, int version) async => Message.fromJson(
    Map<String, dynamic>.from(
      (await _g('mutation DeleteMessage(\$id: ID!, \$v: Int) { deleteMessage(messageId: \$id, version: \$v) { $_messageFields } }', {
        'id': id,
        'v': version,
      }))['deleteMessage'],
    ),
  );

  Future<Message> restoreMessage(String id, int version) async => Message.fromJson(
    Map<String, dynamic>.from(
      (await _g('mutation RestoreMessage(\$id: ID!, \$v: Int!) { restoreMessage(messageId: \$id, version: \$v) { $_messageFields } }', {
        'id': id,
        'v': version,
      }))['restoreMessage'],
    ),
  );

  Future<List<Activity>> conversationActivity(String id) async =>
      ((await _g('query Activity(\$c: ID!) { conversationActivity(conversationId: \$c) { $_activityFields } }', {'c': id}))['conversationActivity'] as List)
          .map((e) => Activity.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  // ---------------------------------------------------------------- Conversation actions

  Future<void> setStatus(String id, bool close) async {
    final f = close ? 'closeConversation' : 'reopenConversation';
    await _g('mutation SetStatus(\$id: ID!) { $f(id: \$id) { id status } }', {'id': id});
  }

  Future<void> snooze(String id, DateTime until) async {
    await _g(r'mutation Snooze($id: ID!, $until: DateTime!) { snoozeConversation(id: $id, until: $until) { id status } }', {
      'id': id,
      'until': until.toUtc().toIso8601String(),
    });
  }

  Future<void> setPinned(String id, bool pinned) async {
    final f = pinned ? 'pinConversation' : 'unpinConversation';
    await _g('mutation Pin(\$id: ID!) { $f(id: \$id) { id pinned } }', {'id': id});
  }

  Future<void> markUnread(String id) async {
    await _g(r'mutation Unread($id: ID!) { markConversationUnread(id: $id) { id unread } }', {'id': id});
  }

  Future<void> clearChat(String id) async {
    await _g(r'mutation ClearChat($id: ID!) { clearConversation(id: $id) }', {'id': id});
  }

  Future<Conversation> startConversation(String waId, {String? name}) async => Conversation.fromJson(
    Map<String, dynamic>.from(
      (await _g('mutation StartConversation(\$input: StartConversationInput!) { startConversation(input: \$input) { startedNow $_conversationFields } }', {
        'input': {'waId': waId, if (name != null && name.trim().isNotEmpty) 'name': name.trim()},
      }))['startConversation'],
    ),
  );

  Future<AssigneeRef?> claim(String conversationId) async {
    final d = await _g(r'mutation Claim($c: ID!) { claimConversation(conversationId: $c) { id assignee { id name color userId } } }', {'c': conversationId});
    final a = d['claimConversation']['assignee'];
    return a == null ? null : AssigneeRef.fromJson(Map<String, dynamic>.from(a));
  }

  Future<AssigneeRef?> assign(String conversationId, {String? assigneeId, String? reason}) async {
    final d = await _g(
      r'mutation Assign($c: ID!, $a: ID, $r: String) { assignConversation(conversationId: $c, assigneeId: $a, reason: $r) { id assignee { id name color userId } } }',
      {'c': conversationId, 'a': assigneeId, 'r': (reason?.trim().isEmpty ?? true) ? null : reason!.trim()},
    );
    final a = d['assignConversation']['assignee'];
    return a == null ? null : AssigneeRef.fromJson(Map<String, dynamic>.from(a));
  }

  Future<List<Assignee>> assignees() async => ((await _g('query Assignees { assignees { id name color conversationCount userId } }'))['assignees'] as List)
      .map((e) => Assignee.fromJson(Map<String, dynamic>.from(e)))
      .toList();

  Future<List<WorkspaceMember>> workspaceMembers() async =>
      ((await _g('query Members { workspaceMembers { id name email role } }'))['workspaceMembers'] as List)
          .map((e) => WorkspaceMember.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  Future<List<WorkspaceMember>> collaborators(String conversationId) async =>
      ((await _g(r'query Collaborators($id: ID!) { conversation(id: $id) { collaborators { id name email role } } }', {
                'id': conversationId,
              }))['conversation']['collaborators']
              as List)
          .map((e) => WorkspaceMember.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  Future<void> addCollaborators(String conversationId, List<String> userIds) async {
    await _g(r'mutation Add($c: ID!, $u: [ID!]!) { addCollaborators(conversationId: $c, userIds: $u) { id } }', {'c': conversationId, 'u': userIds});
  }

  Future<void> removeCollaborator(String conversationId, String userId) async {
    await _g(r'mutation Remove($c: ID!, $u: ID!) { removeCollaborator(conversationId: $c, userId: $u) { id } }', {'c': conversationId, 'u': userId});
  }

  // ---------------------------------------------------------------- Labels

  Future<List<Label>> labels() async => ((await _g('query Labels { labels { id name color conversationCount } }'))['labels'] as List)
      .map((e) => Label.fromJson(Map<String, dynamic>.from(e)))
      .toList();

  Future<List<LabelRef>> setConversationLabel(String conversationId, String labelId, bool add) async {
    final f = add ? 'addConversationLabel' : 'removeConversationLabel';
    final d = await _g('mutation L(\$c: ID!, \$l: ID!) { $f(conversationId: \$c, labelId: \$l) { id labels { id name color } } }', {
      'c': conversationId,
      'l': labelId,
    });
    return (d[f]['labels'] as List).map((e) => LabelRef.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  Future<void> createLabel(String name, String color) async {
    await _g(r'mutation CreateLabel($input: CreateLabelInput!) { createLabel(input: $input) { id } }', {
      'input': {'name': name, 'color': color},
    });
  }

  Future<void> updateLabel(String id, String name, String color) async {
    await _g(r'mutation UpdateLabel($id: ID!, $input: UpdateLabelInput!) { updateLabel(id: $id, input: $input) { id } }', {
      'id': id,
      'input': {'name': name, 'color': color},
    });
  }

  Future<void> deleteLabel(String id) async {
    await _g(r'mutation DeleteLabel($id: ID!) { deleteLabel(id: $id) }', {'id': id});
  }

  // ---------------------------------------------------------------- Internal notes and contacts

  Future<List<ContactRemark>> chatNotes(String conversationId) async =>
      ((await _g('query ChatNotes(\$c: ID!) { chatNotes(conversationId: \$c) { $_remarkFields } }', {'c': conversationId}))['chatNotes'] as List)
          .map((e) => ContactRemark.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  Future<List<ContactRemark>> contactRemarks(String contactId) async =>
      ((await _g('query Remarks(\$c: ID!) { contactRemarks(contactId: \$c) { $_remarkFields } }', {'c': contactId}))['contactRemarks'] as List)
          .map((e) => ContactRemark.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  Future<ContactRemark> addRemark(
    String contactId,
    String body, {
    List<String> mentions = const [],
    List<String> files = const [],
  }) async => ContactRemark.fromJson(
    Map<String, dynamic>.from(
      (await _g(
        'mutation AddRemark(\$c: ID!, \$b: String!, \$m: [ID!], \$f: [ID!]) { addContactRemark(contactId: \$c, body: \$b, mentions: \$m, files: \$f) { $_remarkFields } }',
        {'c': contactId, 'b': body, 'm': mentions.isEmpty ? null : mentions, 'f': files.isEmpty ? null : files},
      ))['addContactRemark'],
    ),
  );

  Future<ContactRemark> updateRemark(String id, String body) async => ContactRemark.fromJson(
    Map<String, dynamic>.from(
      (await _g('mutation UpdateRemark(\$id: ID!, \$b: String!) { updateContactRemark(id: \$id, body: \$b) { $_remarkFields } }', {
        'id': id,
        'b': body,
      }))['updateContactRemark'],
    ),
  );

  Future<void> deleteRemark(String id) async {
    await _g(r'mutation DeleteRemark($id: ID!) { deleteContactRemark(id: $id) }', {'id': id});
  }

  Future<RemarkFile> uploadRemarkFile(String contactId, Uint8List bytes, String mime, String name) async =>
      RemarkFile.fromJson(await api.upload('/inbox/contacts/${Uri.encodeComponent(contactId)}/remark-files', bytes, mime, query: {'name': name}));

  Future<ContactProfile> contact(String id) async =>
      ContactProfile(Map<String, dynamic>.from((await _g('query Contact(\$id: ID!) { contact(id: \$id) { $_contactFields } }', {'id': id}))['contact']));

  Future<ContactProfile> updateContact(String id, Map<String, dynamic> input) async => ContactProfile(
    Map<String, dynamic>.from(
      (await _g('mutation UpdateContact(\$id: ID!, \$i: ContactInput!) { updateContact(id: \$id, input: \$i) { $_contactFields } }', {
        'id': id,
        'i': input,
      }))['updateContact'],
    ),
  );

  Future<ContactProfile> setCustomValue(String contactId, String propertyId, String? value) async => ContactProfile(
    Map<String, dynamic>.from(
      (await _g(
        'mutation SetValue(\$c: ID!, \$p: ID!, \$v: String) { setContactCustomValue(contactId: \$c, propertyId: \$p, value: \$v) { $_contactFields } }',
        {'c': contactId, 'p': propertyId, 'v': value},
      ))['setContactCustomValue'],
    ),
  );

  Future<void> deleteContact(String id) async {
    await _g(r'mutation DeleteContact($id: ID!) { deleteContact(id: $id) }', {'id': id});
  }

  Future<ContactFieldOptions> fieldOptions() async => ContactFieldOptions.fromJson(
    Map<String, dynamic>.from(
      (await _g(
        'query Options { contactFieldOptions { leadStages { $_stageFields } leadSources { value label } priorities { value label } remarkMaxLength } }',
      ))['contactFieldOptions'],
    ),
  );

  Future<List<CustomProperty>> customProperties() async => ((await _g('{ customProperties { id name key type options } }'))['customProperties'] as List)
      .map((e) => CustomProperty.fromJson(Map<String, dynamic>.from(e)))
      .toList();

  Future<List<({String id, String name})>> contactLists() async =>
      ((await _g('query Lists { contactLists { id name } }'))['contactLists'] as List).map((e) => (id: e['id'] as String, name: e['name'] as String)).toList();

  Future<void> setContactList(String contactId, String listId, bool add) async {
    final f = add ? 'addContactToList' : 'removeContactFromList';
    await _g('mutation CL(\$c: ID!, \$l: ID!) { $f(contactId: \$c, listId: \$l) { id } }', {'c': contactId, 'l': listId});
  }

  Future<({String channel, DateTime? lastOutboundAt, DateTime? lastInboundAt})> chatDetails(String conversationId) async {
    final c = (await _g(r'query ChatDetails($id: ID!) { conversation(id: $id) { channel lastOutboundAt lastInboundAt } }', {
      'id': conversationId,
    }))['conversation'];
    return (
      channel: (c['channel'] ?? '') as String,
      lastOutboundAt: c['lastOutboundAt'] == null ? null : DateTime.tryParse(c['lastOutboundAt']),
      lastInboundAt: c['lastInboundAt'] == null ? null : DateTime.tryParse(c['lastInboundAt']),
    );
  }

  Future<List<ChatFile>> chatFiles(String conversationId) async =>
      ((await _g(r'query ChatFiles($c: ID!) { chatFiles(conversationId: $c) { id type direction createdAt mediaMime mediaName mediaSize available } }', {
                'c': conversationId,
              }))['chatFiles']
              as List)
          .map((e) => ChatFile.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  // ---------------------------------------------------------------- Templates and quick replies

  /// The account's approved templates (never Meta's sample), live from Meta through the server
  Future<List<MessageTemplate>> approvedTemplates() async =>
      ((await _g('query Templates { messageTemplates { $_templateFields } }'))['messageTemplates'] as List)
          .map((e) => MessageTemplate.fromJson(Map<String, dynamic>.from(e)))
          .where((t) => t.status == 'APPROVED' && !metaSampleTemplates.contains(t.name))
          .toList();

  Future<List<MessageTemplate>> allTemplates() async =>
      ((await _g('query AllTemplates { allMessageTemplates { $_templateFields } }'))['allMessageTemplates'] as List)
          .map((e) => MessageTemplate.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  Future<void> deleteTemplate(String name, String? id) async {
    await _g(r'mutation DeleteTemplate($n: String!, $id: ID) { deleteMessageTemplate(name: $n, id: $id) }', {'n': name, 'id': id});
  }

  /// Sent only after the agent's "Yes, Send"; requestId is made once per confirmation so a retry can't send twice
  Future<Message> sendTemplate(
    String conversationId,
    MessageTemplate t,
    Map<String, Map<String, String>> values,
    String requestId, {
    ({Uint8List bytes, String mime, String name})? headerFile,
  }) async {
    if (t.mediaHeader != null) {
      if (headerFile == null) throw ApiException('Choose the header ${t.mediaHeader!.toLowerCase()}');
      final json = await api.upload(
        '/inbox/conversations/${Uri.encodeComponent(conversationId)}/template',
        headerFile.bytes,
        headerFile.mime,
        query: {'name': t.name, 'language': t.language, 'values': jsonEncode(values), 'fileName': headerFile.name, 'confirmed': 'true', 'requestId': requestId},
      );
      return Message.fromJson(json);
    }
    return Message.fromJson(
      Map<String, dynamic>.from(
        (await _g('mutation SendTemplate(\$input: SendTemplateInput!) { sendTemplateMessage(input: \$input) { $_baseMessageFields } }', {
          'input': {
            'conversationId': conversationId,
            'name': t.name,
            'language': t.language,
            'values': jsonEncode(values),
            'confirmed': true,
            'requestId': requestId,
          },
        }))['sendTemplateMessage'],
      ),
    );
  }

  Future<List<QuickReply>> quickReplies([String? search]) async =>
      ((await _g(r'query QuickReplies($s: String) { quickReplies(search: $s, first: 100) { id shortcut description category } }', {
                's': (search?.isEmpty ?? true) ? null : search,
              }))['quickReplies']
              as List)
          .map((e) => QuickReply.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  // ---------------------------------------------------------------- Push notifications (this phone)

  Future<bool> pushConfigured() async => (await _g('query PushConfigured { pushConfigured }'))['pushConfigured'] == true;

  /// false: the server can't send push (not configured), nothing stored
  Future<bool> registerPushDevice(String token, String platform) async =>
      (await _g(r'mutation RegisterPush($t: String!, $p: String!) { registerPushDevice(token: $t, platform: $p) }', {'t': token, 'p': platform}))['registerPushDevice'] == true;

  Future<void> unregisterPushDevice(String token) async {
    await _g(r'mutation UnregisterPush($t: String!) { unregisterPushDevice(token: $t) }', {'t': token});
  }

  // ---------------------------------------------------------------- Notifications

  Future<({List<Activity> items, DateTime? seenAt})> notifications() async {
    final n = (await _g('query Notifications { notifications(first: 100) { seenAt items { $_activityFields } } }'))['notifications'];
    return (
      items: (n['items'] as List).map((e) => Activity.fromJson(Map<String, dynamic>.from(e))).toList(),
      seenAt: n['seenAt'] == null ? null : DateTime.tryParse(n['seenAt']),
    );
  }

  Future<void> markNotificationsSeen() async {
    await _g('mutation SeenNotifications { markNotificationsSeen }');
  }

  // ---------------------------------------------------------------- Admin settings

  Future<List<TeamMember>> members() async => ((await _g('query TeamMembers { members { $_memberFields } }'))['members'] as List)
      .map((e) => TeamMember.fromJson(Map<String, dynamic>.from(e)))
      .toList();

  Future<({bool invited, bool emailSent})> inviteMember(Map<String, dynamic> input) async {
    final r = (await _g(
      'mutation InviteMember(\$input: InviteMemberInput!) { inviteMember(input: \$input) { invited emailSent created member { $_memberFields } } }',
      {'input': input},
    ))['inviteMember'];
    return (invited: r['invited'] == true, emailSent: r['emailSent'] == true);
  }

  Future<void> updateMemberRole(String userId, String role) async {
    await _g('mutation UpdateMemberRole(\$userId: ID!, \$role: String!) { updateMemberRole(userId: \$userId, role: \$role) { $_memberFields } }', {
      'userId': userId,
      'role': role,
    });
  }

  Future<void> setMemberActive(String userId, bool active) async {
    await _g('mutation SetMemberActive(\$userId: ID!, \$active: Boolean!) { setMemberActive(userId: \$userId, active: \$active) { $_memberFields } }', {
      'userId': userId,
      'active': active,
    });
  }

  Future<void> setLabelPermission(String userId, bool can) async {
    await _g(r'mutation P($u: ID!, $c: Boolean!) { setLabelPermission(userId: $u, canManageLabels: $c) { userId } }', {'u': userId, 'c': can});
  }

  Future<Map<String, dynamic>> workspaceSettings() async => Map<String, dynamic>.from(
    (await _g(
      '{ workspaceSettings { defaultTimeZone defaultCountry businessDayStartHour reminderMinutes awayMinutes deletedContactRetentionDays } }',
    ))['workspaceSettings'],
  );

  Future<void> updateWorkspaceSettings(Map<String, dynamic> input) async {
    await _g(r'mutation S($i: WorkspaceSettingsInput!) { updateWorkspaceSettings(input: $i) { defaultTimeZone } }', {'i': input});
  }

  Future<String> renameWorkspace(String name) async =>
      (await _g(r'mutation RenameWorkspace($n: String!) { renameWorkspace(name: $n) }', {'n': name}))['renameWorkspace'];

  Future<Map<String, dynamic>> automationSettings() async => Map<String, dynamic>.from(
    (await _g(
      '{ automationSettings { enabled workingHours { day start end } replyInHoursEnabled replyInHours replyOutHoursEnabled replyOutHours cooldownHours routingEnabled routingMode routingMemberIds routingOnlineOnly timeZone replyMaxLength } }',
    ))['automationSettings'],
  );

  Future<void> updateAutomationSettings(Map<String, dynamic> input) async {
    await _g(r'mutation A($i: AutomationSettingsInput!) { updateAutomationSettings(input: $i) { enabled } }', {'i': input});
  }

  Future<List<Map<String, dynamic>>> assignmentReport({DateTime? from, DateTime? to}) async =>
      ((await _g(
                r'query R($f: DateTime, $t: DateTime) { assignmentReport(from: $f, to: $t, first: 500) { id conversationId contactName contactWaId previousAssignee { name } newAssignee { name } assignedBy { name } reason createdAt } }',
                {'f': from?.toUtc().toIso8601String(), 't': to?.toUtc().toIso8601String()},
              ))['assignmentReport']
              as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
}
