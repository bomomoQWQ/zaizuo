import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 先扫描声明长度再交给 dart:io 解码，包含跨 continuation 的消息累计上限。
class WebSocketFrameGuard {
  WebSocketFrameGuard(this.maxMessageBytes);
  final int maxMessageBytes;
  int _state = 0;
  int _opcode = 0;
  bool _fin = false;
  bool _masked = false;
  int _length = 0;
  int _remainingLength = 0;
  int _skip = 0;
  int _messageBytes = 0;
  bool add(List<int> bytes) {
    for (final byte in bytes) {
      if (_skip > 0) {
        _skip--;
        continue;
      }
      if (_state == 0) {
        _fin = byte & 0x80 != 0;
        _opcode = byte & 0x0f;
        if (_opcode != 0 &&
            _opcode != 1 &&
            _opcode != 2 &&
            _opcode != 8 &&
            _opcode != 9 &&
            _opcode != 10) return false;
        _state = 1;
      } else if (_state == 1) {
        _masked = byte & 0x80 != 0;
        _length = byte & 0x7f;
        if (_length == 126 || _length == 127) {
          _remainingLength = _length == 126 ? 2 : 8;
          _length = 0;
          _state = 2;
        } else if (!_lengthDone()) {
          return false;
        }
      } else {
        _length = (_length << 8) | byte;
        if (_length < 0 || _length > maxMessageBytes) return false;
        if (--_remainingLength == 0 && !_lengthDone()) return false;
      }
    }
    return true;
  }

  bool _lengthDone() {
    if (_opcode < 8) {
      if (_opcode == 1 || _opcode == 2) _messageBytes = 0;
      _messageBytes += _length;
      if (_messageBytes > maxMessageBytes) return false;
      if (_fin) _messageBytes = 0;
    }
    _skip = _length + (_masked ? 4 : 0);
    _state = 0;
    return true;
  }
}

/// 在 HttpServer 解析器之前约束首部字节数/首部完整到达时间。
/// 本服务禁用 HTTP keep-alive；WebSocket 升级后不再按 HTTP 首部处理帧。
class GuardedServerSocket extends Stream<Socket> implements ServerSocket {
  GuardedServerSocket(this.inner,
      {required this.maxHeaderBytes,
      required this.headerTimeout,
      required this.maxConnections,
      required this.maxMessageBytes,
      required this.bodyTimeout});
  final ServerSocket inner;
  final int maxHeaderBytes;
  final Duration headerTimeout;
  final int maxConnections;
  final int maxMessageBytes;
  final Duration bodyTimeout;
  final Set<GuardedSocket> sockets = {};
  @override
  InternetAddress get address => inner.address;
  @override
  int get port => inner.port;
  @override
  Future<ServerSocket> close() async {
    await inner.close();
    return this;
  }

  void destroyAll() {
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
  }

  @override
  StreamSubscription<Socket> listen(void Function(Socket)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      inner.map<Socket>((socket) {
        if (sockets.length >= maxConnections) {
          socket.destroy();
          return socket;
        }
        late final GuardedSocket guarded;
        guarded = GuardedSocket(socket, maxHeaderBytes, headerTimeout,
            () => sockets.remove(guarded))
          ..guardWebSocket(maxMessageBytes)
          ..guardHttpBody(maxMessageBytes, bodyTimeout);
        sockets.add(guarded);
        return guarded;
      }).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
}

class GuardedSocket extends Stream<Uint8List> implements Socket {
  GuardedSocket(this.inner, this.maxHeaderBytes, Duration timeout, this.onClose,
      {this.input, bool headersComplete = false}) {
    _timer = Timer(timeout, destroy);
    if (headersComplete) {
      _headersDone = true;
      _webSocketRequested = true;
      _timer.cancel();
    }
  }
  final Socket inner;
  final Stream<Uint8List>? input;
  final int maxHeaderBytes;
  final void Function() onClose;
  late final Timer _timer;
  bool _headersDone = false;
  bool _destroyed = false;
  int _headerBytes = 0;
  int _tail = 0;
  bool _webSocketRequested = false;
  final List<int> _headerProbe = [];
  WebSocketFrameGuard? _frames;
  int? _maxHttpBytes;
  int _httpBytes = 0;
  Duration? _bodyTimeout;
  Timer? _bodyTimer;
  void guardHttpBody(int maxBytes, Duration timeout) {
    // 除解码正文限制外，也限制chunk编码开销/HTTP pipelining占用。
    _maxHttpBytes = maxBytes + maxHeaderBytes;
    _bodyTimeout = timeout;
  }

