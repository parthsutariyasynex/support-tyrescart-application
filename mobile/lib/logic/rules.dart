import 'dart:convert';

import '../models/models.dart';
import 'time.dart';

// Business rules shared with the website (client/lib/*.ts). The server enforces every one of them again; these only
// decide what the app offers, so a refused action is never offered in the first place.

// ---------------------------------------------------------------- WhatsApp's 24-hour window (messagingWindow.ts)

const windowLength = Duration(hours: 24);

/// Free-form messages are allowed for 24 hours after the customer's last message (the server's lastInboundAt)
bool windowOpen(DateTime? lastInboundAt, [DateTime? now]) =>
    lastInboundAt != null && (now ?? DateTime.now()).toUtc().difference(lastInboundAt.toUtc()) < windowLength;

/// Time left before the window closes (null: closed, or the customer never wrote)
Duration? timeUntilClose(DateTime? lastInboundAt, [DateTime? now]) {
  if (!windowOpen(lastInboundAt, now)) return null;
  return lastInboundAt!.toUtc().add(windowLength).difference((now ?? DateTime.now()).toUtc());
}

// ---------------------------------------------------------------- Text limits (textLimits.ts, media.ts)

const whatsappTextMax = 4096;
const captionMax = 1024;
const imageMaxBytes = 5 * 1024 * 1024;
const documentMaxBytes = 100 * 1024 * 1024;
const voiceMaxBytes = 16 * 1024 * 1024;
const noteFilesMax = 10;

