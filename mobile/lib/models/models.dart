// Data shapes returned by the GraphQL API (the same fields the website asks for).

DateTime? _date(dynamic v) => v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toUtc() : null;
String? _str(dynamic v) => v is String ? v : null;
int _int(dynamic v, [int fallback = 0]) => v is int ? v : (v is num ? v.toInt() : fallback);
List<Map<String, dynamic>> _list(dynamic v) => v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];

class Contact {
  Contact({required this.id, required this.waId, this.name, this.leadStage, this.country});
  final String id;
  final String waId;
  final String? name;
  final String? leadStage;
  final String? country;

  /// The customer's name, or their number with a +
  String get display => (name != null && name!.trim().isNotEmpty) ? name!.trim() : '+$waId';

  factory Contact.fromJson(Map<String, dynamic> j) =>
      Contact(id: j['id'], waId: j['waId'] ?? '', name: _str(j['name']), leadStage: _str(j['leadStage']), country: _str(j['country']));

  Contact copyWith({String? name, String? leadStage, String? country, bool clearStage = false}) =>
      Contact(id: id, waId: waId, name: name ?? this.name, leadStage: clearStage ? null : (leadStage ?? this.leadStage), country: country ?? this.country);
}

class QuotedMessage {
  QuotedMessage({required this.id, required this.direction, required this.type, required this.body, this.senderName, required this.deleted, this.mediaMime, this.mediaName});
  final String id;
  final String direction;
  final String type;
  final String body;
  final String? senderName;
  final bool deleted;
  final String? mediaMime;
  final String? mediaName;

  factory QuotedMessage.fromJson(Map<String, dynamic> j) => QuotedMessage(
        id: j['id'],
        direction: j['direction'] ?? 'in',
        type: j['type'] ?? 'text',
        body: j['body'] ?? '',
        senderName: _str(j['senderName']),
        deleted: j['deleted'] == true,
        mediaMime: _str(j['mediaMime']),
        mediaName: _str(j['mediaName']),
      );
}

class Message {
  Message({
    required this.id,
    required this.conversationId,
    required this.direction,
    required this.type,
    required this.body,
    required this.status,
    this.error,
    required this.createdAt,
    this.sentById,
    this.senderName,
    this.editedAt,
    this.deletedAt,
    required this.version,
    this.mediaMime,
    this.mediaSize,
    this.mediaName,
    this.customerReaction,
    this.teamReaction,
    this.teamReactionById,
    this.automation,
    this.replyToId,
    this.replyTo,
  });

  final String id;
  final String conversationId;
  final String direction; // in | out
  final String type;
  final String body;
  final String status; // pending | sent | delivered | read | failed | received
  final String? error;
  final DateTime createdAt;
  final String? sentById;
  final String? senderName;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final int version;
  final String? mediaMime;
  final int? mediaSize;
  final String? mediaName;
  final String? customerReaction;
  final String? teamReaction;
  final String? teamReactionById;
  final String? automation;
  final String? replyToId;
  final QuotedMessage? replyTo;

