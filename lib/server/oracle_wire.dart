/// Oracle (TNS/TTC) wire-protocol server front-end for [Database].
///
/// Lets unmodified Oracle thin clients (node-oracledb, python-oracledb, the
/// pure-Dart `oracledb` driver) connect to `dart_db_server`, mirroring the way
/// [MySqlServer] fronts the engine for MySQL clients. This is the inverse of
/// the sibling client in `../dart-oracledb`: every frame the client *encodes*
/// we *decode* here, and vice-versa.
///
/// Status: Phase 0/1 of `doc/oracle-wire-protocol-plan.md` — TNS transport.
/// The listener accepts connections, parses the CONNECT packet, negotiates a
/// protocol version, and answers with ACCEPT; DATA frames carrying TTC are
/// decoded to their function code and dispatched to [_handleTtc], where later
/// phases (negotiation, auth, execute/fetch) hang off.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'database.dart';
import 'oracle_codec.dart';
import 'oracle_tns.dart';

// TTC function codes (first byte of a TTC message). Full set lives in the
// client's `protocol/constants.dart`; only the ones the transport phase needs
// are named here.
const int _ttcProtocol = 1; // protocol negotiation
const int _ttcDataTypes = 2; // data-type negotiation

/// Oracle TNS/TTC server fronting a [Database].
class OracleServer {
  OracleServer(
    this.db, {
    InternetAddress? address,
    this.port = 1521,
  }) : address = address ?? InternetAddress.loopbackIPv4;

  final Database db;
  final InternetAddress address;
  final int port;

  ServerSocket? _socket;
  final Set<OracleConnection> _conns = <OracleConnection>{};
  int _nextId = 1;
  void Function(String msg)? onLog;

  Future<void> start() async {
    _socket = await ServerSocket.bind(address, port);
    _log('listening on ${address.address}:${_socket!.port} (oracle wire)');
    _socket!.listen(_accept);
  }

  /// The actual bound port (useful when [port] was 0).
  int get boundPort => _socket?.port ?? port;

  Future<void> stop() async {
    for (final c in _conns.toList()) {
      await c.close();
    }
    await _socket?.close();
  }

  void _accept(Socket socket) {
    final conn = OracleConnection(this, socket, _nextId++);
    _conns.add(conn);
    conn._start();
  }

  void _log(String msg) => (onLog ?? print).call('[oracle] $msg');
}

/// Connection phases for the TNS/TTC state machine.
enum OraclePhase { connect, negotiate, auth, ready, closed }

/// Per-connection state machine. Buffers inbound bytes, reassembles TNS
/// frames, and advances the handshake.
class OracleConnection {
  OracleConnection(this.server, this.socket, this.id);

  final OracleServer server;
  final Socket socket;
  final int id;

  Uint8List _buffered = Uint8List(0);
  StreamSubscription<Uint8List>? _sub;
  OraclePhase _phase = OraclePhase.connect;

  int _version = tnsServerVersion;

  void _start() {
    server._log('conn $id connected from '
        '${socket.remoteAddress.address}:${socket.remotePort}');
    _sub = socket.listen(
      _onData,
      onError: (Object e, StackTrace st) {
        server._log('conn $id error: $e');
      },
      onDone: close,
      cancelOnError: false,
    );
  }

  Future<void> close() async {
    if (_phase == OraclePhase.closed) return;
    _phase = OraclePhase.closed;
    await _sub?.cancel();
    try {
      await socket.close();
    } catch (_) {}
    server._conns.remove(this);
    server._log('conn $id disconnected');
  }

  void _onData(Uint8List chunk) {
    // Append to the running buffer.
    if (_buffered.isEmpty) {
      _buffered = Uint8List.fromList(chunk);
    } else {
      final merged = Uint8List(_buffered.length + chunk.length)
        ..setRange(0, _buffered.length, _buffered)
        ..setRange(_buffered.length, _buffered.length + chunk.length, chunk);
      _buffered = merged;
    }
    _drain();
  }

  /// Consumes as many whole TNS frames as the buffer currently holds.
  void _drain() {
    while (true) {
      final frameLen = TnsPacket.frameLength(_buffered, _buffered.length);
      if (frameLen == null || _buffered.length < frameLen) return;
      final raw = Uint8List.sublistView(_buffered, 0, frameLen);
      _buffered = Uint8List.sublistView(_buffered, frameLen);
      try {
        _handleFrame(raw);
      } on TnsException catch (e) {
        server._log('conn $id bad frame: $e');
        unawaited(close());
        return;
      }
    }
  }

  void _handleFrame(Uint8List raw) {
    final packet = TnsPacket.decode(raw);
    switch (packet.type) {
      case tnsPacketConnect:
        _handleConnect(raw);
        break;
      case tnsPacketData:
        _handleData(packet);
        break;
      case tnsPacketResend:
        // Client asking us to resend — nothing buffered to resend yet.
        break;
      case tnsPacketMarker:
        _handleMarker(packet);
        break;
      case tnsPacketAbort:
        unawaited(close());
        break;
      default:
        server._log('conn $id ignoring packet type ${packet.type}');
    }
  }

  void _handleConnect(Uint8List raw) {
    final req = ConnectRequest.parse(raw);
    _version = negotiateVersion(req);
    server._log(
      'conn $id CONNECT v=${req.versionDesired}/${req.versionMinimum} '
      'sdu=${req.sdu} -> negotiated v=$_version'
      '${req.connectData.isNotEmpty ? ' desc="${req.connectData}"' : ''}',
    );
    final accept = buildAcceptPacket(
      version: _version,
      sdu: req.sdu == 0 ? tnsDefaultSdu : req.sdu,
      tdu: req.tdu == 0 ? tnsDefaultTdu : req.tdu,
      // flag2 = 0: classical (non-FAST_AUTH) handshake for now.
    );
    _phase = OraclePhase.negotiate;
    _send(accept);
  }

  void _handleMarker(TnsPacket packet) {
    // Echo an ATTENTION/MARKER acknowledgement by replying with the same
    // marker body (break/reset handling is a later phase).
    _send(TnsPacket(type: tnsPacketMarker, payload: packet.payload).encode());
  }

  void _handleData(TnsPacket packet) {
    if (packet.payload.length < 3) return; // need TTC header
    // TTC header: function code (1), sequence (1), data flags (2 BE) — but the
    // 2 data-flags bytes are at the TNS DATA layer here; the TTC message body
    // starts with its function code. The client wraps TTC in DATA with the
    // 2-byte data flags already stripped into packet.flags.
    final ttc = ReadBuffer(packet.payload);
    final functionCode = ttc.readUint8();
    _handleTtc(functionCode, ttc, packet);
  }

  void _handleTtc(int functionCode, ReadBuffer body, TnsPacket packet) {
    switch (functionCode) {
      case _ttcProtocol:
        server._log('conn $id TTC PROTOCOL negotiation (not yet implemented)');
        break;
      case _ttcDataTypes:
        server._log('conn $id TTC DATA TYPES negotiation (not yet implemented)');
        break;
      default:
        server._log('conn $id TTC function $functionCode (phase $_phase, '
            'not yet implemented)');
    }
    // Negotiation, auth, and execute/fetch responses are implemented in the
    // next phases of doc/oracle-wire-protocol-plan.md.
  }

  void _send(Uint8List bytes) {
    try {
      socket.add(bytes);
    } catch (e) {
      server._log('conn $id send failed: $e');
    }
  }
}
