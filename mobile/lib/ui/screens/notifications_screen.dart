import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../logic/rules.dart';
import '../../logic/time.dart';
import '../../state/workspace_data.dart';
import '../app.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The bell: what happened in your chats (assignments, labels, closed/reopened, edits, @mentions). Owners and admins
/// see everything; others only their own chats. The server decides; opening it marks everything seen.
class NotificationsScreen extends StatefulWidget {
  /// embedded: the home screen's Updates tab (its own title, no back button; it marks the feed seen when opened)
  const NotificationsScreen({super.key, this.embedded = false});
  final bool embedded;
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.embedded) return;
    final data = context.read<WorkspaceData>();
    data.loadNotifications().then((_) => data.markNotificationsSeen()).catchError((_) {});
  }

  IconData _icon(String type) => switch (type) {
        'note_mention' => Icons.alternate_email,
        'assigned' || 'reassigned' || 'unassigned' => Icons.person_add_alt,
        'label_added' || 'label_removed' => Icons.label_outline,
        'conversation_closed' => Icons.check_circle_outline,
        'conversation_reopened' => Icons.replay,
        'conversation_snoozed' => Icons.snooze,
        'message_edited' => Icons.edit_outlined,
        'message_deleted' || 'message_restored' => Icons.delete_outline,
        'collaborators_added' || 'collaborator_removed' => Icons.group_outlined,
        _ => Icons.notifications_none,
      };

  @override
  Widget build(BuildContext context) {
    final data = context.watch<WorkspaceData>();
    final me = context.read<Session>().userId;
    return Scaffold(
      appBar: widget.embedded
          ? AppBar(
              backgroundColor: context.chat.homeBar,
              foregroundColor: context.chat.homeTitle,
              title: const Text('Updates', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22)),
            )
          : AppBar(title: const Text('Notifications')),
      body: RefreshIndicator(
        onRefresh: data.loadNotifications,
        child: data.notifications.isEmpty
            ? ListView(children: const [SizedBox(height: 120), EmptyState(icon: Icons.notifications_none, title: 'Nothing new', body: 'Assignments, labels and @mentions in your chats show here.')])
            : ListView.separated(
                itemCount: data.notifications.length,
                separatorBuilder: (_, _) => const Divider(indent: 72),
                itemBuilder: (_, i) {
                  final a = data.notifications[i];
                  return ListTile(
                    leading: CircleAvatar(child: Icon(_icon(a.type))),
                    title: Text(activityText(a, me, bell: true), maxLines: 3, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${dayLabel(a.createdAt)}, ${formatTime(a.createdAt)}'),
                    onTap: a.conversationId == null ? null : () => openChat(a.conversationId!),
                  );
                },
              ),
      ),
    );
  }
}
