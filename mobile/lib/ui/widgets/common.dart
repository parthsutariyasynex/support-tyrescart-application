import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../logic/rules.dart';
import '../../state/workspace_data.dart';

Color hexColor(String? hex, [Color fallback = const Color(0xFF25D366)]) {
  if (hex == null) return fallback;
  final h = hex.replaceFirst('#', '');
  if (h.length != 6) return fallback;
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(0xFF000000 | v);
}

String hexOf(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// The same colour per person/customer every time (from their id)
Color avatarColor(String key) {
  const colors = [
    Color(0xFF00A884), Color(0xFF7E57C2), Color(0xFFEF6C00), Color(0xFF1E88E5), Color(0xFFD81B60),
    Color(0xFF43A047), Color(0xFF6D4C41), Color(0xFF00897B), Color(0xFF5C6BC0), Color(0xFFF4511E),
  ];
  var h = 0;
  for (final c in key.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return colors[h % colors.length];
}

String initials(String name) {
  final words = name.replaceAll('+', '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  if (RegExp(r'^\d').hasMatch(words.first)) return '#';
  return (words.first[0] + (words.length > 1 ? words[1][0] : '')).toUpperCase();
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, required this.colorKey, this.size = 48, this.icon});
  final String name;
  final String colorKey;
  final double size;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: size / 2,
        backgroundColor: avatarColor(colorKey),
        child: icon != null
            ? Icon(icon, color: Colors.white, size: size * 0.55)
            : Text(initials(name), style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: size * 0.36)),
      );
}

/// Online (green), away (yellow), offline (red): the website's presence colours
class PresenceDot extends StatelessWidget {
  const PresenceDot(this.status, {super.key, this.size = 12});
  final PresenceStatus status;
  final double size;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: switch (status) { PresenceStatus.online => 'Online', PresenceStatus.away => 'Away', PresenceStatus.offline => 'Offline' },
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: switch (status) { PresenceStatus.online => const Color(0xFF16A34A), PresenceStatus.away => const Color(0xFFEAB308), PresenceStatus.offline => const Color(0xFFDC2626) },
            border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
          ),
        ),
      );
}

/// A teammate's avatar with their live presence
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({super.key, required this.name, required this.userId, this.size = 36});
  final String name;
  final String? userId;
  final double size;
  @override
  Widget build(BuildContext context) {
    final status = context.watch<WorkspaceData>().presenceOf(userId);
    return Stack(clipBehavior: Clip.none, children: [
      Avatar(name: name, colorKey: userId ?? name, size: size),
      Positioned(right: -1, bottom: -1, child: PresenceDot(status, size: size * 0.34)),
    ]);
  }
}

class LabelChip extends StatelessWidget {
  const LabelChip({super.key, required this.name, required this.color, this.small = true});
  final String name;
  final String color;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = hexColor(color);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: small ? 1 : 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10), border: Border.all(color: c.withValues(alpha: 0.5))),
      child: Text(name, style: TextStyle(fontSize: small ? 10.5 : 12.5, color: c, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.color});
  final int count;
  final Color? color;
  @override
  // No `alignment` here: an aligned Container grows to fill its space (e.g. a whole ListTile's trailing slot)
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: color ?? const Color(0xFF25D366), borderRadius: BorderRadius.circular(10)),
        child: Text(countText(count, max: 999),
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF111B21) : Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                height: 1.25)),
      );
}

/// A count as badges show it: "99+" past the limit (WhatsApp's tabs), "999+" in chat rows
String countText(int count, {int max = 99}) => count > max ? '$max+' : '$count';

void showError(BuildContext context, Object err) => showMessage(context, errorText(err), error: true);

void showMessage(BuildContext context, String text, {bool error = false, SnackBarAction? action, Duration? duration}) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(
    content: Text(text),
    backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    action: action,
    duration: duration ?? Duration(seconds: action != null ? 6 : 4),
  ));
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'OK', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

Future<String?> promptText(BuildContext context, String title,
    {String initial = '', String? hint, String ok = 'Save', int maxLines = 1, int? maxLength, bool allowEmpty = false}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: maxLines,
        minLines: 1,
        maxLength: maxLength,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final v = ctrl.text.trim();
            if (v.isEmpty && !allowEmpty) return;
            Navigator.pop(c, v);
          },
          child: Text(ok),
        ),
      ],
    ),
  );
}

/// Runs an action, showing the server's refusal (if any) as a snack bar. Returns whether it worked.
Future<bool> attempt(BuildContext context, Future<void> Function() fn, {String? done}) async {
  try {
    await fn();
    if (done != null && context.mounted) showMessage(context, done);
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action});
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(body!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ]),
        ),
      );
}

class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.cloud_off,
        title: message,
        action: FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
      );
}

/// The role pill (Admin / Supervisor / Agent), coloured like the website
class RolePill extends StatelessWidget {
  const RolePill(this.role, {super.key});
  final String role;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (role) {
      'owner' || 'admin' => ('Admin', const Color(0xFF6D28D9)),
      'supervisor' => ('Supervisor', const Color(0xFF1D4ED8)),
      _ => ('Agent', const Color(0xFF047857)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

/// The app's scroll behaviour: Android's overscroll stretch only where there is something to scroll. A list or page
/// whose content already fits doesn't stretch when dragged (a long one keeps the usual effect).
class FitScrollBehavior extends MaterialScrollBehavior {
  const FitScrollBehavior();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) =>
      _NoStretchWhenFits(child: super.buildOverscrollIndicator(context, child, details));
}

class _NoStretchWhenFits extends StatefulWidget {
  const _NoStretchWhenFits({required this.child});
  final Widget child;
  @override
  State<_NoStretchWhenFits> createState() => _NoStretchWhenFitsState();
}

class _NoStretchWhenFitsState extends State<_NoStretchWhenFits> {
  bool _fits = true;

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollMetricsNotification>(
        // depth 0: this list's own size, not a list nested inside it
        onNotification: (n) {
          if (n.depth == 0) _fits = n.metrics.maxScrollExtent <= n.metrics.minScrollExtent;
          return false;
        },
        child: NotificationListener<OverscrollIndicatorNotification>(
          onNotification: (n) {
            if (n.depth == 0 && _fits) n.disallowIndicator();
            return false;
          },
          child: widget.child,
        ),
      );
}

/// A bottom sheet's body with a text field (search, reason…): the given share of the screen, but always above the
/// keyboard, so its list end and buttons can be reached while typing
class SheetBody extends StatelessWidget {
  const SheetBody({super.key, required this.fraction, required this.child});
  final double fraction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final keyboard = mq.viewInsets.bottom;
    // the sheet may use the screen above the keyboard, less the status bar and the sheet's drag handle
    final room = mq.size.height - keyboard - mq.padding.top - 48;
    final height = (mq.size.height * fraction).clamp(0.0, room < 0 ? 0.0 : room);
    return Padding(padding: EdgeInsets.only(bottom: keyboard), child: SizedBox(height: height, child: child));
  }
}
