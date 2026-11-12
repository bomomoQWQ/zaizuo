import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_relay/src/protocol.dart';
import 'package:zaizuo_relay/zaizuo_relay.dart';

const topicA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const fakeToken = 'test-only-zaizuo-relay-token-000000000000';

Map<String, Object?> publish(Object? payload) => {
      'op': 'publish',
      'request_id': 'p1',
      'topic': topicA,
      'payload': payload,
    };

void main() {
  group('shared v1 vectors', () {
    // Resolve relative to this source, not the test runner working directory.
    final file = File.fromUri(
        Platform.script.resolve('../../../protocol/relay-v1-cases.json'));
    // package:test executes a generated kernel entrypoint, so resolve from the
    // package root as a fallback without maintaining a private vector copy.
    final vectorsFile =
        file.existsSync() ? file : File('../../protocol/relay-v1-cases.json');
    final vectors =
        jsonDecode(vectorsFile.readAsStringSync()) as Map<String, dynamic>;
    test('version', () => expect(vectors['version'], 1));
    for (final (index, request) in (vectors['valid'] as List).indexed) {
      test('accepts valid vector $index', () {
        expect(parseRequest(jsonEncode(request), maxPayloadBytes: 32768),
            isA<RelayRequest>());
      });
    }
    for (final (index, value) in (vectors['invalid'] as List).indexed) {
      final vector = value as Map<String, dynamic>;
      test('rejects invalid vector $index', () {
        final result =
            parseRequest(jsonEncode(vector['request']), maxPayloadBytes: 32768);
        expect(result, isA<RequestFailure>());
        expect((result as RequestFailure).code, vector['code']);
      });
    }
  });

  group('strict request shape', () {
    for (final text in [
      '',
      'null',
      'true',
      '[]',
      '42',
      '"subscribe"',
      '{',
      '{"op":"subscribe","request_id":"x","topic":"$topicA"}\n{}',
    ]) {
      test('rejects non-object or malformed JSON ${jsonEncode(text)}', () {
        final result =
            parseRequest(text, maxPayloadBytes: 32768) as RequestFailure;
        expect(result.code, 'bad_request');
        expect(result.requestId, isNull);
      });
    }
    final invalid = <Map<String, Object?>>[
      {'op': null, 'request_id': 'x'},
      {'op': 1, 'request_id': 'x'},
      {'op': 'dance'},
      {'op': 'dance', 'request_id': ''},
      {'op': 'subscribe', 'request_id': 1, 'topic': topicA},
      {'op': 'subscribe', 'request_id': 'x\n', 'topic': topicA},
      {'op': 'subscribe', 'request_id': 'x', 'topic': '$topicA\n'},
      {'op': 'subscribe', 'request_id': 'x' * 65, 'topic': topicA},
      {'op': 'subscribe', 'request_id': 'x', 'topic': true},
      {
        'op': 'subscribe',
        'request_id': 'x',
        'topic': topicA,
        'payload': 'AQID'
      },
      {'op': 'unsubscribe', 'request_id': 'x', 'topic': topicA, 'extra': null},
      {'op': 'publish', 'request_id': 'x', 'topic': topicA},
      publish(42),
      publish(true),
      publish(null),
      publish([]),
    ];
    for (final (index, request) in invalid.indexed) {
      test('rejects wrong fields/types $index', () {
        final result = parseRequest(jsonEncode(request), maxPayloadBytes: 32768)
            as RequestFailure;
        expect(result.code, 'bad_request');
      });
    }
    test('only safe request ids are echoed', () {
      final safe = parseRequest('{"op":"subscribe","request_id":"safe"}',
          maxPayloadBytes: 32768) as RequestFailure;
      final unsafe = parseRequest(
          '{"op":"subscribe","request_id":"secret text"}',
          maxPayloadBytes: 32768) as RequestFailure;
      expect(safe.requestId, 'safe');
      expect(unsafe.requestId, isNull);
    });
    test('unknown op is unsupported and never echoed', () {
      final result = parseRequest('{"op":"arbitrary secret","request_id":"r1"}',
          maxPayloadBytes: 32768) as RequestFailure;
      expect(result.code, 'unsupported_op');
      expect(result.requestId, 'r1');
    });
  });

  group('canonical standard base64', () {
    for (final payload in [
      '',
      'AQ',
      'AQ=',
      'AQ===',
      'AR==',
      'AQJ=',
      'AQID\n',
      'AQID ',
      '-_==',
      '____',
      '%41QID',
      '====',
      'A===',
      'A QI'
    ]) {
      test('rejects ${jsonEncode(payload)}', () {
        expect(
            parseRequest(jsonEncode(publish(payload)), maxPayloadBytes: 32768),
            isA<RequestFailure>());
      });
    }
    for (final payload in ['AQ==', 'AQI=', 'AQID', '+/8=']) {
      test('accepts $payload without interpreting content', () {
        final result =
            parseRequest(jsonEncode(publish(payload)), maxPayloadBytes: 32768)
                as RelayRequest;
        expect(result.payload, payload);
      });
    }
    test('decoded byte boundary and configured lower bound', () {
      final atLimit = base64Encode(List<int>.filled(32768, 255));
      final aboveLimit = base64Encode(List<int>.filled(32769, 255));
      expect(parseRequest(jsonEncode(publish(atLimit)), maxPayloadBytes: 32768),
          isA<RelayRequest>());
      expect(
          parseRequest(jsonEncode(publish(aboveLimit)), maxPayloadBytes: 32768),
          isA<RequestFailure>());
      expect(parseRequest(jsonEncode(publish('AQI=')), maxPayloadBytes: 1),
          isA<RequestFailure>());
      expect(parseRequest(jsonEncode(publish('AQ==')), maxPayloadBytes: 1),
          isA<RelayRequest>());
    });
  });

  group('RelayConfig', () {
    test('protocol defaults', () {
      final config = RelayConfig(token: fakeToken);
      expect(config.maxConnections, 128);
      expect(config.maxTopicsPerConnection, 64);
      expect(config.maxMessageBytes, 65536);
      expect(config.maxPayloadBytes, 32768);
      expect(config.maxPendingMessages, 32);
      expect(config.maxRequestsPerWindow, 100);
      expect(config.pingInterval, const Duration(seconds: 30));
      expect(config.writeTimeout, const Duration(seconds: 5));
      expect(config.toString(), isNot(contains(fakeToken)));
    });
    for (final (index, token) in [
      '',
      'a' * 31,
      'a' * 257,
      '${'a' * 31} ',
      '${'a' * 31}\t',
      '${'a' * 31}\n',
      '${'a' * 31}\x7f',
      '${'a' * 31}中'
    ].indexed) {
      test('rejects invalid token $index without exposing its contents', () {
        expect(
            () => RelayConfig(token: token),
            throwsA(isA<ArgumentError>().having((e) => e.message, 'safe error',
                'token must contain 32–256 printable non-space ASCII characters')));
      });
    }
    test('accepts minimum/maximum printable ASCII token', () {
      expect(RelayConfig(token: '!' * 32).token.length, 32);
      expect(RelayConfig(token: '~' * 256).token.length, 256);
    });
    final invalidConfigs = <RelayConfig Function()>[
      () => RelayConfig(token: fakeToken, maxConnections: 0),
      () => RelayConfig(token: fakeToken, maxTopicsPerConnection: 0),
      () => RelayConfig(token: fakeToken, maxMessageBytes: -1),
      () => RelayConfig(token: fakeToken, maxPayloadBytes: 0),
      () => RelayConfig(token: fakeToken, maxPayloadBytes: 32769),
      () => RelayConfig(token: fakeToken, maxPendingMessages: 0),
      () => RelayConfig(token: fakeToken, maxRequestsPerWindow: 0),
      () => RelayConfig(token: fakeToken, pingInterval: Duration.zero),
      () => RelayConfig(
          token: fakeToken, writeTimeout: const Duration(microseconds: -1)),
    ];
    for (final (index, create) in invalidConfigs.indexed) {
      test('rejects invalid numeric config $index',
          () => expect(create, throwsArgumentError));
    }
  });
}
