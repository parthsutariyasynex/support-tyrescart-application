import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../logic/rules.dart';
import '../../logic/time.dart';
import '../../models/models.dart';
import '../widgets/common.dart';

// AI Assistant, as on the website (client/app/inbox/AiAssistant.tsx). Everything AI runs on the server; these sheets
// only ask it for a summary or a reply suggestion:
//   AI Summary (every member, agents too): the saved summary, who made it and when, Generate (at once) /
//   Regenerate (only after "Regenerate the summary?").
//   AI Reply (whoever may reply): opening it writes a suggestion straight away, to edit here. "Use this reply" asks
//   "Send this AI reply?": Send sends it as it is, Edit first puts it in the message box (sent from there without
//   asking again). Nothing is sent without that confirmation.

const _aiBlue = Color(0xFF2563EB);

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title, {required this.action});
  final String title;
  final Widget action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
    child: Row(
      children: [
        const Icon(Icons.auto_awesome, size: 20, color: _aiBlue),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
        action,
      ],
    ),
  );
}

/// A coloured line: an error (red), or a note (green tick)
class _Notice extends StatelessWidget {
  const _Notice(this.text, {this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = error ? scheme.error : const Color(0xFF16A34A);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(error ? Icons.error_outline : Icons.check, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: error ? scheme.error : null))),
        ],
      ),
    );
  }
}

Widget _busyLabel(String text) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
    const SizedBox(width: 8),
    Text(text),
  ],
);

// ---------------------------------------------------------------- AI Summary

class AiSummarySheet extends StatefulWidget {
  const AiSummarySheet({super.key, required this.conversationId});
  final String conversationId;
  @override
  State<AiSummarySheet> createState() => _AiSummarySheetState();
}

