import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zaizuo_relay/zaizuo_relay.dart';

const _token = 'test-only-zaizuo-relay-token-000000000000';
const _topic =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _guard = Duration(seconds: 2);

/// Test-only native peer so continuation/ping frames are not hidden by the
/// client's WebSocket API. This is not shipped in the library.
final class _NativePeer {
  _NativePeer(this.socket) : input = StreamIterator<Uint8List>(socket);
  final Socket socket;
  final StreamIterator<Uint8List> input;
  final Queue<int> _buffer = Queue<int>();

  static Future<_NativePeer> connect(RelayServer server) async {
    final http = HttpClient();
    try {
      final request =
          await http.getUrl(Uri.parse('http://127.0.0.1:${server.port}/v1/ws'));
      request.headers
        ..set('Connection', 'Upgrade')
        ..set('Upgrade', 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', 'AAECAwQFBgcICQoLDA0ODw==')
        ..set('Authorization', 'Bearer $_token');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.switchingProtocols);
      final peer = _NativePeer(await response.detachSocket());
      final (opcode, bytes) = await peer.frame();
      expect(opcode, 1);
      expect(jsonDecode(utf8.decode(bytes)), {'op': 'ready', 'version': 1});
      return peer;
    } finally {
      http.close(force: true);
    }
  }

  Future<List<int>> _read(int count) async {
    while (_buffer.length < count) {
      if (!await input.moveNext().timeout(_guard)) {
        fail('server disconnected before the expected frame');
      }
      _buffer.addAll(input.current);
    }
    return List<int>.generate(count, (_) => _buffer.removeFirst());
  }

  Future<(int, List<int>)> frame() async {
    final header = await _read(2);
    expect(header[0] & 0x80, 0x80); // native server sends complete frames
    expect(header[1] & 0x80, 0); // server must not mask
    var size = header[1] & 0x7f;
    if (size == 126 || size == 127) {
      final extended = await _read(size == 126 ? 2 : 8);
      size = 0;
      for (final byte in extended) {
        size = size << 8 | byte;
      }
    }
    return (header[0] & 0x0f, await _read(size));
  }

  void send(int opcode, List<int> bytes, {bool fin = true}) {
    assert(bytes.length < 126);
    const mask = [1, 2, 3, 4];
    socket.add([
      (fin ? 0x80 : 0) | opcode,
      0x80 | bytes.length,
      ...mask,
      for (var i = 0; i < bytes.length; i++) bytes[i] ^ mask[i % 4],
    ]);
  }

  Future<void> dispose() async {
    socket.destroy();
    await input.cancel();
  }
}

void main() {
  test('fragmented text is checked by complete-message UTF-8 byte size',
      () async {
    final server = await RelayServer.start(
        RelayConfig(token: _token, maxMessageBytes: 100));
    addTearDown(server.close);
    final peer = await _NativePeer.connect(server);
    addTearDown(peer.dispose);
    // Both individual frames are below 100, but their one message is 120.
    peer.send(1, List<int>.filled(60, 120), fin: false);
    peer.send(0, List<int>.filled(60, 120));
    final (opcode, payload) = await peer.frame();
    expect(opcode, 8);
    expect(payload.take(2), [0x03, 0xf1]); // 1009
  });

  test('native parser handles a valid fragmented request and control pong',
      () async {
    final server = await RelayServer.start(RelayConfig(token: _token));
    addTearDown(server.close);
    final peer = await _NativePeer.connect(server);
    addTearDown(peer.dispose);
    final body = utf8.encode(
        jsonEncode({'op': 'subscribe', 'request_id': 's1', 'topic': _topic}));
    peer.send(1, body.sublist(0, 30), fin: false);
    peer.send(0, body.sublist(30));
    final (opcode, payload) = await peer.frame();
    expect(opcode, 1);
    expect(jsonDecode(utf8.decode(payload)),
        {'op': 'ok', 'request_id': 's1', 'for': 'subscribe', 'topic': _topic});
    peer.send(9, [7, 8, 9]);
    final (pongOpcode, pongPayload) = await peer.frame();
    expect(pongOpcode, 10);
    expect(pongPayload, [7, 8, 9]);
  });

  test('message byte limit is inclusive, before JSON format rejection',
      () async {
    final server =
        await RelayServer.start(RelayConfig(token: _token, maxMessageBytes: 8));
    addTearDown(server.close);
    final peer = await _NativePeer.connect(server);
    addTearDown(peer.dispose);
    peer.send(1, utf8.encode('12345678'));
    final (opcode, payload) = await peer.frame();
    expect(opcode, 1);
    expect(jsonDecode(utf8.decode(payload)),
        {'op': 'error', 'code': 'bad_request'});
  });
}
