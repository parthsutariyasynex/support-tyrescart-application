import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/media_cache.dart';
import '../../logic/rules.dart';
import '../../logic/time.dart';
import '../../models/models.dart';
import '../../state/chat_controller.dart';
import '../theme.dart';
import 'chat_tile.dart';
import 'media.dart';

/// Colours for agents' names on their messages (the same agent always gets the same colour)
Color agentColor(String id) {
  const colors = [Color(0xFF7C3AED), Color(0xFF0369A1), Color(0xFFB45309), Color(0xFF047857), Color(0xFFBE185D), Color(0xFF4338CA), Color(0xFF0F766E)];
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return colors[h % colors.length];
}

class QuoteBlock extends StatelessWidget {
  const QuoteBlock({super.key, required this.quote, this.onTap, this.onClose});
  final QuotedMessage quote;
  final VoidCallback? onTap;
  final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) {
    final color = quote.direction == 'in' ? const Color(0xFF00A884) : const Color(0xFF5E5CE6);
    final name = quote.senderName ?? (quote.direction == 'in' ? 'Customer' : 'Team');
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(6), border: Border(left: BorderSide(color: color, width: 4))),
        padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12.5), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(quotePreview(quote),
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: context.chat.meta, fontStyle: quote.deleted ? FontStyle.italic : null)),
            ]),
          ),
          if (onClose != null) IconButton(visualDensity: VisualDensity.compact, onPressed: onClose, icon: const Icon(Icons.close, size: 18)),
        ]),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message, required this.onLongPress, this.onQuoteTap, this.onReactionTap, this.highlighted = false, this.searchTerm});
  final Message message;
  final String? searchTerm;
  final VoidCallback onLongPress;
  final VoidCallback? onQuoteTap;
  final VoidCallback? onReactionTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final out = m.isOut;
    final colors = context.chat;
    final cache = context.read<MediaCache>();
    final hasMedia = m.mediaMime != null && !m.isDeleted;
    final showText = !m.isDeleted && (hasMedia ? (m.body.isNotEmpty && !isMediaPlaceholder(m.body)) : true);
    final reactions = [if (m.customerReaction != null) m.customerReaction!, if (m.teamReaction != null) m.teamReaction!];

    Widget media() {
      switch (m.type) {
        case 'image':
        case 'sticker':
          return AuthImage(load: () => cache.message(m.id), heroTag: 'img-${m.id}', maxHeight: m.type == 'sticker' ? 160 : 320);
        case 'video':
          return GestureDetector(
            onTap: () => openProtectedFile(context, () => cache.messageFile(m.id, m.mediaName ?? 'video-${m.id}.mp4')),
            child: Container(
              width: 220,
              height: 140,
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
              alignment: Alignment.center,
              child: const Icon(Icons.play_circle_fill, color: Colors.white, size: 52),
            ),
          );
        case 'audio':
        case 'voice':
          return VoicePlayer(messageId: m.id, mime: m.mediaMime, isVoice: m.type == 'voice');
        case 'document':
          return DocumentCard(
            name: m.mediaName ?? 'Document',
            mime: m.mediaMime,
            size: m.mediaSize,
            onOpen: () => openProtectedFile(context, () => cache.messageFile(m.id, m.mediaName ?? 'document-${m.id}.${documentTypes[m.mediaMime] ?? 'bin'}')),
          );
        default:
          return const SizedBox.shrink();
      }
    }

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
      margin: EdgeInsets.only(left: out ? 48 : 8, right: out ? 8 : 48, top: 2, bottom: reactions.isNotEmpty ? 14 : 2),
      padding: const EdgeInsets.fromLTRB(9, 6, 9, 5),
      decoration: BoxDecoration(
        color: highlighted ? Colors.amber.withValues(alpha: 0.35) : (out ? colors.outgoing : colors.incoming),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(10),
          topRight: const Radius.circular(10),
          bottomLeft: Radius.circular(out ? 10 : 2),
          bottomRight: Radius.circular(out ? 2 : 10),
        ),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 1, offset: Offset(0, 1))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (m.automation != null && m.senderName == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(m.automation == 'follow_up' ? '🤖 Follow-up' : '🤖 Auto-reply', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.meta)),
          ),
        if (m.senderName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(m.senderName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: out && m.sentById != null ? agentColor(m.sentById!) : const Color(0xFF00A884))),
          ),
        if (m.replyTo != null && !m.isDeleted) Padding(padding: const EdgeInsets.only(bottom: 4), child: QuoteBlock(quote: m.replyTo!, onTap: onQuoteTap)),
        if (m.isDeleted)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.block, size: 15, color: colors.meta),
            const SizedBox(width: 4),
            Text('This message was deleted', style: TextStyle(fontStyle: FontStyle.italic, color: colors.meta)),
          ]),
        if (hasMedia) Padding(padding: const EdgeInsets.only(bottom: 3), child: media()),
        if (!m.isDeleted && !hasMedia && const ['image', 'video', 'audio', 'voice', 'document', 'sticker'].contains(m.type))
          Text(m.isOut ? 'File' : 'Downloading the file from WhatsApp…', style: TextStyle(fontStyle: FontStyle.italic, color: colors.meta, fontSize: 13)),
        if (showText && !(const ['image', 'video', 'audio', 'voice', 'document', 'sticker'].contains(m.type) && isMediaPlaceholder(m.body)))
          LinkText(m.body, highlight: searchTerm, style: TextStyle(fontSize: 15.5, color: Theme.of(context).colorScheme.onSurface, height: 1.3)),
        if (m.status == 'failed' && m.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text('Not delivered: ${m.error}', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 2),
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Spacer(),
          if (m.editedAt != null && !m.isDeleted) Text('Edited  ', style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: colors.meta)),
          Text(formatTime(m.createdAt), style: TextStyle(fontSize: 11, color: colors.meta)),
          if (out && !m.isDeleted) ...[const SizedBox(width: 3), StatusTicks(m.status, size: 15)],
        ]),
      ]),
    );

    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Stack(clipBehavior: Clip.none, children: [
          IntrinsicWidth(child: bubble),
          if (reactions.isNotEmpty)
            Positioned(
              bottom: 0,
              left: out ? null : 20,
              right: out ? 20 : null,
              child: GestureDetector(
                onTap: onReactionTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 2)],
                  ),
                  child: Text(reactions.join(' '), style: const TextStyle(fontSize: 14)),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// A message on its way, or one that couldn't be sent (retry / remove)
class PendingBubble extends StatelessWidget {
  const PendingBubble({super.key, required this.pending, required this.onRemove});
  final PendingSend pending;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    final colors = context.chat;
    final p = pending;
    final label = switch (p.kind) {
      'image' => '📷 ${p.text.isEmpty ? (p.fileName ?? 'Photo') : p.text}',
      'document' => '📄 ${p.fileName ?? 'Document'}',
      'voice' => '🎤 Voice message',
      _ => p.text,
    };
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        margin: const EdgeInsets.fromLTRB(48, 2, 8, 2),
        padding: const EdgeInsets.fromLTRB(9, 6, 9, 5),
        decoration: BoxDecoration(color: colors.outgoing.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          if (p.replyTo != null) Padding(padding: const EdgeInsets.only(bottom: 4), child: QuoteBlock(quote: p.replyTo!)),
          if (p.bytes != null) ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(p.bytes!, height: 160, fit: BoxFit.cover)),
          Text(label, style: const TextStyle(fontSize: 15.5)),
          const SizedBox(height: 2),
          if (p.error == null)
            Icon(Icons.schedule, size: 14, color: colors.meta)
          else
            Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(p.error!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error))),
              TextButton(onPressed: onRemove, child: const Text('Remove')),
            ]),
        ]),
      ),
    );
  }
}

