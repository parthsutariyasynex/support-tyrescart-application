import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/repo.dart';
import '../../core/session.dart';
import '../../logic/rules.dart';
import '../../logic/time.dart';
import '../../models/models.dart';
import '../../state/alerts.dart';
import '../../state/inbox_store.dart';
import '../../state/workspace_data.dart';
import '../settings/admin_screens.dart';
import '../settings/settings_screen.dart';
import '../theme.dart';
import '../widgets/chat_tile.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';
import 'contact_screen.dart';
import 'filter_sheet.dart';
import 'new_chat_sheet.dart';
import 'notifications_screen.dart';

/// The chat lists of the website's left menu (the filter chips here)
class ChatView {
  const ChatView(this.key, this.title, this.icon, {this.assignee, this.leadStage, this.unreadOnly = false});
  final String key;
  final String title;
  final IconData icon;
  final String? assignee;
  final String? leadStage;
  final bool unreadOnly;

  static const inbox = ChatView('inbox', 'All', Icons.all_inbox);
  static const unread = ChatView('unread', 'Unread', Icons.mark_chat_unread_outlined, unreadOnly: true);
  static const myChats = ChatView('my', 'My chats', Icons.person, assignee: 'me');
  static const newLeads = ChatView('leads', 'New leads', Icons.fiber_new, assignee: 'new_leads');
  static const collaborations = ChatView('collab', 'Collaborations', Icons.group, assignee: 'collaborating');
  static const mentions = ChatView('mentions', 'Mentions', Icons.alternate_email, assignee: 'mentioned');
  static ChatView stage(ContactOption s) => ChatView('stage:${s.value}', s.label, Icons.flag, leadStage: s.value);
}

/// Home: WhatsApp's layout with a bottom navigation (Chats, Calls, Updates, Tools)
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  final Set<int> _built = {0}; // tabs are built the first time they're opened

  void _select(int i) {
    setState(() {
      _tab = i;
      _built.add(i);
    });
    // Opening Updates is opening the bell: its feed reloads and counts as seen
    if (i == 2) {
      final data = context.read<WorkspaceData>();
      data.loadNotifications().then((_) => data.markNotificationsSeen()).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = context.watch<WorkspaceData>();
    Widget lazy(int i, Widget Function() child) => _built.contains(i) ? child() : const SizedBox.shrink();
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          _ChatsTab(onOpenUpdates: () => _select(2)),
          lazy(1, () => const _CallsTab()),
          lazy(2, () => const NotificationsScreen(embedded: true)),
          lazy(3, () => const _ToolsTab()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _select,
        destinations: [
          NavigationDestination(
            icon: Badge(isLabelVisible: data.unreadTotal > 0, label: Text(countText(data.unreadTotal)), child: const Icon(Icons.chat_outlined)),
            selectedIcon: Badge(isLabelVisible: data.unreadTotal > 0, label: Text(countText(data.unreadTotal)), child: const Icon(Icons.chat)),
            label: 'Chats',
          ),
          const NavigationDestination(icon: Icon(Icons.call_outlined), selectedIcon: Icon(Icons.call), label: 'Calls'),
          NavigationDestination(
            icon: Badge(isLabelVisible: data.unseen > 0, label: Text(countText(data.unseen)), child: const Icon(Icons.notifications_none)),
            selectedIcon: Badge(isLabelVisible: data.unseen > 0, label: Text(countText(data.unseen)), child: const Icon(Icons.notifications)),
            label: 'Updates',
          ),
          const NavigationDestination(icon: Icon(Icons.handyman_outlined), selectedIcon: Icon(Icons.handyman), label: 'Tools'),
        ],
      ),
    );
  }
}

/// The home tabs' top bar: WhatsApp's large title on the page colour
PreferredSizeWidget homeBar(BuildContext context, String title, {List<Widget> actions = const []}) => AppBar(
  backgroundColor: context.chat.homeBar,
  foregroundColor: Theme.of(context).colorScheme.onSurface,
  automaticallyImplyLeading: false,
  title: Text(
    title,
    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22, color: context.chat.homeTitle),
  ),
  actions: actions,
);

// ============================================================================================================== Chats