  bool get isOut => direction == 'out';
  bool get isDeleted => deletedAt != null;

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: j['id'],
        conversationId: j['conversationId'] ?? '',
        direction: j['direction'] ?? 'in',
        type: j['type'] ?? 'text',
        body: j['body'] ?? '',
        status: j['status'] ?? 'sent',
        error: _str(j['error']),
        createdAt: _date(j['createdAt']) ?? DateTime.now().toUtc(),
        sentById: _str(j['sentById']),
        senderName: _str(j['senderName']),
        editedAt: _date(j['editedAt']),
        deletedAt: _date(j['deletedAt']),
        version: _int(j['version']),
        mediaMime: _str(j['mediaMime']),
        mediaSize: j['mediaSize'] is num ? (j['mediaSize'] as num).toInt() : null,
        mediaName: _str(j['mediaName']),
        customerReaction: _str(j['customerReaction']),
        teamReaction: _str(j['teamReaction']),
        teamReactionById: _str(j['teamReactionById']),
        automation: _str(j['automation']),
        replyToId: _str(j['replyToId']),
        replyTo: j['replyTo'] is Map ? QuotedMessage.fromJson(Map<String, dynamic>.from(j['replyTo'])) : null,
      );

  /// Socket events and responses can arrive out of order: keep whichever copy is newest (web: newerMessage)
  Message newer(Message incoming) {
    if (incoming.version >= version) {
      return incoming._withSender(incoming.senderName ?? senderName, incoming.replyTo ?? replyTo);
    }
    return _withStatus(incoming.status, incoming.error);
  }

  Message _withSender(String? name, QuotedMessage? quote) => Message(
        id: id, conversationId: conversationId, direction: direction, type: type, body: body, status: status, error: error,
        createdAt: createdAt, sentById: sentById, senderName: name, editedAt: editedAt, deletedAt: deletedAt, version: version,
        mediaMime: mediaMime, mediaSize: mediaSize, mediaName: mediaName, customerReaction: customerReaction,
        teamReaction: teamReaction, teamReactionById: teamReactionById, automation: automation, replyToId: replyToId, replyTo: quote,
      );

  Message _withStatus(String s, String? e) => Message(
        id: id, conversationId: conversationId, direction: direction, type: type, body: body, status: s, error: e,
        createdAt: createdAt, sentById: sentById, senderName: senderName, editedAt: editedAt, deletedAt: deletedAt, version: version,
        mediaMime: mediaMime, mediaSize: mediaSize, mediaName: mediaName, customerReaction: customerReaction,
        teamReaction: teamReaction, teamReactionById: teamReactionById, automation: automation, replyToId: replyToId, replyTo: replyTo,
      );
}

class LabelRef {
  LabelRef({required this.id, required this.name, required this.color});
  final String id;
  final String name;
  final String color;
  factory LabelRef.fromJson(Map<String, dynamic> j) => LabelRef(id: j['id'], name: j['name'] ?? '', color: j['color'] ?? '#25d366');
}

class Label extends LabelRef {
  Label({required super.id, required super.name, required super.color, required this.conversationCount});
  final int conversationCount;
  factory Label.fromJson(Map<String, dynamic> j) =>
      Label(id: j['id'], name: j['name'] ?? '', color: j['color'] ?? '#25d366', conversationCount: _int(j['conversationCount']));
}

class AssigneeRef {
  AssigneeRef({required this.id, required this.name, required this.color, this.userId});
  final String id; // member id
  final String name;
  final String color;
  final String? userId;
  factory AssigneeRef.fromJson(Map<String, dynamic> j) =>
      AssigneeRef(id: j['id'], name: j['name'] ?? '', color: j['color'] ?? '#047857', userId: _str(j['userId']));
}

class Assignee extends AssigneeRef {
  Assignee({required super.id, required super.name, required super.color, super.userId, required this.conversationCount});
  final int conversationCount;
  factory Assignee.fromJson(Map<String, dynamic> j) => Assignee(
      id: j['id'], name: j['name'] ?? '', color: j['color'] ?? '#047857', userId: _str(j['userId']), conversationCount: _int(j['conversationCount']));
}

class WorkspaceMember {
  WorkspaceMember({required this.id, required this.name, required this.email, required this.role});
  final String id; // user id
  final String name;
  final String email;
  final String role;
  factory WorkspaceMember.fromJson(Map<String, dynamic> j) =>
      WorkspaceMember(id: j['id'], name: j['name'] ?? '', email: j['email'] ?? '', role: j['role'] ?? 'agent');
}

class Conversation {
  Conversation({
    required this.id,
    required this.contact,
    required this.unread,
    required this.lastMessageAt,
    this.lastInboundAt,
    this.lastMessage,
    required this.labels,
    this.assignee,
    this.assigneeOpenedAt,
    required this.status,
    this.closedAt,
    this.closedById,
    this.snoozedUntil,
    required this.pinned,
    required this.isCollaborator,
    required this.wasAssigned,
  });

