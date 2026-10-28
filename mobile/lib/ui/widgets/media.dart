import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/media_cache.dart';
import '../../logic/rules.dart';
import '../theme.dart';

/// A protected image (message photo or note file), loaded with the sign-in token
class AuthImage extends StatelessWidget {
  const AuthImage({super.key, required this.load, this.heroTag, this.maxHeight = 320, this.onTap});
  final Future<({Uint8List bytes, String mime})> Function() load;
  final String? heroTag;
  final double maxHeight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: load(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Container(
            height: 120,
            width: 220,
            alignment: Alignment.center,
            color: Colors.black12,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.broken_image_outlined),
              Padding(padding: const EdgeInsets.all(6), child: Text(errorText(snap.error!), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12))),
            ]),
          );
        }
        if (!snap.hasData || snap.data!.bytes.isEmpty) {
          return Container(height: 180, width: 220, alignment: Alignment.center, color: Colors.black12, child: const CircularProgressIndicator(strokeWidth: 2));
        }
        final img = ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight, minWidth: 120),
          child: Image.memory(snap.data!.bytes, fit: BoxFit.cover, gaplessPlayback: true),
        );
        final child = heroTag != null ? Hero(tag: heroTag!, child: img) : img;
        return GestureDetector(
          onTap: onTap ?? () => Navigator.push(context, MaterialPageRoute(builder: (_) => ImageViewer(bytes: snap.data!.bytes, heroTag: heroTag))),
          child: ClipRRect(borderRadius: BorderRadius.circular(6), child: child),
        );
      },
    );
  }
}

class ImageViewer extends StatelessWidget {
  const ImageViewer({super.key, required this.bytes, this.heroTag, this.title});
  final Uint8List bytes;
  final String? heroTag;
  final String? title;
  @override
  Widget build(BuildContext context) {
    final img = Image.memory(bytes);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: title != null ? Text(title!) : null),
      body: Center(child: InteractiveViewer(maxScale: 5, child: heroTag != null ? Hero(tag: heroTag!, child: img) : img)),
    );
  }
}

/// Opens a protected file in another app (PDF viewer, Office, video player…)
Future<void> openProtectedFile(BuildContext context, Future<dynamic> Function() getFile) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Opening…'), duration: Duration(seconds: 1)));
  try {
    final file = await getFile();
    final r = await OpenFilex.open(file.path);
    if (r.type != ResultType.done) {
      messenger.showSnackBar(SnackBar(content: Text(r.type == ResultType.noAppToOpen ? 'No app on this phone can open this file.' : r.message)));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
  }
}

class DocumentCard extends StatelessWidget {
  const DocumentCard({super.key, required this.name, this.mime, this.size, required this.onOpen});
  final String name;
  final String? mime;
  final int? size;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final label = documentLabel(mime, name);
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: label == 'PDF' ? const Color(0xFFE53935) : const Color(0xFF1E88E5), borderRadius: BorderRadius.circular(4)),
            child: Text(label.length > 4 ? label.substring(0, 4) : label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11)),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              Text([label, if (size != null) formatSize(size!)].join(' · '), style: TextStyle(fontSize: 12, color: context.chat.meta)),
            ]),
          ),
          const SizedBox(width: 6),
          Icon(Icons.download_outlined, color: context.chat.meta),
        ]),
      ),
    );
  }
}

/// Voice note / audio player (the file is fetched with the sign-in token, then played from the cache folder)
class VoicePlayer extends StatefulWidget {
  const VoicePlayer({super.key, required this.messageId, this.mime, this.isVoice = true});
  final String messageId;
  final String? mime;
  final bool isVoice;
  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  AudioPlayer? _player;
  bool _loading = false;
  String? _error;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  final List<StreamSubscription> _subs = [];

