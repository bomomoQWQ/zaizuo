import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

const _password = 'OneBotMedia!82#LocalOnly';
const _fastKdf = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
const _token = 'test-only-onebot-media-node-0123456789abcdef';
const _bot = 'onebot-media-bot';
const _space = 'onebot-media-room';
const _room = '$_space#main';

void main() {
  for (final version in [11, 12]) {
    test(
        'real Node HTTP$version uploads image/file, scoped send/project/get, WebP codec and persistent handles after restart',
        () async {
      final root = await Directory.systemTemp.createTemp('zaizuo-node-media-');
      final nodes = <ZaizuoNode>[];
      addTearDown(() async {
        for (final node in nodes.reversed) {
          await node.close();
        }
        if (await root.exists()) await root.delete(recursive: true);
      });
      await LocalProfile.initialize(root,
          name: 'mediaowner',
          displayName: 'Media Owner',
          password: _password,
          parameters: _fastKdf);
      final profile = await LocalProfile.open(root, _password);
      final node = await ZaizuoNode.open(
          profile: profile, syncInterval: const Duration(hours: 1));
      nodes.add(node);
      await node.execute(
          operation: 'bot.register',
          params: {'id': _bot, 'display_name': 'Media Bot'});
      await node.execute(operation: 'space.create', params: {
        'id': _space,
        'title': 'OneBot media',
        'public_channel': true,
      });
      await node.execute(
          operation: 'space.join', params: {'space': _space, 'bot_id': _bot});
      await node.start(botId: _bot, token: _token, port: 0);
      final port = node.port!;
      final supported = await _action(port, version,
          version == 11 ? 'get_version_info' : 'get_supported_actions');
      _ok(supported);
      final actions = version == 11
          ? supported['data']['zaizuo.supported_actions']
          : supported['data'];
      final uploadAction = version == 11 ? 'zaizuo.upload_file' : 'upload_file';
      final getAction = version == 11 ? 'zaizuo.get_file' : 'get_file';
      expect(actions, containsAll([uploadAction, getAction]));
      final mappedGroup = node.ids!.encode('group', _room);
      final original = image.Image(width: 4, height: 3, numChannels: 4);
      for (var y = 0; y < original.height; y++) {
        for (var x = 0; x < original.width; x++) {
          original.setPixelRgba(x, y, 20 + x * 40, 30 + y * 60, 200 - x * 20,
              [0, 64, 127, 255][x]);
        }
      }
      final png = image.encodePng(original);
      final fileBytes = Uint8List.fromList([
        ...utf8.encode(
            'Private binary from actual OneBot Node, not a raw event body!'),
        ...List<int>.generate(2048, (index) => index % 251),
      ]);
      final stages = <String, String>{};
      final projectedHandles = <String, String>{};
      final messageIds = <String, String>{};
      final integerIds = <String, int>{};
      final downloadedBytes = <String, List<int>>{};
      final savedMessages = <String, Map<String, dynamic>>{};

      for (final purpose in ['image', 'file']) {
        final input = purpose == 'image' ? png : fileBytes;
        final up = await _action(port, version, uploadAction, {
          'type': 'data',
          'name': purpose == 'image' ? 'rgba.png' : 'payload.bin',
          'data': base64Encode(input),
          'zaizuo.purpose': purpose,
          'zaizuo.mime':
              purpose == 'image' ? 'image/png' : 'application/octet-stream',
        });
        _ok(up);
        final stage = up['data']['file_id'] as String;
        stages[purpose] = stage;
        final staged = await _action(
            port, version, getAction, {'type': 'data', 'file_id': stage});
        _ok(staged);
        final stagedBytes = base64Decode(staged['data']['data'] as String);
        if (purpose == 'image') {
          expect(staged['data']['zaizuo.mime'], 'image/webp');
          expect(staged['data']['name'], 'rgba.webp');
          _assertLosslessWebp(stagedBytes, original);
          expect(stagedBytes, isNot(png));
        } else {
          expect(stagedBytes, fileBytes);
        }

        final beforeIds = node.replica.service.state.messages.keys.toSet();
        final sent = await _action(
            port, version, version == 11 ? 'send_group_msg' : 'send_message', {
          if (version == 12) 'detail_type': 'group',
          'group_id': version == 11 ? mappedGroup : _room,
          'message': version == 11
              ? '[CQ:$purpose,file=$stage]'
              : [
                  {
                    'type': purpose,
                    'data': {'file_id': stage}
                  },
                ],
        });
        _ok(sent);
        final created = node.replica.service.state.messages.values
            .where((message) => !beforeIds.contains(message.id))
            .single;
        expect(created.senderId, _bot);
        expect(created.conversationId, _room);
        final nativeId = created.id;
        final mappedId = node.ids!.encode('message', nativeId);
        messageIds[purpose] = nativeId;
        integerIds[purpose] = mappedId;
        savedMessages[purpose] = created.toJson();
        expect(sent['data']['message_id'], version == 11 ? mappedId : nativeId);
        final internal = created.parts.single['data'] as Map;
        expect(internal.keys.toSet(), {'attachment'});
        final reference = AttachmentRef.fromJson(
            internal['attachment'] as Map<String, dynamic>);
        expect(reference.scope, _room);
        expect(reference.epoch, greaterThanOrEqualTo(1));
        expect(reference.descriptor.mime,
            purpose == 'image' ? 'image/webp' : 'application/octet-stream');
        expect(canonicalJson(created.toJson()), isNot(contains(stage)));
        final object = File(
            '${root.path}/attachments/${reference.descriptor.objectId}.bin');
        final ciphertext = await object.readAsBytes();
        expect(await sha256Hex(ciphertext), reference.descriptor.objectId);
        expect(ciphertext, isNot(stagedBytes));
        expect(base64Encode(ciphertext), isNot(base64Encode(input)));

        final fetched =
            await _action(port, 11, 'get_msg', {'message_id': mappedId});
        _ok(fetched);
        final publicPart = (fetched['data']['message'] as List).single as Map;
        expect(publicPart['type'], purpose);
        final publicData = publicPart['data'] as Map;
        expect(publicData.keys.toSet(), {'file', 'file_id', 'name', 'mime'});
        final recordHandle = publicData['file_id'] as String;
        projectedHandles[purpose] = recordHandle;
        expect(recordHandle, isNot(stage));
        expect(publicData['file'], recordHandle);
        expect(jsonEncode(fetched), isNot(contains('descriptor')));
        expect(jsonEncode(fetched), isNot(contains('attachment')));
        expect(
            jsonEncode(fetched), isNot(contains(reference.descriptor.nonce)));
        final polled = await _action(port, 12, 'get_latest_events');
        _ok(polled);
        final event = (polled['data'] as List)
            .singleWhere((event) => event['message_id'] == nativeId);
        expect(event['message'].single['data']['file_id'], recordHandle);
        expect(event['self'], {'platform': 'zaizuo', 'user_id': _bot});
        expect(
            event['message'].single['data']['mime'], reference.descriptor.mime);
        final got = await _action(port, version, getAction,
            {'type': 'data', 'file_id': recordHandle});
        _ok(got);
        final clear = base64Decode(got['data']['data'] as String);
        downloadedBytes[purpose] = clear;
        expect(clear, stagedBytes);
        if (purpose == 'image')
          _assertLosslessWebp(clear, original);
        else
          expect(clear, fileBytes);
      }

      final encryptedLog = await node.store.logFile.readAsString();
      for (final value in [
        base64Encode(png),
        base64Encode(fileBytes),
        utf8.decode(fileBytes.take(64).toList(), allowMalformed: true),
        ...stages.values,
        ...projectedHandles.values
      ]) {
        expect(encryptedLog, isNot(contains(value)));
      }
      final diskMedia = await profile.file('media-state.enc').readAsString();
      for (final id in [...stages.values, ...projectedHandles.values]) {
        expect(diskMedia, isNot(contains(id)));
      }
      // URL/path或自报source不能新建stage、改字节、写入事件；请求仅回拒绝码。
      final count = node.store.allEnvelopes.length;
      final mediaBefore = await profile.file('media-state.enc').readAsBytes();
      for (final request in [
        {
          'type': 'url',
          'name': 'forbidden.bin',
          'url': 'http://127.0.0.1:1/private'
        },
        {
          'type': 'path',
          'name': 'forbidden.bin',
          'path': '/private/never-read'
        },
        {
          'type': 'data',
          'name': 'forbidden.bin',
          'data': 'AQ==',
          'path': r'C:\private\never-read'
        },
      ]) {
        final denied = await _action(port, version, uploadAction, request);
        expect(denied['status'], 'failed');
        expect(denied['retcode'], version == 11 ? 1400 : 10004);
      }
      expect(node.store.allEnvelopes.length, count);
      expect(await profile.file('media-state.enc').readAsBytes(), mediaBefore);
      for (final purpose in ['image', 'file']) {
        final still = await _action(port, version, getAction,
            {'type': 'data', 'file_id': stages[purpose]});
        _ok(still);
        expect(base64Decode(still['data']['data'] as String),
            downloadedBytes[purpose]);
      }
      expect(node.replica.rejected, isEmpty);
      await node.close();
      final reopenedProfile = await LocalProfile.open(root, _password);
      final reopened = await ZaizuoNode.open(
          profile: reopenedProfile, syncInterval: const Duration(hours: 1));
      nodes.add(reopened);
      await reopened.start(botId: _bot, token: _token, port: 0);
      final newPort = reopened.port!;
      for (final purpose in ['image', 'file']) {
        expect(reopened.ids!.decode('message', integerIds[purpose]),
            messageIds[purpose]);
        expect(
            reopened.replica.service.state.messages[messageIds[purpose]]!
                .toJson(),
            savedMessages[purpose]);
        final stageData = await _action(newPort, version, getAction,
            {'type': 'data', 'file_id': stages[purpose]});
        _ok(stageData);
        expect(base64Decode(stageData['data']['data'] as String),
            downloadedBytes[purpose]);
        final referenceData = await _action(newPort, version, getAction,
            {'type': 'data', 'file_id': projectedHandles[purpose]});
        _ok(referenceData);
        expect(base64Decode(referenceData['data']['data'] as String),
            downloadedBytes[purpose]);
        final message = await _action(
            newPort, 11, 'get_msg', {'message_id': integerIds[purpose]});
        _ok(message);
        expect(message['data']['message'].single['data']['file_id'],
            projectedHandles[purpose]);
      }
      expect(reopened.replica.rejected, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}

void _assertLosslessWebp(List<int> bytes, image.Image original) {
  expect(ascii.decode(bytes.take(4).toList()), 'RIFF');
  expect(ascii.decode(bytes.skip(8).take(4).toList()), 'WEBP');
  final decoded = image.decodeWebP(Uint8List.fromList(bytes));
  expect(decoded, isNotNull);
  expect([decoded!.width, decoded.height], [original.width, original.height]);
  for (var y = 0; y < original.height; y++) {
    for (var x = 0; x < original.width; x++) {
      final a = original.getPixel(x, y);
      final b = decoded.getPixel(x, y);
      expect([b.r, b.g, b.b, b.a], [a.r, a.g, a.b, a.a], reason: 'RGBA($x,$y)');
    }
  }
}

Future<Map<String, dynamic>> _action(int port, int version, String action,
    [Map<String, dynamic> params = const {}]) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client
        .postUrl(Uri.parse('http://127.0.0.1:$port/onebot/v$version'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    request.headers.contentType = ContentType.json;
    final echo = version == 11
        ? {
            'media-node': [11, true]
          }
        : 'media-node-12';
    request
        .write(jsonEncode({'action': action, 'params': params, 'echo': echo}));
    final response = await request.close().timeout(const Duration(seconds: 15));
    expect(response.statusCode,
        version == 11 && action == 'upload_file' ? 404 : 200);
    final result = jsonObject(await utf8.decoder.bind(response).join());
    expect(result['echo'], echo);
    return result;
  } finally {
    client.close(force: true);
  }
}

void _ok(Map<String, dynamic> response) {
  expect(response['status'], 'ok', reason: '$response');
  expect(response['retcode'], 0);
}
