import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'api.dart';

/// Files the server only gives to signed-in teammates (message media, note files): fetched once with the token and
/// kept for this session, in memory (small images) and in the app's cache folder (to open or play them).
class MediaCache {
  MediaCache(this.api);
  final Api api;

  final Map<String, Future<({Uint8List bytes, String mime})>> _memory = {};
  final Map<String, Future<File>> _files = {};

  Future<({Uint8List bytes, String mime})> _get(String path) {
    final p = _memory[path] ??= api.download(path);
    p.catchError((_) {
      _memory.remove(path); // try again next time
      return (bytes: Uint8List(0), mime: '');
    });
    return p;
  }

  Future<({Uint8List bytes, String mime})> message(String messageId) => _get('/inbox/messages/${Uri.encodeComponent(messageId)}/media');

  Future<({Uint8List bytes, String mime})> remarkFile(String id) => _get('/inbox/remark-files/${Uri.encodeComponent(id)}');

  /// A local copy with a readable name (for opening documents in another app, or playing audio/video)
  Future<File> file(String key, Future<({Uint8List bytes, String mime})> Function() fetch, String name) {
    final f = _files[key] ??= () async {
      final data = await fetch();
      final dir = Directory('${(await getTemporaryDirectory()).path}/media/${key.hashCode.toUnsigned(32)}');
      await dir.create(recursive: true);
      final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${dir.path}/${safe.isEmpty ? 'file' : safe}');
      await file.writeAsBytes(data.bytes, flush: true);
      return file;
    }();
    f.catchError((_) {
      _files.remove(key);
      return File('');
    });
    return f;
  }

  Future<File> messageFile(String messageId, String name) => file('m:$messageId', () => message(messageId), name);
  Future<File> remarkFileCopy(String id, String name) => file('r:$id', () => remarkFile(id), name);

  void clear() {
    _memory.clear();
    _files.clear();
  }
}