class _AiSummarySheetState extends State<AiSummarySheet> {
  ConversationSummary? _summary;
  String _state = 'loading'; // loading | idle | busy
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<Session>().repo.conversationSummary(widget.conversationId);
      if (mounted) setState(() => _summary = s);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _state = 'idle');
    }
  }

  Future<void> _generate() async {
    if (_summary != null &&
        !await confirm(
          context,
          'Regenerate the summary?',
          'The AI updates it with the messages since it was made, and the new summary replaces the current one.',
          ok: 'Regenerate',
        )) {
      return;
    }
    if (!mounted) return;
    final repo = context.read<Session>().repo;
    setState(() {
      _state = 'busy';
      _error = null;
    });
    try {
      final s = await repo.generateConversationSummary(widget.conversationId);
      if (mounted) setState(() => _summary = s);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _state = 'idle');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = _summary;
    final muted = TextStyle(fontSize: 12.5, color: scheme.outline);
    return SheetBody(
      fraction: 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetTitle(
            'AI Summary',
            action: FilledButton.tonal(
              key: const Key('ai-summary-generate'),
              onPressed: _state == 'idle' ? _generate : null,
              child: _state == 'busy' ? _busyLabel('Writing…') : Text(s != null ? 'Regenerate' : 'Generate'),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              children: [
                if (_state == 'loading')
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                else if (s != null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _aiBlue.withValues(alpha: 0.08),
                      border: Border.all(color: _aiBlue.withValues(alpha: 0.25)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SelectableText(s.summary, style: const TextStyle(fontSize: 14.5, height: 1.45)),
                  ),
                  const SizedBox(height: 8),
                  Text('${s.updatedByName != null ? 'By ${s.updatedByName}, ' : ''}${formatDateTime(s.updatedAt)}', style: muted),
                  if (!s.upToDate)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('New messages since this summary', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.orange.shade700)),
                    ),
                  // Regenerate with nothing new: the AI wasn't asked (messages from the last couple of seconds wait for the next try)
                  if (s.addedMessages == 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        s.upToDate ? 'Already up to date: no new messages since the last summary.' : 'The newest messages just arrived. Try again in a few seconds.',
                        style: muted,
                      ),
                    ),
                ] else if (_error == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text('No summary yet for this chat. Generate one to see what the customer wants and what is still open.', style: muted, textAlign: TextAlign.center),
                  ),
                if (_error != null) _Notice(_error!, error: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- AI Reply

/// What to do with a confirmed AI reply: send it now, or put it in the message box to edit (sent from there as an AI reply)
typedef AiReplyChoice = ({String text, bool send});

class AiReplySheet extends StatefulWidget {
  const AiReplySheet({super.key, required this.conversationId, this.blocked});
  final String conversationId;
  /// Why a reply can't be sent now (e.g. the 24-hour window closed); null when it can
  final String? blocked;
  @override
  State<AiReplySheet> createState() => _AiReplySheetState();
}

class _AiReplySheetState extends State<AiReplySheet> {
  final _text = TextEditingController();
  bool _busy = false;
  // A suggestion came back: the box stays (even emptied while editing) until the next one
  bool _drafted = false;
  String? _error;
  // The team already answered the customer's latest message: a note, not an error (nothing to suggest)
  String? _note;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    // Opened: write a suggestion at once (one tap), unless a reply can't be sent now
    if (widget.blocked == null) _draft();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _draft() async {
    final repo = context.read<Session>().repo;
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      final text = await repo.suggestReply(widget.conversationId);
      if (!mounted) return;
      _text.text = text;
      setState(() => _drafted = text.isNotEmpty);
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.code == 'ALREADY_ANSWERED') {
        _text.clear();
        setState(() {
          _drafted = false;
          _note = e.message;
        });
      } else {
        setState(() => _error = errorText(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _use() async {
    final text = _text.text.trim();
    if (text.length > whatsappTextMax) {
      setState(() => _error = tooLongText(text.length, whatsappTextMax));
      return;
    }
    final send = await confirmAiSend(context, text);
    if (send == null || !mounted) return;
    Navigator.pop<AiReplyChoice>(context, (text: text, send: send));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12.5, color: scheme.outline);
    final hasReply = _text.text.trim().isNotEmpty;
    return SheetBody(
      fraction: 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetTitle(
            'AI Reply',
            action: FilledButton.tonal(
              key: const Key('ai-reply-draft'),
              onPressed: _busy || widget.blocked != null ? null : _draft,
              child: _busy ? _busyLabel('Writing…') : Text(hasReply ? 'Try again' : 'AI Reply'),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              children: [
                if (widget.blocked != null)
                  Text(widget.blocked!, style: muted)
                else if (_drafted) ...[
                  TextField(
                    key: const Key('ai-reply-text'),
                    controller: _text,
                    enabled: !_busy,
                    minLines: 4,
                    maxLines: 10,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: _aiBlue.withValues(alpha: 0.06),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('Edit it here or in the message box. It is sent only after you confirm.', style: muted),
                ] else if (_busy)
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                else if (_error == null && _note == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text("Writes a reply to the customer's latest message for you to check and edit.", style: muted, textAlign: TextAlign.center),
                  ),
                if (_note != null) _Notice(_note!),
                if (_error != null) _Notice(_error!, error: true),
              ],
            ),
          ),
          if (widget.blocked == null)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: FilledButton.icon(
                  key: const Key('ai-reply-use'),
                  onPressed: hasReply && !_busy ? _use : null,
                  icon: const Icon(Icons.check),
                  label: const Text('Use this reply'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Send this AI reply?" before an AI-written reply goes to the customer: true = Send, false = Edit first, null = closed
Future<bool?> confirmAiSend(BuildContext context, String text) => showDialog<bool>(
  context: context,
  builder: (c) => AlertDialog(
    title: const Text('Send this AI reply?'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This message was written with AI. Check it before it goes to the customer on WhatsApp.', style: TextStyle(fontSize: 13, color: Theme.of(c).colorScheme.outline)),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Theme.of(c).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
            child: Text(text, style: const TextStyle(fontSize: 14, height: 1.4)),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Edit first')),
      FilledButton(key: const Key('ai-reply-send'), onPressed: () => Navigator.pop(c, true), child: const Text('Send')),
    ],
  ),
);