class _ChatsTab extends StatefulWidget {
  const _ChatsTab({required this.onOpenUpdates});
  final VoidCallback onOpenUpdates;
  @override
  State<_ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<_ChatsTab> {
  ChatView _view = ChatView.inbox;
  late InboxStore _store;
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _store = InboxStore(context.read<Session>(), _queryFor(_view));
    _store.load();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _store.loadMore();
    });
  }

  /// What the server searches: the box's text, or the "unread" word for the Unread chip when nothing is typed
  String get _serverSearch => _searchCtrl.text.trim().isEmpty && _view.unreadOnly ? 'unread' : _searchCtrl.text;

  ConversationQuery _queryFor(ChatView v, [ConversationQuery? keep]) => ConversationQuery(
    assignee: v.assignee,
    leadStage: v.leadStage,
    status: keep?.status,
    search: keep?.search,
    sort: keep?.sort,
    labelIds: keep?.labelIds ?? const [],
    assigneeIds: keep?.assigneeIds ?? const [],
    from: keep?.from,
    to: keep?.to,
    leadStages: keep?.leadStages ?? const [],
  );

  void _setView(ChatView v) {
    setState(() => _view = v);
    _store.unreadOnly = v.unreadOnly;
    _store.setQuery(_queryFor(v, _store.query).copyWith(search: _serverSearch));
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _onSearch(String _) {
    setState(() {}); // instant local filtering
    _store.query = _store.query.copyWith(search: _serverSearch);
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () => _store.setQuery(_store.query.copyWith(search: _serverSearch)));
  }

  @override
  void dispose() {
    _store.dispose();
    _scroll.dispose();
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _openChat(Conversation c) async {
    _store.markOpened(c.id);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(conversationId: c.id, initial: c),
      ),
    );
    _store.reload();
  }

  Future<void> _chatActions(Conversation c) async {
    final session = context.read<Session>();
    final repo = session.repo;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(c.contact.display, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('+${c.contact.waId}'),
            ),
            ListTile(
              leading: Icon(c.pinned ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(c.pinned ? 'Unpin chat' : 'Pin chat'),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            if (c.unread == 0)
              ListTile(leading: const Icon(Icons.mark_chat_unread_outlined), title: const Text('Mark as unread'), onTap: () => Navigator.pop(ctx, 'unread')),
            if (c.status != 'closed')
              ListTile(leading: const Icon(Icons.check_circle_outline), title: const Text('Close chat'), onTap: () => Navigator.pop(ctx, 'close')),
            if (c.status != 'open') ListTile(leading: const Icon(Icons.replay), title: const Text('Reopen chat'), onTap: () => Navigator.pop(ctx, 'reopen')),
            ListTile(leading: const Icon(Icons.person_outline), title: const Text('Contact info'), onTap: () => Navigator.pop(ctx, 'contact')),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'pin':
        await attempt(context, () async {
          await repo.setPinned(c.id, !c.pinned);
          _store.patch(c.id, (x) => x.pinned = !c.pinned);
          _store.reload();
        }, done: c.pinned ? 'Chat unpinned.' : 'Chat pinned to the top of your list.');
      case 'unread':
        await attempt(context, () async {
          await repo.markUnread(c.id);
          _store.patch(c.id, (x) => x.unread = 1);
        });
      case 'close':
        await attempt(context, () => repo.setStatus(c.id, true), done: 'Chat closed.');
        _store.reload();
      case 'reopen':
        await attempt(context, () => repo.setStatus(c.id, false), done: 'Chat reopened.');
        _store.reload();
      case 'contact':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ContactScreen(contactId: c.contact.id, conversationId: c.id),
          ),
        );
    }
  }

  Future<void> _newChat() async {
    final c = await showModalBottomSheet<Conversation>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => const NewChatSheet());
    if (c != null && mounted) {
      _store.reload();
      _openChat(c);
    }
  }

  Future<void> _filters() async {
    final q = await showModalBottomSheet<ConversationQuery>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FilterSheet(query: _store.query, hideStage: _view.leadStage != null),
    );
    if (q != null) _store.setQuery(q);
  }

  /// Camera: take a photo and send it to a chat (the chat's usual rules apply: 24-hour window, closed chats, New leads)
  Future<void> _camera() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2560);
    if (x == null || !mounted) return;
    final bytes = await x.readAsBytes();
    var mime = lookupMimeType(x.name, headerBytes: bytes) ?? 'image/jpeg';
    if (!imageTypes.contains(mime)) mime = 'image/jpeg';
    final check = checkFile(x.name.toLowerCase().endsWith('.png') ? x.name : '${x.name.split('.').first}.jpg', mime, bytes.length);
    if (check is FileProblem) {
      if (mounted) showMessage(context, check.message, error: true);
      return;
    }
    if (!mounted) return;
    final c = await showModalBottomSheet<Conversation>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ChatPickerSheet(title: 'Send photo to…'),
    );
    if (c == null || !mounted) return;
    final sent = await attempt(
      context,
      () => context.read<Session>().repo.sendFile(c.id, bytes: bytes, mime: mime, image: true, name: x.name),
      done: 'Photo sent',
    );
    if (sent && mounted) _openChat(c);
  }

  Future<void> _menu(String v) async {
    final session = context.read<Session>();
    switch (v) {
      case 'new':
        await _newChat();
      case 'filter':
        await _filters();
      case 'updates':
        widget.onOpenUpdates();
      case 'settings':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
      case 'signout':
        if (await confirm(context, 'Sign out?', 'You will stop getting alerts on this phone until you sign in again.', ok: 'Sign out')) {
          await session.signOut();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final data = context.watch<WorkspaceData>();
    final filters = _store.query.activeMenuFilters;
    final menu = PopupMenuButton<String>(
      tooltip: 'Menu',
      onSelected: _menu,
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'new', child: Text('New chat')),
        PopupMenuItem(value: 'filter', child: Text(filters > 0 ? 'Filter by ($filters)' : 'Filter by')),
        const PopupMenuItem(value: 'updates', child: Text('Notifications')),
        const PopupMenuItem(value: 'settings', child: Text('Settings')),
        const PopupMenuItem(value: 'signout', child: Text('Sign out')),
      ],
    );
    final search = Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
      child: TextField(
        key: const Key('home-search'),
        controller: _searchCtrl,
        onChanged: _onSearch,
        textInputAction: TextInputAction.search,
        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        decoration: InputDecoration(
          hintText: 'Search name, number or message',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchCtrl.clear();
                    _onSearch('');
                  },
                ),
          filled: true,
          fillColor: context.chat.searchFill,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
        ),
      ),
    );

    // One scrolling page, as in WhatsApp: the title bar slides away while scrolling down and comes back on the way up;
    // the search bar, notice and chips scroll with the chats; dragging the list closes the keyboard.
    return Scaffold(
      floatingActionButton: FloatingActionButton(tooltip: 'New chat', onPressed: _newChat, child: const Icon(Icons.add_comment)),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          final rows = _store.visible;
          final Widget content;
          if (_store.loading && rows.isEmpty) {
            content = const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()));
          } else if (_store.error != null && rows.isEmpty) {
            content = SliverFillRemaining(
              hasScrollBody: false,
              child: ErrorRetry(message: _store.error!, onRetry: _store.load),
            );
          } else if (rows.isEmpty) {
            content = SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: _view.icon,
                title: _searchCtrl.text.trim().isNotEmpty ? 'No chats match "${_searchCtrl.text.trim()}"' : 'No chats here',
                body: _emptyHint(),
              ),
            );
          } else {
            content = SliverPadding(
              padding: const EdgeInsets.only(bottom: 88), // room for the new-chat button
              sliver: SliverList.builder(
                itemCount: rows.length + (_store.hasMore ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i >= rows.length) {
                    return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                  }
                  final c = rows[i];
                  return ChatTile(
                    conversation: c,
                    meId: session.userId,
                    typingName: _store.typing[c.id]?.name,
                    stage: data.stage(c.contact.leadStage),
                    onTap: () => _openChat(c),
                    onLongPress: () => _chatActions(c),
                  );
                },
              ),
            );
          }
          return RefreshIndicator(
            edgeOffset: kToolbarHeight + MediaQuery.of(context).padding.top,
            onRefresh: () async {
              await _store.load(quiet: true);
              await data.refreshAll();
            },
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverAppBar(
                  floating: true,
                  snap: true,
                  backgroundColor: context.chat.homeBar,
                  surfaceTintColor: Colors.transparent,
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                  automaticallyImplyLeading: false,
                  title: Text(
                    'TyresCart Support',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22, color: context.chat.homeTitle),
                  ),
                  actions: [
                    IconButton(tooltip: 'Camera', icon: const Icon(Icons.photo_camera_outlined), onPressed: _camera),
                    menu,
                  ],
                ),
                SliverToBoxAdapter(child: search),
                const SliverToBoxAdapter(child: _HomeBanner()),
                SliverToBoxAdapter(
                  child: _Chips(
                    view: _view,
                    status: _store.query.status,
                    onView: _setView,
                    onStatus: (s) => _store.setQuery(_store.query.copyWith(status: s, clearStatus: s == null)),
                  ),
                ),
                content,
              ],
            ),
          );
        },
      ),
    );
  }

  String _emptyHint() => switch (_view.key) {
    'unread' => 'Chats with unread customer messages show here.',
    'my' => 'Chats assigned to you show here.',
    'leads' => 'New customers who aren\'t assigned to anyone yet show here.',
    'collab' => 'Chats you were added to as a collaborator show here.',
    'mentions' => 'Chats where a teammate @mentioned you in a note show here.',
    _ => 'Customer chats from WhatsApp show here.',
  };
}