String tooLongText(int length, int max) {
  String f(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${f(length)} / ${f(max)} characters: WhatsApp allows up to ${f(max)}. Shorten it or send it in parts.';
}

// ---------------------------------------------------------------- Files (media.ts)

const imageTypes = ['image/jpeg', 'image/png'];
const documentTypes = <String, String>{
  'application/pdf': 'pdf',
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'application/vnd.ms-excel': 'xls',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  'application/vnd.ms-powerpoint': 'ppt',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
  'text/plain': 'txt',
};

/// The file's type from what the system says or its extension (some pickers report none for .docx)
String fileType(String name, String? reported) {
  if (reported != null && (imageTypes.contains(reported) || documentTypes.containsKey(reported))) return reported;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (ext == 'jpg' || ext == 'jpeg') return 'image/jpeg';
  if (ext == 'png') return 'image/png';
  for (final e in documentTypes.entries) {
    if (e.value == ext) return e.key;
  }
  return reported ?? 'application/octet-stream';
}

sealed class FileCheck {}

class FileOk extends FileCheck {
  FileOk(this.image, this.mime);
  final bool image;
  final String mime;
}

class FileProblem extends FileCheck {
  FileProblem(this.message);
  final String message;
}

/// What a file can be sent as in the chat, or why it can't (checked before upload)
FileCheck checkFile(String name, String? reported, int size) {
  final type = fileType(name, reported);
  final image = imageTypes.contains(type);
  if (!image && !documentTypes.containsKey(type)) {
    return FileProblem("This file type can't be sent. Send a JPEG or PNG image, or a PDF, Word, Excel, PowerPoint or text file.");
  }
  if (size == 0) return FileProblem('That file is empty.');
  final max = image ? imageMaxBytes : documentMaxBytes;
  if (size > max) return FileProblem('That ${image ? 'image' : 'document'} is ${formatSize(size)}. ${image ? 'Images can be up to 5 MB' : 'Documents can be up to 100 MB'}.');
  return FileOk(image, type);
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

String documentLabel(String? mime, [String? name]) =>
    (documentTypes[mime ?? ''] ?? ((name?.contains('.') ?? false) ? name!.split('.').last : 'file')).toUpperCase();

bool isMediaPlaceholder(String body) => RegExp(r'^\[(image|video|audio|document|sticker)\]$').hasMatch(body.trim());

/// Chat list preview for a file message: "📷 caption" / "📷 Photo", "🎥 Video", "🎤 Voice message"…
String? filePreview(String type, String body, [String? mediaName]) {
  final text = body.isNotEmpty && !isMediaPlaceholder(body) ? body : '';
  switch (type) {
    case 'image':
      return '📷 ${text.isEmpty ? 'Photo' : text}';
    case 'sticker':
      return '🙂 Sticker';
    case 'video':
      return '🎥 ${text.isEmpty ? 'Video' : text}';
    case 'voice':
      return '🎤 Voice message';
    case 'audio':
      return '🎵 Audio';
    case 'document':
      return '📄 ${(mediaName?.isNotEmpty ?? false) ? mediaName : (text.isEmpty ? 'Document' : text)}';
    case 'location':
      return '📍 Location';
    case 'contacts':
      return '👤 Contact';
    default:
      return null;
  }
}

String quotePreview(QuotedMessage q) => q.deleted ? 'This message was deleted' : (filePreview(q.type, q.body, q.mediaName) ?? q.body);

String messagePreview(Message? m) {
  if (m == null) return '';
  if (m.isDeleted) return 'This message was deleted';
  return filePreview(m.type, m.body, m.mediaName) ?? m.body;
}

// ---------------------------------------------------------------- Message actions (messages.tsx, forward.ts)

enum MessageAction { reply, react, forward, copy, edit, delete, info }

/// Which actions the viewer gets on a message (web: messageActions)
List<MessageAction> messageActions(Message m, {required String? userId, required bool isAdmin, required bool canReply}) {
  if (m.isDeleted) return const [];
  final out = <MessageAction>[];
  if (canReply && m.status != 'pending') out.addAll([MessageAction.reply, MessageAction.react]);
  if (m.status != 'pending' && forwardKind(m) != null) out.add(MessageAction.forward);
  if (m.body.isNotEmpty && !isMediaPlaceholder(m.body)) out.add(MessageAction.copy);
  final mine = m.isOut && userId != null && (isAdmin || m.sentById == userId);
  if (mine && m.type == 'text') out.add(MessageAction.edit);
  if (mine) out.add(MessageAction.delete);
  if (m.isOut) out.add(MessageAction.info);
  return out;
}

/// What a message can be forwarded as: only what this app can send (web: forwardKind)
String? forwardKind(Message m) {
  if (m.isDeleted) return null;
  final mime = (m.mediaMime ?? '').split(';').first.trim().toLowerCase();
  if (m.type == 'image') return imageTypes.contains(mime) ? 'image' : null;
  if (m.type == 'document') return documentTypes.containsKey(mime) ? 'document' : null;
  if (m.type == 'voice') return RegExp(r'^audio/(ogg|webm|mp4)$').hasMatch(mime) ? 'voice' : null;
  if (const ['video', 'audio', 'sticker'].contains(m.type)) return null;
  final text = m.body.trim();
  return text.isNotEmpty && !isMediaPlaceholder(text) && !text.startsWith('[template]') ? 'text' : null;
}

/// Why a chat can't take a forwarded message right now ('' = it can)
String forwardBlocked(Conversation c, [DateTime? now]) {
  if (c.status == 'closed') return 'Closed: reopen it to write';
  if (!windowOpen(c.lastInboundAt, now)) return '24-hour window closed: only templates can be sent';
  return '';
}

// ---------------------------------------------------------------- Chat list (inbox.ts)

/// The search box applied at once to the chats on screen while the server search refreshes (web: matchesSearch)
bool matchesSearch(Conversation c, String query) {
  final term = query.trim().toLowerCase();
  if (term.isEmpty) return true;
  final digits = term.replaceAll(RegExp(r'\D'), '');
  if ((c.contact.name ?? '').toLowerCase().contains(term)) return true;
  if (digits.length >= 3 && c.contact.waId.contains(digits)) return true;
  if (c.lastMessage != null && !c.lastMessage!.isDeleted && c.lastMessage!.body.toLowerCase().contains(term)) return true;
  if (c.labels.any((l) => l.name.toLowerCase().contains(term))) return true;
  if (c.assignee != null && c.assignee!.name.toLowerCase().contains(term)) return true;
  if (term == c.status) return true;
  if (term == 'unread') return c.unread > 0;
  if (term == 'unassigned') return c.assignee == null;
  if (term == 'assigned') return c.assignee != null;
  return false;
}

/// Bold row: unread customer messages, or assigned to you and not opened since (web: needsAttention)
bool needsAttention(Conversation c, String? meId) {
  if (c.unread > 0) return true;
  return c.status == 'open' && meId != null && c.assignee?.userId == meId && c.assigneeOpenedAt == null;
}

bool isAssignedTo(Conversation c, String? userId) => userId != null && c.assignee?.userId != null && c.assignee!.userId == userId;

// ---------------------------------------------------------------- @mentions (mentions.ts)

/// The @word being typed right before the cursor, or null ("email@x" doesn't count: the @ must start a word)
({int start, String query})? mentionAt(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  final before = text.substring(0, caret);
  final m = RegExp(r'(^|\s)@([\p{L}\p{N}._-]*)$', unicode: true).firstMatch(before);
  if (m == null) return null;
  final q = m.group(2)!;
  return (start: before.length - q.length - 1, query: q);
}

/// Teammates whose name or email matches: name starts with it, then a word of the name, then anywhere
List<T> matchMembers<T>(List<T> members, String query, String Function(T) name, String Function(T) email) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return members;
  int rank(T m) {
    final n = name(m).toLowerCase();
    if (n.startsWith(q)) return 0;
    if (n.split(RegExp(r'\s+')).any((w) => w.startsWith(q))) return 1;
    if (n.contains(q) || email(m).toLowerCase().contains(q)) return 2;
    return -1;
  }

  final ranked = [for (var i = 0; i < members.length; i++) (m: members[i], r: rank(members[i]), i: i)].where((x) => x.r >= 0).toList();
  ranked.sort((a, b) => a.r != b.r ? a.r.compareTo(b.r) : a.i.compareTo(b.i)); // ties keep the list's order
  return ranked.map((x) => x.m).toList();
}

/// The text with "@query" replaced by "@Name ", and where the cursor goes
({String text, int caret}) insertMention(String text, ({int start, String query}) at, String name) {
  final end = at.start + 1 + at.query.length;
  final mention = '@$name ';
  final rest = text.substring(end).replaceFirst(RegExp(r'^ '), '');
  return (text: text.substring(0, at.start) + mention + rest, caret: at.start + mention.length);
}

/// A note split into plain text and @mentions of these teammates (longest names first)
List<({String text, bool mention})> mentionPieces(String text, List<String> names) {
  final sorted = {...names.map((n) => n.trim()).where((n) => n.isNotEmpty)}.toList()..sort((a, b) => b.length.compareTo(a.length));
  if (sorted.isEmpty) return [(text: text, mention: false)];
  final re = RegExp('(^|\\s)(@(?:${sorted.map(RegExp.escape).join('|')}))(?![\\p{L}\\p{N}])', unicode: true);
  final out = <({String text, bool mention})>[];
  var last = 0;
  for (final m in re.allMatches(text)) {
    final start = m.start + m.group(1)!.length;
    if (start > last) out.add((text: text.substring(last, start), mention: false));
    out.add((text: m.group(2)!, mention: true));
    last = start + m.group(2)!.length;
  }
  if (last < text.length) out.add((text: text.substring(last), mention: false));
  return out;
}

/// Ids of members whose "@Name" is still in the text (picked mentions the agent didn't delete again)
List<String> mentionedIds(String text, Map<String, String> picked) {
  final out = <String>[];
  for (final e in picked.entries) {
    if (mentionPieces(text, [e.value]).any((p) => p.mention) && !out.contains(e.key)) out.add(e.key);
  }
  return out;
}

// ---------------------------------------------------------------- Templates (templates.ts)

final _varRe = RegExp(r'\{\{\s*([A-Za-z0-9_]+)\s*\}\}');

/// A name the customer doesn't have: WhatsApp refuses an empty value, so it gets a zero-width space instead
const noName = '​';

List<String> variablesOf(String? text) {
  final out = <String>[];
  for (final m in _varRe.allMatches(text ?? '')) {
    if (!out.contains(m.group(1))) out.add(m.group(1)!);
  }
  return out;
}

({String first, String last}) customerNames({String? firstName, String? lastName, String? name}) {
  final words = (name ?? '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  return (
    first: (firstName?.trim().isNotEmpty ?? false) ? firstName!.trim() : (words.isNotEmpty ? words.first : ''),
    last: (lastName?.trim().isNotEmpty ?? false) ? lastName!.trim() : words.skip(1).join(' '),
  );
}

/// {{1}} / first_name is the first name, {{2}} / last_name the last name; anything else is typed by hand
String? nameFor(String variable) {
  if (variable == '1' || RegExp(r'^first_?name$', caseSensitive: false).hasMatch(variable)) return 'first';
  if (variable == '2' || RegExp(r'^last_?name$', caseSensitive: false).hasMatch(variable)) return 'last';
  return null;
}

typedef TemplateValues = Map<String, Map<String, String>>;

TemplateValues emptyValues() => {'header': {}, 'body': {}, 'buttons': {}};

TemplateValues autoFillValues(MessageTemplate t, ({String first, String last}) names) {
  final body = <String, String>{};
  for (final v in t.bodyVariables) {
    final which = nameFor(v);
    if (which != null) {
      final n = which == 'first' ? names.first : names.last;
      body[v] = n.isEmpty ? noName : n;
    }
  }
  return {'header': {}, 'body': body, 'buttons': {}};
}

/// The message as the customer will read it (an unknown name is left out with its space, never shown as {{1}})
String readableMessage(String text, Map<String, String> values) => text
    .replaceAllMapped(_varRe, (m) => (values[m.group(1)] ?? '').replaceAll(noName, '').trim())
    .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
    .replaceAllMapped(RegExp(r' +([,.!?;:])'), (m) => m.group(1)!)
    .split('\n')
    .map((l) => l.trim())
    .join('\n');

/// What still has to be filled in before sending (and the header file)
List<String> missingValues(MessageTemplate t, TemplateValues values, {bool hasFile = false}) {
  final missing = <String>[];
  if (t.mediaHeader != null && !hasFile) missing.add('header ${t.mediaHeader!.toLowerCase()}');
  if (t.header?.format == 'TEXT') {
    for (final v in t.header!.variables) {
      if ((values['header']?[v] ?? '').trim().isEmpty) missing.add('header {{$v}}');
    }
  }
  for (final v in t.bodyVariables) {
    if ((values['body']?[v] ?? '').trim().isEmpty) missing.add('{{$v}}');
  }
  for (var i = 0; i < t.buttons.length; i++) {
    final b = t.buttons[i];
    if ((b.type == 'URL' && b.variables.isNotEmpty) || b.type == 'COPY_CODE') {
      if ((values['buttons']?['$i'] ?? '').trim().isEmpty) missing.add(b.type == 'COPY_CODE' ? 'coupon code' : 'link for "${b.text}"');
    }
  }
  return missing;
}

// ---------------------------------------------------------------- Activity text (activity.ts)

Map<String, dynamic> _details(Activity a) {
  try {
    final d = a.data == null ? null : jsonDecode(a.data!);
    return d is Map ? Map<String, dynamic>.from(d) : {};
  } catch (_) {
    return {};
  }
}

/// One-line description; where = 'chat' (timeline) or 'bell' (names the customer)
String activityText(Activity a, String? meId, {bool bell = false}) {
  final d = _details(a);
  final who = a.actorId != null && a.actorId == meId ? 'You' : (a.actorName ?? d['by']?.toString() ?? 'Someone');
  final chat = bell ? 'the chat with ${a.contactName ?? 'a customer'}' : 'this chat';
  String assignedTo() => d['assigneeUserId'] != null && d['assigneeUserId'] == meId ? 'you' : (d['assignee']?.toString() ?? 'someone');
  switch (a.type) {
    case 'conversation_closed':
      return '$who closed $chat';
    case 'conversation_reopened':
      if (d['reason'] == 'snooze_ended') return '${bell ? 'The chat with ${a.contactName ?? 'a customer'}' : 'This chat'} is back from snooze';
      if (d['reason'] == 'customer_replied') return 'The customer wrote, so $chat is back from snooze';
      return '$who reopened $chat';
    case 'collaborators_added':
      final names = (d['names'] is List) ? List<String>.from((d['names'] as List).map((e) => '$e')) : <String>[];
      return '$who added ${names.isEmpty ? 'someone' : names.join(', ')} as ${names.length > 1 ? 'collaborators' : 'a collaborator'}${bell ? ' on $chat' : ''}';
    case 'collaborator_removed':
      return '$who removed ${d['name'] ?? 'someone'} as a collaborator${bell ? ' on $chat' : ''}';
    case 'conversation_snoozed':
      final until = d['until'] is String ? DateTime.tryParse(d['until']) : null;
      return '$who snoozed $chat${until != null ? ' until ${snoozedUntilText(until)}' : ''}';
    case 'assigned':
      return '$who assigned $chat to ${assignedTo()}';
    case 'reassigned':
      return '$who reassigned $chat from ${d['previous'] ?? 'someone'} to ${assignedTo()}';
    case 'unassigned':
      if (d['reason'] == 'assignee_deleted') return '$who deleted ${d['assignee'] ?? 'the assignee'}, so $chat is now unassigned';
      if (d['reason'] == 'member_removed') return '$who removed ${d['assignee'] ?? 'a member'} from the team, so $chat is now unassigned';
      return d['assignee'] != null ? '$who unassigned ${d['assignee']} from $chat' : '$who unassigned $chat';
    case 'label_added':
      return '$who added label "${d['label']}" to $chat';
    case 'label_removed':
      return '$who removed label "${d['label']}" from $chat';
    case 'message_edited':
      return '$who edited a message${bell ? ' in $chat' : ''}';
    case 'message_deleted':
      return '$who deleted a message${bell ? ' in $chat' : ''}';
    case 'message_restored':
      return '$who restored a deleted message${bell ? ' in $chat' : ''}';
    case 'message_received':
      return '${a.contactName ?? 'Customer'}: ${d['preview'] ?? 'New message'}';
    case 'note_mention':
      return '$who mentioned you in a note${bell ? ' on $chat' : ''}${d['text'] != null ? ': ${d['text']}' : ''}';
    default:
      return '$who updated $chat';
  }
}

/// The bell leaves customer messages out (they're unread counts and pop-ups instead)
bool inBell(Activity a) => a.type != 'message_received';

// ---------------------------------------------------------------- Roles (roles.ts)

String roleLabel(String role) => switch (role) {
      'owner' || 'admin' => 'Admin',
      'supervisor' => 'Supervisor',
      _ => 'Agent',
    };

/// Phone numbers for a new chat: digits only with the country code, 8-15 digits (E.164)
String? phoneProblem(String countryCode, String number) {
  final digits = '$countryCode$number'.replaceAll(RegExp(r'\D'), '');
  if (number.replaceAll(RegExp(r'\D'), '').isEmpty) return 'Enter the phone number';
  if (digits.length < 8 || digits.length > 15) return 'Enter a valid number with its country code';
  return null;
}

// ---------------------------------------------------------------- Search in conversation (messageSearch.ts)

/// Matches over the loaded messages (case-insensitive substring; deleted messages have no text), oldest first
List<String> findMessageMatches(List<Message> messages, String query) {
  final term = query.trim().toLowerCase();
  if (term.isEmpty) return const [];
  return messages.where((m) => !m.isDeleted && m.body.toLowerCase().contains(term)).map((m) => m.id).toList();
}

/// Plain and matching pieces of a text, keeping its casing
List<({String text, bool match})> highlightSegments(String text, String query) {
  final term = query.trim().toLowerCase();
  if (term.isEmpty || text.isEmpty) return [(text: text, match: false)];
  final lower = text.toLowerCase();
  final out = <({String text, bool match})>[];
  var i = 0;
  while (i < text.length) {
    final j = lower.indexOf(term, i);
    if (j == -1) {
      out.add((text: text.substring(i), match: false));
      break;
    }
    if (j > i) out.add((text: text.substring(i, j), match: false));
    out.add((text: text.substring(j, j + term.length), match: true));
    i = j + term.length;
  }
  return out;
}

// ---------------------------------------------------------------- Presence (presence.ts)

enum PresenceStatus { online, away, offline }

PresenceStatus presenceFrom(String? s) => switch (s) { 'online' => PresenceStatus.online, 'away' => PresenceStatus.away, _ => PresenceStatus.offline };
