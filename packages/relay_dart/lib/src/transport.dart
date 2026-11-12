import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Retains the detached Socket so shutdown can actually abort a blocked write.
/// Native WebSocket still owns parsing, fragmentation, masking and ping/pong.
final class RelayTransport {
  RelayTransport(Socket socket, this.timeout) {
    _socket = FlushingSocket(socket, timeout);
    webSocket = WebSocket.fromUpgradedSocket(
      _socket,
      serverSide: true,
      compression: CompressionOptions.compressionOff,
    );
  }

  final Duration timeout;
  late final FlushingSocket _socket;
  late final WebSocket webSocket;
  final Completer<void> _inputDone = Completer<void>();
  Future<void>? _closing;

  set onWriteFailure(void Function() callback) {
    _socket.onWriteFailure = callback;
  }

  Future<void> write(String message) => _socket.sendText(webSocket, message);

  void inputDone() {
    if (!_inputDone.isCompleted) _inputDone.complete();
  }

  Future<void> close(int code) => _closing ??= _close(code);

  Future<void> _close(int code) async {
    try {
      // Dart 3.6 and later SDKs reject the RFC 6455/IANA-assigned 1013 in
      // WebSocket.close. Only that two-byte outgoing close code is rewritten;
      // the SDK continues to perform the complete close handshake itself.
      _socket.closeCodeOverride = code == 1013 ? 1013 : null;
      final nativeCode =
          code == 1013 ? WebSocketStatus.internalServerError : code;
      await Future.wait<void>([
        webSocket.close(nativeCode).then<void>((_) {}),
        _inputDone.future,
      ]).timeout(timeout);
    } catch (_) {
      // A closing/failed peer is expected, and never logged.
    } finally {
      _socket.destroy();
    }
  }
}

/// Socket decorator that propagates native WebSocket output pause/resume all
/// the way to a real Socket.flush. WebSocket.add alone has no flush receipt.
///
/// A maximum of one application write is active. Native control frames share
/// the same serialized output stream. Only outgoing frame headers are inspected
/// to identify application-frame flush boundaries and the 1013 close workaround;
/// no incoming frame parser or application-payload parser is implemented here.
final class FlushingSocket extends Stream<Uint8List> implements Socket {
  FlushingSocket(this._socket, this.writeTimeout) {
    // Register immediately: Socket.done can fail even before close is called.
    _socket.done.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  }

  final Socket _socket;
  final Duration writeTimeout;
  final OutgoingFrameTracker _frames = OutgoingFrameTracker();
  Completer<void>? _applicationWrite;
  StreamSubscription<Uint8List>? _incoming;
  bool _destroyed = false;
  bool _outputBound = false;
  void Function()? onWriteFailure;

  set closeCodeOverride(int? code) => _frames.closeCodeOverride = code;

  Future<void> sendText(WebSocket webSocket, String message) {
    if (_destroyed) return Future<void>.error(const SocketException.closed());
    if (_applicationWrite != null) {
      return Future<void>.error(
          StateError('A transport write is already active'));
    }
    final completion = _applicationWrite = Completer<void>();
    try {
      webSocket.add(message);
    } catch (error, stackTrace) {
      _applicationWrite = null;
      completion.completeError(error, stackTrace);
    }
    return completion.future;
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    if (_outputBound) throw StateError('WebSocket output is already bound');
    _outputBound = true;
    try {
      // await-for pauses the SDK's source while the real socket is draining.
      // This prevents draining our finite queue into an unbounded IOSink queue.
      await for (final bytes in stream) {
        if (_destroyed) break;
        final chunk = _frames.inspect(bytes);
        _socket.add(chunk.bytes);
        // In particular, do not let an endless ping stream queue unbounded
        // SDK-generated pongs while output is blocked. This does not undo any
        // frame/message already assembled by the native parser.
        final incoming = _incoming;
        incoming?.pause();
        try {
          await _socket.flush().timeout(writeTimeout);
        } finally {
          incoming?.resume();
        }
        if (chunk.applicationFrames != 0) {
          final completion = _applicationWrite;
          _applicationWrite = null;
          if (completion != null && !completion.isCompleted) {
            completion.complete();
          }
        }
      }
    } catch (_) {
      onWriteFailure?.call();
      destroy();
      rethrow;
    }
  }

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    final completion = _applicationWrite;
    _applicationWrite = null;
    if (completion != null && !completion.isCompleted) {
      completion.completeError(const SocketException.closed());
    }
    _socket.destroy();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _incoming = _socket.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  InternetAddress get address => _socket.address;
  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
  @override
  int get port => _socket.port;
  @override
  int get remotePort => _socket.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
  @override
  Encoding get encoding => _socket.encoding;
  @override
  set encoding(Encoding value) => _socket.encoding = value;
  @override
  void add(List<int> data) => _socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);
  @override
  void write(Object? object) => _socket.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
  @override
  Future<void> flush() => _socket.flush();
  @override
  Future<void> close() async {
    try {
      await _socket.close().timeout(writeTimeout);
    } catch (_) {
      destroy();
    }
  }

  @override
  Future<void> get done => _socket.done.then<void>((_) {});

  // Socket also declares a private VM-only raw-detach member. WebSocket never
  // uses it; a public decorator cannot name that member from another library.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class OutgoingChunk {
  const OutgoingChunk(this.bytes, this.applicationFrames);
  final List<int> bytes;
  final int applicationFrames;
}

/// Small streaming *outgoing-header* tracker. At most 10 header bytes are kept;
/// payload is neither copied nor decoded except for the two close-code bytes.
/// SDK output is always unmasked, uncompressed server frames. Internal for tests.
final class OutgoingFrameTracker {
  int? closeCodeOverride;
  final List<int> _header = [];
  int _headerLength = 2;
  int _remaining = 0;
  int _payloadOffset = 0;
  int _opcode = 0;
  bool _inPayload = false;

  OutgoingChunk inspect(List<int> bytes) {
    List<int>? rewritten;
    var applicationFrames = 0;
    var index = 0;
    while (index < bytes.length) {
      if (!_inPayload) {
        _header.add(bytes[index++]);
        if (_header.length == 2) {
          if ((_header[1] & 0x80) != 0) {
            throw StateError('Unexpected masked SDK server frame');
          }
          final size = _header[1] & 0x7f;
          _headerLength = size == 126 ? 4 : (size == 127 ? 10 : 2);
        }
        if (_header.length < _headerLength) continue;
        _opcode = _header[0] & 0x0f;
        _remaining = _header[1] & 0x7f;
        if (_headerLength > 2) {
          _remaining = 0;
          for (var i = 2; i < _headerLength; i++) {
            _remaining = (_remaining << 8) | _header[i];
          }
        }
        _inPayload = true;
        _payloadOffset = 0;
      } else {
        final count = _remaining < bytes.length - index
            ? _remaining
            : bytes.length - index;
        final replacement = closeCodeOverride;
        if (_opcode == 8 && replacement != null && _payloadOffset < 2) {
          for (var offset = 0;
              offset < count && _payloadOffset + offset < 2;
              offset++) {
            rewritten ??= Uint8List.fromList(bytes);
            rewritten[index + offset] = _payloadOffset + offset == 0
                ? replacement >> 8
                : replacement & 0xff;
          }
        }
        index += count;
        _payloadOffset += count;
        _remaining -= count;
      }
      if (_inPayload && _remaining == 0) {
        if (_opcode == 1 || _opcode == 2) applicationFrames++;
        _header.clear();
        _headerLength = 2;
        _inPayload = false;
      }
    }
    return OutgoingChunk(rewritten ?? bytes, applicationFrames);
  }
}