/// One row of pill chips: the list to show (All, Unread, My chats, … lifecycle stages), then the status (Open,
/// Snoozed, Closed; tap again for any status)
class _Chips extends StatelessWidget {
  const _Chips({required this.view, required this.status, required this.onView, required this.onStatus});
  final ChatView view;
  final String? status;
  final ValueChanged<ChatView> onView;
  final ValueChanged<String?> onStatus;

  @override
  Widget build(BuildContext context) {
    final data = context.watch<WorkspaceData>();
    final colors = context.chat;
    Widget chip(String label, bool selected, VoidCallback onTap, {int? count, Color? dot}) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: dot == null ? null : Icon(Icons.circle, size: 10, color: dot),
        label: Text(count != null && count > 0 ? '$label $count' : label),
        labelStyle: TextStyle(color: selected ? colors.chipSelectedText : colors.meta, fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
    final views = [ChatView.inbox, ChatView.unread, ChatView.myChats, ChatView.newLeads, ChatView.mentions, ChatView.collaborations];
    return SizedBox(
      height: 50,
      child: ListView(
        key: const Key('home-chips'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        children: [
          for (final v in views) chip(v.title, view.key == v.key, () => onView(v), count: v.key == 'leads' ? data.counts.newLeads : null),
          for (final s in data.fieldOptions?.leadStages ?? const <ContactOption>[])
            chip(
              s.label,
              view.key == 'stage:${s.value}',
              () => onView(ChatView.stage(s)),
              count: data.stageCounts[s.value],
              dot: hexColor(s.color, Colors.grey),
            ),
          Container(width: 1, margin: const EdgeInsets.fromLTRB(2, 8, 10, 8), color: Theme.of(context).dividerColor),
          chip('Open', status == 'open', () => onStatus(status == 'open' ? null : 'open'), count: data.counts.open),
          chip('Snoozed', status == 'snoozed', () => onStatus(status == 'snoozed' ? null : 'snoozed'), count: data.counts.snoozed),
          chip('Closed', status == 'closed', () => onStatus(status == 'closed' ? null : 'closed')),
        ],
      ),
    );
  }
}

/// A dismissible notice under the search bar, only for something real: phone notifications off, no WhatsApp number
/// connected (replies can't be sent), or the live connection lost
class _HomeBanner extends StatefulWidget {
  const _HomeBanner();
  @override
  State<_HomeBanner> createState() => _HomeBannerState();
}

class _HomeBannerState extends State<_HomeBanner> with WidgetsBindingObserver {
  static final Set<String> _dismissed = {}; // for this run of the app
  bool? _notificationsAllowed;
  bool _connected = true;
  Timer? _offlineGrace;
  StreamSubscription<bool>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNotifications();
    final rt = context.read<Session>().realtime;
    _connected = true; // give the first connection a moment before saying it's lost
    _sub = rt.connection.listen((c) {
      _offlineGrace?.cancel();
      if (c) {
        if (mounted) setState(() => _connected = true);
      } else {
        // a brief reconnect isn't worth a banner
        _offlineGrace = Timer(const Duration(seconds: 6), () {
          if (mounted && !rt.isConnected) setState(() => _connected = false);
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkNotifications(); // e.g. turned on in the phone's settings
  }

  Future<void> _checkNotifications() async {
    final allowed = await context.read<Alerts>().notificationsAllowed();
    if (mounted) setState(() => _notificationsAllowed = allowed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _offlineGrace?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    String? key;
    late IconData icon;
    late String title;
    late String body;
    VoidCallback? onTap;
    if (!_connected && !_dismissed.contains('offline')) {
      key = 'offline';
      icon = Icons.cloud_off;
      title = 'Reconnecting…';
      body = "Live updates are paused until the connection is back. Pull down to refresh.";
    } else if (_notificationsAllowed == false && !_dismissed.contains('notifications')) {
      key = 'notifications';
      icon = Icons.notifications_off_outlined;
      title = 'Turn on notifications';
      body = 'Get alerts for new customer messages, assignments and @mentions.';
      onTap = () async {
        final ok = await context.read<Alerts>().requestNotifications();
        if (mounted) setState(() => _notificationsAllowed = ok);
        if (!ok && context.mounted) showMessage(context, 'Allow notifications for TyresCart Support in the phone\'s Settings → Apps.');
      };
    } else if (session.state == SessionState.signedIn && session.workspaceId != null && session.whatsappPhone == null && !_dismissed.contains('whatsapp')) {
      key = 'whatsapp';
      icon = Icons.link_off;
      title = 'No WhatsApp number connected';
      body = session.isAdmin
          ? "Replies can't be sent until a number is connected. Connect it on the website: Settings → WhatsApp."
          : "Replies can't be sent until an admin connects the WhatsApp number.";
    }
    if (key == null) return const SizedBox.shrink();
    final k = key;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: Material(
        color: context.chat.searchFill,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('home-banner-$k'),
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: context.chat.chipSelected,
                  child: Icon(icon, color: context.chat.chipSelectedText, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(body, style: TextStyle(fontSize: 13, color: context.chat.meta)),
                    ],
                  ),
                ),
                IconButton(tooltip: 'Dismiss', icon: const Icon(Icons.close, size: 20), onPressed: () => setState(() => _dismissed.add(k))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Chooses one chat that can take a message now (camera photo)
class _ChatPickerSheet extends StatefulWidget {
  const _ChatPickerSheet({required this.title});
  final String title;
  @override
  State<_ChatPickerSheet> createState() => _ChatPickerSheetState();
}

class _ChatPickerSheetState extends State<_ChatPickerSheet> {
  List<Conversation> _chats = [];
  bool _loading = true;
  String? _error;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([String q = '']) async {
    setState(() => _loading = true);
    try {
      final page = await context.read<Session>().repo.conversations(ConversationQuery(search: q, status: 'open'));
      if (mounted) setState(() => (_chats = page.nodes, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    return SheetBody(
      fraction: 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search chats', isDense: true),
              onChanged: (v) {
                _q = v;
                Future.delayed(const Duration(milliseconds: 350), () {
                  if (_q == v && mounted) _load(v);
                });
              },
            ),
          ),
          Expanded(
            child: _error != null
                ? ErrorRetry(message: _error!, onRetry: () => _load(_q))
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : _chats.isEmpty
                ? const EmptyState(icon: Icons.chat_bubble_outline, title: 'No open chats')
                : ListView(
                    children: [
                      for (final c in _chats)
                        Builder(
                          builder: (context) {
                            // The same rules the chat's message box follows
                            var blocked = forwardBlocked(c);
                            if (blocked.isEmpty && c.assignee == null && !session.isSupervisorOrAbove) blocked = 'New lead: assign it to yourself first';
                            return ListTile(
                              enabled: blocked.isEmpty,
                              leading: Avatar(name: c.contact.display, colorKey: c.contact.id, size: 40),
                              title: Text(c.contact.display),
                              subtitle: Text(blocked.isNotEmpty ? blocked : '+${c.contact.waId}'),
                              onTap: () => Navigator.pop(context, c),
                            );
                          },
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================================================== Calls

/// Calls: WhatsApp calls aren't part of this system (the server has no calling), so this tab lists the customers and
/// calls them with the phone's own dialer. Tapping a row opens the chat.
class _CallsTab extends StatefulWidget {
  const _CallsTab();
  @override
  State<_CallsTab> createState() => _CallsTabState();
}

class _CallsTabState extends State<_CallsTab> {
  late final InboxStore _store = InboxStore(context.read<Session>(), const ConversationQuery())..load();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _store.loadMore();
    });
  }

  @override
  void dispose() {
    _store.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _call(Conversation c) async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: '+${c.contact.waId}'));
    if (!ok && mounted) showMessage(context, "This phone can't make calls.", error: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: homeBar(context, 'Calls'),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          final rows = _store.items;
          if (_store.loading && rows.isEmpty) return const Center(child: CircularProgressIndicator());
          if (_store.error != null && rows.isEmpty) return ErrorRetry(message: _store.error!, onRetry: _store.load);
          if (rows.isEmpty) return const EmptyState(icon: Icons.call_outlined, title: 'No customers yet');
          return RefreshIndicator(
            onRefresh: () => _store.load(quiet: true),
            child: ListView.builder(
              controller: _scroll,
              itemCount: rows.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      'Call a customer from this phone',
                      style: TextStyle(color: context.chat.meta, fontWeight: FontWeight.w600),
                    ),
                  );
                }
                final c = rows[i - 1];
                return ListTile(
                  leading: Avatar(name: c.contact.display, colorKey: c.contact.id),
                  title: Text(
                    c.contact.display,
                    style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface),
                  ),
                  subtitle: Text('+${c.contact.waId} · ${listTimestamp(c.lastMessageAt)}', style: TextStyle(color: context.chat.meta)),
                  trailing: IconButton(
                    tooltip: 'Call ${c.contact.display}',
                    icon: Icon(Icons.call_outlined, color: Theme.of(context).colorScheme.primary),
                    onPressed: () => _call(c),
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(conversationId: c.id, initial: c),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================================================== Tools

/// Tools: who you are, the team's tools and settings (owners/admins see the workspace pages, as on the website)
class _ToolsTab extends StatelessWidget {
  const _ToolsTab();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    Widget section(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        t,
        style: TextStyle(color: context.chat.meta, fontWeight: FontWeight.w600),
      ),
    );
    Widget tool(IconData icon, String title, VoidCallback onTap, {String? subtitle}) =>
        ListTile(leading: Icon(icon), title: Text(title), subtitle: subtitle == null ? null : Text(subtitle), onTap: onTap);
    return Scaffold(
      appBar: homeBar(context, 'Tools'),
      body: ListView(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            leading: MemberAvatar(name: s.userName, userId: s.userId, size: 52),
            title: Text(s.userName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(s.workspaceName, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 6),
                    RolePill(s.role),
                  ],
                ),
                if (s.whatsappPhone != null) Text('WhatsApp ${s.whatsappPhone}', style: TextStyle(color: context.chat.meta, fontSize: 12)),
              ],
            ),
            onTap: () => go(const ProfileScreen()),
          ),
          const Divider(),
          section('Chats'),
          tool(Icons.add_comment_outlined, 'New chat', () async {
            final c = await showModalBottomSheet<Conversation>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => const NewChatSheet(),
            );
            if (c != null && context.mounted) go(ChatScreen(conversationId: c.id, initial: c));
          }),
          tool(Icons.bolt, 'Saved replies', () => go(const SavedRepliesScreen()), subtitle: 'Type / in a message to use them'),
          tool(Icons.label_outline, 'Labels', () => go(const LabelsScreen())),
          if (s.isAdmin) tool(Icons.description_outlined, 'Message templates', () => go(const TemplatesAdminScreen())),
          if (s.isAdmin) ...[
            section('Team and workspace'),
            tool(Icons.group_outlined, 'User management', () => go(const TeamScreen())),
            tool(Icons.assessment_outlined, 'Assignment report', () => go(const ReportScreen())),
            tool(Icons.smart_toy_outlined, 'Simple automations', () => go(const AutomationsScreen())),
            tool(Icons.business_outlined, 'Company and workspace preferences', () => go(const WorkspacePrefsScreen())),
          ],
          section('Account'),
          tool(Icons.swap_horiz, 'Switch workspace', () => go(const WorkspacesScreen())),
          tool(Icons.settings_outlined, 'Settings', () => go(const SettingsScreen())),
          ListTile(
            leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
            title: Text('Sign out', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              if (await confirm(context, 'Sign out?', 'You will stop getting alerts on this phone until you sign in again.', ok: 'Sign out')) {
                await s.signOut();
              }
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