  Future<void> _toggle() async {
    if (_player != null) {
      _player!.playing ? await _player!.pause() : await _player!.play();
      setState(() {});
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final file = await context.read<MediaCache>().messageFile(widget.messageId, 'voice-${widget.messageId}.${audioExtension(widget.mime)}');
      final p = AudioPlayer();
      final d = await p.setFilePath(file.path);
      _subs.add(p.positionStream.listen((x) => mounted ? setState(() => _pos = x) : null));
      _subs.add(p.playerStateStream.listen((s) {
        if (s.processingState == ProcessingState.completed) {
          p.seek(Duration.zero);
          p.pause();
        }
        if (mounted) setState(() {});
      }));
      _player = p;
      _dur = d ?? Duration.zero;
      await p.play();
    } catch (e) {
      _error = e is ApiException ? e.message : "Couldn't play this recording";
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final playing = _player?.playing ?? false;
    final total = _dur.inMilliseconds > 0 ? _dur : (_player?.duration ?? Duration.zero);
    return SizedBox(
      width: 240,
      child: Row(children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: widget.isVoice ? const Color(0xFF00A884) : const Color(0xFFF59E0B),
          child: Icon(widget.isVoice ? Icons.mic : Icons.headphones, color: Colors.white, size: 20),
        ),
        IconButton(
          onPressed: _loading ? null : _toggle,
          icon: _loading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(playing ? Icons.pause : Icons.play_arrow),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (_error != null)
              Text(_error!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error))
            else
              SliderTheme(
                data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), overlayShape: SliderComponentShape.noOverlay),
                child: Slider(
                  value: total.inMilliseconds == 0 ? 0 : (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0),
                  onChanged: _player == null || total.inMilliseconds == 0 ? null : (v) => _player!.seek(total * v),
                ),
              ),
            Text(total.inMilliseconds > 0 ? '${_fmt(_pos)} / ${_fmt(total)}' : (widget.isVoice ? 'Voice message' : 'Audio'),
                style: TextStyle(fontSize: 11, color: context.chat.meta)),
          ]),
        ),
      ]),
    );
  }
}

/// Text with web addresses as tappable links (they open in the browser), like the website
class LinkText extends StatefulWidget {
  const LinkText(this.text, {super.key, this.style, this.highlight});
  final String text;
  final TextStyle? style;
  final String? highlight;
  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final List<TapGestureRecognizer> _recognizers = [];
  static final _url = RegExp(r'((https?:\/\/|www\.)[^\s<]+[^\s<.,:;"\x27)\]!?])', caseSensitive: false);

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final spans = <InlineSpan>[];
    final mark = TextStyle(backgroundColor: Colors.amber.withValues(alpha: 0.6), color: Colors.black);
    void plain(String t) {
      final h = widget.highlight;
      if (h == null || h.trim().isEmpty) return spans.add(TextSpan(text: t));
      for (final seg in highlightSegments(t, h)) {
        spans.add(TextSpan(text: seg.text, style: seg.match ? mark : null));
      }
    }

    var last = 0;
    for (final m in _url.allMatches(widget.text)) {
      if (m.start > last) plain(widget.text.substring(last, m.start));
      final raw = m.group(0)!;
      final href = raw.toLowerCase().startsWith('www.') ? 'https://$raw' : raw;
      final r = TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
      _recognizers.add(r);
      spans.add(TextSpan(text: raw, style: TextStyle(color: context.chat.mention, decoration: TextDecoration.underline), recognizer: r));
      last = m.end;
    }
    if (last < widget.text.length) plain(widget.text.substring(last));
    return Text.rich(TextSpan(style: widget.style ?? DefaultTextStyle.of(context).style, children: spans));
  }
}

/// A small chip for a file attached to a note (image thumbnail or document)
class RemarkFileChip extends StatelessWidget {
  const RemarkFileChip({super.key, required this.id, required this.name, required this.mime, required this.size});
  final String id, name, mime;
  final int size;
  @override
  Widget build(BuildContext context) {
    final cache = context.read<MediaCache>();
    if (mime.startsWith('image/')) {
      return SizedBox(width: 180, child: AuthImage(load: () => cache.remarkFile(id), maxHeight: 180));
    }
    return DocumentCard(name: name, mime: mime, size: size, onOpen: () => openProtectedFile(context, () => cache.remarkFileCopy(id, name)));
  }
}

/// A file extension the phone's player understands for this audio type
String audioExtension(String? mime) {
  final m = (mime ?? '').split(';').first.trim().toLowerCase();
  return switch (m) {
    'audio/ogg' || 'audio/opus' => 'ogg',
    'audio/mp4' || 'audio/x-m4a' || 'audio/aac' => 'm4a',
    'audio/mpeg' || 'audio/mp3' => 'mp3',
    'audio/amr' => 'amr',
    'audio/webm' => 'webm',
    _ => 'm4a',
  };
}