  final String id;
  Contact contact;
  int unread;
  DateTime lastMessageAt;
  DateTime? lastInboundAt;
  Message? lastMessage;
  List<LabelRef> labels;
  AssigneeRef? assignee;
  DateTime? assigneeOpenedAt;
  String status; // open | snoozed | closed
  DateTime? closedAt;
  String? closedById;
  DateTime? snoozedUntil;
  bool pinned;
  bool isCollaborator;
  bool wasAssigned;

  /// New Leads: open chats nobody holds right now (web: isNewLead)
  bool get isNewLead => assignee == null && status == 'open';

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'],
        contact: Contact.fromJson(Map<String, dynamic>.from(j['contact'] ?? {'id': '', 'waId': ''})),
        unread: _int(j['unread']),
        lastMessageAt: _date(j['lastMessageAt']) ?? DateTime.now().toUtc(),
        lastInboundAt: _date(j['lastInboundAt']),
        lastMessage: j['lastMessage'] is Map ? Message.fromJson(Map<String, dynamic>.from(j['lastMessage'])) : null,
        labels: _list(j['labels']).map(LabelRef.fromJson).toList(),
        assignee: j['assignee'] is Map ? AssigneeRef.fromJson(Map<String, dynamic>.from(j['assignee'])) : null,
        assigneeOpenedAt: _date(j['assigneeOpenedAt']),
        status: j['status'] ?? 'open',
        closedAt: _date(j['closedAt']),
        closedById: _str(j['closedById']),
        snoozedUntil: _date(j['snoozedUntil']),
        pinned: j['pinned'] == true,
        isCollaborator: j['isCollaborator'] == true,
        wasAssigned: j['wasAssigned'] == true,
      );
}

class Page<T> {
  Page(this.nodes, this.hasNextPage, this.endCursor);
  final List<T> nodes;
  final bool hasNextPage;
  final String? endCursor;
}

class ConversationCounts {
  ConversationCounts({this.open = 0, this.closed = 0, this.closedWithUnread = 0, this.snoozed = 0, this.unassigned = 0, this.newLeads = 0});
  final int open, closed, closedWithUnread, snoozed, unassigned, newLeads;
  factory ConversationCounts.fromJson(Map<String, dynamic> j) => ConversationCounts(
      open: _int(j['open']), closed: _int(j['closed']), closedWithUnread: _int(j['closedWithUnread']),
      snoozed: _int(j['snoozed']), unassigned: _int(j['unassigned']), newLeads: _int(j['newLeads']));
}

class RemarkFile {
  RemarkFile({required this.id, required this.name, required this.mime, required this.size});
  final String id;
  final String name;
  final String mime;
  final int size;
  bool get isImage => mime.startsWith('image/');
  factory RemarkFile.fromJson(Map<String, dynamic> j) => RemarkFile(id: j['id'], name: j['name'] ?? 'file', mime: j['mime'] ?? '', size: _int(j['size']));
}

/// Internal note about a customer (yellow bubble in the chat). Never sent to WhatsApp.
class ContactRemark {
  ContactRemark({required this.id, required this.contactId, required this.body, this.createdById, this.authorName, required this.createdAt, this.editedAt, required this.files});
  final String id;
  final String contactId;
  final String body;
  final String? createdById;
  final String? authorName;
  final DateTime createdAt;
  final DateTime? editedAt;
  final List<RemarkFile> files;
  factory ContactRemark.fromJson(Map<String, dynamic> j) => ContactRemark(
        id: j['id'],
        contactId: j['contactId'] ?? '',
        body: j['body'] ?? '',
        createdById: _str(j['createdById']),
        authorName: _str(j['authorName']),
        createdAt: _date(j['createdAt']) ?? DateTime.now().toUtc(),
        editedAt: _date(j['editedAt']),
        files: _list(j['files']).map(RemarkFile.fromJson).toList(),
      );
}