  void httpBodyComplete() {
    _bodyTimer?.cancel();
  }

  void guardWebSocket(int maxMessageBytes) {
    _frames = WebSocketFrameGuard(maxMessageBytes);
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      (input ?? inner)
          .transform<Uint8List>(StreamTransformer.fromHandlers(
            handleData: (data, sink) {
              if (_destroyed) return;
              var frameOffset = 0;
              if (!_headersDone) {
                frameOffset = data.length;
                for (var i = 0; i < data.length; i++) {
                  final byte = data[i];
                  _headerProbe.add(byte);
                  _headerBytes++;
                  _tail = ((_tail << 8) | byte) & 0xffffffff;
                  if (_headerBytes > maxHeaderBytes) {
                    destroy();
                    return;
                  }
                  if (_tail == 0x0d0a0d0a) {
                    _headersDone = true;
                    _timer.cancel();
                    _webSocketRequested = RegExp(
                            r'^upgrade\s*:\s*websocket\s*\r?$',
                            multiLine: true,
                            caseSensitive: false)
                        .hasMatch(latin1.decode(_headerProbe));
                    final headerText = latin1.decode(_headerProbe);
                    if (!_webSocketRequested &&
                        _bodyTimeout != null &&
                        RegExp(r'^transfer-encoding\s*:|^content-length\s*:\s*[1-9]',
                                multiLine: true, caseSensitive: false)
                            .hasMatch(headerText)) {
                      _bodyTimer = Timer(_bodyTimeout!, destroy);
                    }
                    _headerProbe.clear();
                    frameOffset = i + 1;
                    break;
                  }
                }
              }
              if (_headersDone && frameOffset < data.length) {
                if (!_webSocketRequested && _maxHttpBytes != null) {
                  _httpBytes += data.length - frameOffset;
                  if (_httpBytes > _maxHttpBytes!) {
                    destroy();
                    return;
                  }
                }
                // 未经 upgrade 的 HTTP 请求不做帧扫描；已升级的消息必须先验长度。
                if (_webSocketRequested &&
                    _frames != null &&
                    !_frames!.add(data.sublist(frameOffset))) {
                  destroy();
                  return;
                }
              }
              sink.add(data);
            },
            handleDone: (sink) {
              _timer.cancel();
              _bodyTimer?.cancel();
              onClose();
              sink.close();
            },
          ))
          .listen(onData,
              onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  InternetAddress get address => inner.address;
  @override
  InternetAddress get remoteAddress => inner.remoteAddress;
  @override
  int get port => inner.port;
  @override
  int get remotePort => inner.remotePort;
  @override
  Encoding get encoding => inner.encoding;
  @override
  set encoding(Encoding value) {
    inner.encoding = value;
  }

  @override
  Future get done => inner.done;
  @override
  void add(List<int> data) => inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      inner.addError(error, stackTrace);
  @override
  Future addStream(Stream<List<int>> stream) => inner.addStream(stream);
  @override
  void write(Object? object) => inner.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      inner.writeAll(objects, separator);
  @override
  void writeln([Object? object = '']) => inner.writeln(object);
  @override
  void writeCharCode(int charCode) => inner.writeCharCode(charCode);
  @override
  Future flush() => inner.flush();
  @override
  Future close() {
    _timer.cancel();
    _bodyTimer?.cancel();
    onClose();
    return inner.close();
  }

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _timer.cancel();
    _bodyTimer?.cancel();
    onClose();
    inner.destroy();
  }

  @override
  bool setOption(SocketOption option, bool enabled) =>
      inner.setOption(option, enabled);
  @override
  void setRawOption(RawSocketOption option) => inner.setRawOption(option);
  @override
  Uint8List getRawOption(RawSocketOption option) => inner.getRawOption(option);
}
