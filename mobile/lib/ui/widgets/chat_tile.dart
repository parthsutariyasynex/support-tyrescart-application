import 'package:flutter/material.dart';

import '../../logic/rules.dart';
import '../../logic/time.dart';
import '../../models/models.dart';
import '../theme.dart';
import 'common.dart';

/// Delivery ticks, as WhatsApp shows them
class StatusTicks extends StatelessWidget {
  const StatusTicks(this.status, {super.key, this.size = 15});
  final String status;
  final double size;
  @override
  Widget build(BuildContext context) {
    final meta = context.chat.meta;
    return switch (status) {
      'pending' => Icon(Icons.schedule, size: size - 2, color: meta),
      'sent' => Icon(Icons.done, size: size, color: meta),
      'delivered' => Icon(Icons.done_all, size: size, color: meta),
      'read' => Icon(Icons.done_all, size: size, color: context.chat.tickRead),
      'failed' => Icon(Icons.error_outline, size: size - 1, color: Theme.of(context).colorScheme.error),
      _ => const SizedBox.shrink(),
    };
  }
}

class ChatTile extends StatelessWidget {
  const ChatTile({
    super.key,
    required this.conversation,
    required this.meId,
    required this.onTap,
    this.onLongPress,
    this.typingName,
    this.stage,
    this.selected = false,
  });

  final Conversation conversation;
  final String? meId;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? typingName;
  final ContactOption? stage;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = conversation;
    final scheme = Theme.of(context).colorScheme;
    final meta = context.chat.meta;
    final bold = needsAttention(c, meId);
    final last = c.lastMessage;
    final preview = messagePreview(last);
    final timeColor = c.unread > 0 ? context.chat.unreadBadge : meta;

    Widget subtitle;
    if (typingName != null) {
      subtitle = Text('$typingName is typing…', style: TextStyle(color: context.chat.unreadBadge, fontStyle: FontStyle.italic), maxLines: 1, overflow: TextOverflow.ellipsis);
    } else {
      subtitle = Row(children: [
        if (last != null && last.isOut && !last.isDeleted) ...[StatusTicks(last.status, size: 16), const SizedBox(width: 3)],
        if (last != null && last.isDeleted) ...[Icon(Icons.block, size: 14, color: meta), const SizedBox(width: 3)],
        Expanded(
          child: Text(
            preview.isEmpty ? 'No messages yet' : preview.replaceAll('\n', ' '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: bold ? scheme.onSurface : meta,
                fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
                fontStyle: (last?.isDeleted ?? false) ? FontStyle.italic : FontStyle.normal),
          ),
        ),
      ]);
    }

    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.08) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(clipBehavior: Clip.none, children: [
              Avatar(name: c.contact.display, colorKey: c.contact.id),
              if (c.status == 'closed')
                Positioned(right: -2, bottom: -2, child: _miniIcon(context, Icons.check_circle, const Color(0xFF6B7280))),
              if (c.status == 'snoozed')
                Positioned(right: -2, bottom: -2, child: _miniIcon(context, Icons.snooze, const Color(0xFFF59E0B))),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(c.contact.display,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16.5, color: scheme.onSurface, fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
                  ),
                  const SizedBox(width: 6),
                  Text(listTimestamp(c.lastMessageAt), style: TextStyle(fontSize: 12, color: timeColor, fontWeight: c.unread > 0 ? FontWeight.w600 : null)),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  Expanded(child: subtitle),
                  if (c.pinned) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.push_pin, size: 16, color: meta)),
                  if (c.unread > 0) Padding(padding: const EdgeInsets.only(left: 6), child: CountBadge(c.unread, color: context.chat.unreadBadge)),
                  if (c.unread == 0 && bold)
                    Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Container(width: 10, height: 10, decoration: BoxDecoration(color: context.chat.unreadBadge, shape: BoxShape.circle))),
                ]),
                if (c.labels.isNotEmpty || c.assignee != null || stage != null) ...[
                  const SizedBox(height: 5),
                  Wrap(spacing: 4, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (stage != null) LabelChip(name: stage!.label, color: stage!.color ?? '#64748b'),
                    for (final l in c.labels.take(3)) LabelChip(name: l.name, color: l.color),
                    if (c.labels.length > 3) Text('+${c.labels.length - 3}', style: TextStyle(fontSize: 11, color: meta)),
                    if (c.assignee != null)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.person, size: 13, color: hexColor(c.assignee!.color)),
                        const SizedBox(width: 2),
                        Text(c.assignee!.userId != null && c.assignee!.userId == meId ? 'You' : c.assignee!.name,
                            style: TextStyle(fontSize: 11, color: hexColor(c.assignee!.color), fontWeight: FontWeight.w600)),
                      ]),
                  ]),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _miniIcon(BuildContext context, IconData icon, Color color) => Container(
        decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, shape: BoxShape.circle),
        padding: const EdgeInsets.all(1),
        child: Icon(icon, size: 16, color: color),
      );
}
