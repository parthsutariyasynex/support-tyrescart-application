import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

/// One server event (name + payload), as the website's socket.on handlers receive them.
class ServerEvent {
  ServerEvent(this.name, this.data);
  final String name;
  final dynamic data;

  Map<String, dynamic> get map => data is Map ? Map<String, dynamic>.from(data as Map) : const {};
}

/// The live connection to the API's Socket.IO server (through the website's /socket.io path). The server checks the
/// same sign-in token on connect and puts the socket in the workspace's room and the user's own room.
class Realtime {
  io.Socket? _socket;
  final _events = StreamController<ServerEvent>.broadcast();
  final _connected = StreamController<bool>.broadcast();
  bool isConnected = false;

  Stream<ServerEvent> get events => _events.stream;
  Stream<bool> get connection => _connected.stream;

  Stream<ServerEvent> on(String name) => _events.stream.where((e) => e.name == name);
  Stream<ServerEvent> onAny(Set<String> names) => _events.stream.where((e) => names.contains(e.name));

  void connect(String baseUrl, String token) {
    disconnect();
    // The client library reports a connection the server closed (e.g. a removed or deactivated teammate, a password
    // change) as an uncaught error from its WebSocket. The disconnect is already handled below; keep that error from
    // escaping into the app.
    runZonedGuarded(() => _open(baseUrl, token), (error, _) => _setConnected(false));
  }

  void _open(String baseUrl, String token) {
    final socket = io.io(
      baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          // "/socket.io", as the website's own client uses it: the live server (nginx) redirects "/socket.io/" to it,
          // and a WebSocket can't follow a redirect
          .disableAddTrailingSlash()
          .setAuth({'token': token})
          .enableForceNew() // a new token (another workspace, or after sign-in) must open a new connection
          .enableReconnection()
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(10000)
          .disableAutoConnect()
          .build(),
    );
    socket.onConnect((_) => _setConnected(true));
    socket.onDisconnect((_) => _setConnected(false));
    socket.onConnectError((_) => _setConnected(false));
    socket.onAny((event, data) => _events.add(ServerEvent(event, data)));
    _socket = socket;
    socket.connect();
  }

  void _setConnected(bool v) {
    if (isConnected == v) return;
    isConnected = v;
    _connected.add(v);
  }

  void emit(String event, [dynamic data]) => _socket?.emit(event, data);

  /// Presence list: the server answers through the acknowledgement
  Future<List<Map<String, dynamic>>> presenceList() {
    final c = Completer<List<Map<String, dynamic>>>();
    final s = _socket;
    if (s == null || !isConnected) return Future.value(const []);
    s.emitWithAck('presence:list', null, ack: (data) {
      if (!c.isCompleted) c.complete(data is List ? data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const []);
    });
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () => const []);
  }

  void disconnect() {
    _socket?.dispose();
    _socket = null;
    _setConnected(false);
  }
}