class Activity {
  Activity({required this.id, required this.type, this.conversationId, this.actorId, this.actorName, this.contactName, this.data, required this.createdAt});
  final String id;
  final String type;
  final String? conversationId;
  final String? actorId;
  final String? actorName;
  final String? contactName;
  final String? data;
  final DateTime createdAt;
  factory Activity.fromJson(Map<String, dynamic> j) => Activity(
        id: j['id'],
        type: j['type'] ?? '',
        conversationId: _str(j['conversationId']),
        actorId: _str(j['actorId']),
        actorName: _str(j['actorName']),
        contactName: _str(j['contactName']),
        data: j['data'] is String ? j['data'] : j['data']?.toString(),
        createdAt: _date(j['createdAt']) ?? DateTime.now().toUtc(),
      );
}

class TemplateHeader {
  TemplateHeader({required this.format, required this.text, required this.variables});
  final String format; // TEXT | IMAGE | VIDEO | DOCUMENT | LOCATION
  final String text;
  final List<String> variables;
  factory TemplateHeader.fromJson(Map<String, dynamic> j) =>
      TemplateHeader(format: j['format'] ?? 'TEXT', text: j['text'] ?? '', variables: List<String>.from(j['variables'] ?? const []));
}

class TemplateButton {
  TemplateButton({required this.type, required this.text, this.url, this.phoneNumber, required this.variables});
  final String type;
  final String text;
  final String? url;
  final String? phoneNumber;
  final List<String> variables;
  factory TemplateButton.fromJson(Map<String, dynamic> j) => TemplateButton(
      type: j['type'] ?? '', text: j['text'] ?? '', url: _str(j['url']), phoneNumber: _str(j['phoneNumber']), variables: List<String>.from(j['variables'] ?? const []));
}

class MessageTemplate {
  MessageTemplate({
    required this.id,
    required this.name,
    required this.language,
    required this.category,
    required this.status,
    this.rejectedReason,
    required this.parameterFormat,
    this.header,
    required this.body,
    required this.bodyVariables,
    this.footer,
    required this.buttons,
    required this.needsParameters,
    required this.sendable,
    this.unsupportedReason,
  });
  final String id, name, language, category, status, parameterFormat, body;
  final String? rejectedReason, footer, unsupportedReason;
  final TemplateHeader? header;
  final List<String> bodyVariables;
  final List<TemplateButton> buttons;
  final bool needsParameters, sendable;

  /// IMAGE / VIDEO / DOCUMENT when the header is a file the agent has to choose
  String? get mediaHeader => header != null && const ['IMAGE', 'VIDEO', 'DOCUMENT'].contains(header!.format) ? header!.format : null;

  factory MessageTemplate.fromJson(Map<String, dynamic> j) => MessageTemplate(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        language: j['language'] ?? '',
        category: j['category'] ?? '',
        status: j['status'] ?? '',
        rejectedReason: _str(j['rejectedReason']),
        parameterFormat: j['parameterFormat'] ?? 'POSITIONAL',
        header: j['header'] is Map ? TemplateHeader.fromJson(Map<String, dynamic>.from(j['header'])) : null,
        body: j['body'] ?? '',
        bodyVariables: List<String>.from(j['bodyVariables'] ?? const []),
        footer: _str(j['footer']),
        buttons: _list(j['buttons']).map(TemplateButton.fromJson).toList(),
        needsParameters: j['needsParameters'] == true,
        sendable: j['sendable'] != false,
        unsupportedReason: _str(j['unsupportedReason']),
      );
}

class QuickReply {
  QuickReply({required this.id, required this.shortcut, this.description, this.category});
  final String id;
  final String shortcut;
  final String? description;
  final String? category;
  factory QuickReply.fromJson(Map<String, dynamic> j) =>
      QuickReply(id: j['id'], shortcut: j['shortcut'] ?? '', description: _str(j['description']), category: _str(j['category']));
}