/// Internal note: a yellow bubble in the chat, for the team only (never sent to WhatsApp)
class NoteBubble extends StatelessWidget {
  const NoteBubble({super.key, required this.note, required this.memberNames, required this.onLongPress});
  final ContactRemark note;
  final List<String> memberNames;
  final VoidCallback onLongPress;
  @override
  Widget build(BuildContext context) {
    final colors = context.chat;
    final pieces = mentionPieces(note.body, memberNames);
    return Center(
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.86),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.fromLTRB(11, 8, 11, 6),
          decoration: BoxDecoration(color: colors.note, borderRadius: BorderRadius.circular(10), border: Border.all(color: colors.noteBorder)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.sticky_note_2_outlined, size: 15, color: Color(0xFFB45309)),
              const SizedBox(width: 4),
              const Text('Internal note', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFB45309))),
              const SizedBox(width: 6),
              Flexible(child: Text('· ${note.authorName ?? 'Teammate'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: colors.meta))),
            ]),
            if (note.body.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text.rich(TextSpan(
                style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurface, height: 1.3),
                children: [
                  for (final p in pieces)
                    TextSpan(text: p.text, style: p.mention ? TextStyle(color: colors.mention, fontWeight: FontWeight.w600) : null),
                ],
              )),
            ],
            if (note.files.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final f in note.files) RemarkFileChip(id: f.id, name: f.name, mime: f.mime, size: f.size),
              ]),
            ],
            const SizedBox(height: 3),
            Align(
              alignment: Alignment.centerRight,
              child: Text('${note.editedAt != null ? 'Edited  ' : ''}${formatTime(note.createdAt)}', style: TextStyle(fontSize: 11, color: colors.meta)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Day separator and timeline events (assigned, labelled, closed…), centred like WhatsApp's system messages
class SystemPill extends StatelessWidget {
  const SystemPill(this.text, {super.key, this.icon});
  final String text;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: context.chat.system, borderRadius: BorderRadius.circular(8), boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 1)]),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 13, color: context.chat.meta), const SizedBox(width: 4)],
            Flexible(child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: context.chat.meta))),
          ]),
        ),
      );
}

String labelOf(LabelRef l) => l.name;