class ContactOption {
  ContactOption({required this.value, required this.label, this.id, this.color, this.closed, this.isDefault});
  final String value;
  final String label;
  final String? id;
  final String? color;
  final bool? closed;
  final bool? isDefault;
  factory ContactOption.fromJson(Map<String, dynamic> j) => ContactOption(
      value: j['value'] ?? '', label: j['label'] ?? '', id: _str(j['id']), color: _str(j['color']), closed: j['closed'] as bool?, isDefault: j['isDefault'] as bool?);
}

class ContactFieldOptions {
  ContactFieldOptions({required this.leadStages, required this.leadSources, required this.priorities, required this.remarkMaxLength});
  final List<ContactOption> leadStages, leadSources, priorities;
  final int remarkMaxLength;
  factory ContactFieldOptions.fromJson(Map<String, dynamic> j) => ContactFieldOptions(
        leadStages: _list(j['leadStages']).map(ContactOption.fromJson).toList(),
        leadSources: _list(j['leadSources']).map(ContactOption.fromJson).toList(),
        priorities: _list(j['priorities']).map(ContactOption.fromJson).toList(),
        remarkMaxLength: _int(j['remarkMaxLength'], 16000),
      );
  ContactOption? stage(String? value) => value == null ? null : leadStages.where((s) => s.value == value).firstOrNull;
}

class ContactProfile {
  ContactProfile(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'];
  String get waId => json['waId'] ?? '';
  String? get name => _str(json['name']);
  String? field(String key) => _str(json[key]);
  bool get subscribed => json['subscribed'] != false;
  String? get conversationId => _str(json['conversationId']);
  List<({String id, String name})> get lists => _list(json['lists']).map((l) => (id: l['id'] as String, name: (l['name'] ?? '') as String)).toList();
  Map<String, String> get customValues => {for (final v in _list(json['customValues'])) v['propertyId'] as String: (v['value'] ?? '') as String};
  DateTime? get createdAt => _date(json['createdAt']);
}

class CustomProperty {
  CustomProperty({required this.id, required this.name, required this.key, required this.type, required this.options});
  final String id, name, key, type;
  final List<String> options;
  factory CustomProperty.fromJson(Map<String, dynamic> j) =>
      CustomProperty(id: j['id'], name: j['name'] ?? '', key: j['key'] ?? '', type: j['type'] ?? 'text', options: List<String>.from(j['options'] ?? const []));
}

class ChatFile {
  ChatFile({required this.id, required this.type, required this.direction, required this.createdAt, this.mediaMime, this.mediaName, this.mediaSize, required this.available});
  final String id, type, direction;
  final DateTime createdAt;
  final String? mediaMime, mediaName;
  final int? mediaSize;
  final bool available;
  factory ChatFile.fromJson(Map<String, dynamic> j) => ChatFile(
      id: j['id'], type: j['type'] ?? '', direction: j['direction'] ?? 'in', createdAt: _date(j['createdAt']) ?? DateTime.now().toUtc(),
      mediaMime: _str(j['mediaMime']), mediaName: _str(j['mediaName']), mediaSize: j['mediaSize'] is num ? (j['mediaSize'] as num).toInt() : null, available: j['available'] == true);
}

class TeamMember {
  TeamMember({required this.userId, required this.name, required this.email, required this.role, required this.isOwner, required this.canManageLabels, required this.active, required this.status});
  final String userId, name, email, role, status;
  final bool isOwner, canManageLabels, active;
  factory TeamMember.fromJson(Map<String, dynamic> j) => TeamMember(
      userId: j['userId'], name: j['name'] ?? '', email: j['email'] ?? '', role: j['role'] ?? 'agent', isOwner: j['isOwner'] == true,
      canManageLabels: j['canManageLabels'] == true, active: j['active'] != false, status: j['status'] ?? 'active');
}

class WorkspaceSummary {
  WorkspaceSummary({required this.id, required this.name, required this.role});
  final String id, name, role;
  factory WorkspaceSummary.fromJson(Map<String, dynamic> j) => WorkspaceSummary(id: j['id'], name: j['name'] ?? '', role: j['role'] ?? 'agent');
}
