import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_onebot/zaizuo_onebot.dart';

import 'helpers.dart';

void main() {
  for (final version in [11, 12]) {
    test(
        'HTTP v$version data upload/image-file references/get and per-bot authorization',
        () async {
      final f = Fixture();
      final host = _MediaHost(f);
      final b = host.backend('bot-a');
      final p = OneBotProjection(backend: b);
      final b2 = host.backend('bot-b');
      final p2 = OneBotProjection(backend: b2);
      final server = OneBotServer(bindings: [
        OneBotBinding(token: token, projection: p),
        OneBotBinding(token: secondToken, projection: p2)
      ], limits: OneBotLimits.media());
      await server.start();
      addTearDown(() async {
        await server.close();
        await p.close();
        await p2.close();
        await b.close();
        await b2.close();
        await f.close();
      });
      final bytes =
          List<int>.generate(70000, (i) => i % 251); // 超过旧64KiB，仍在明确wirecap内。
      final up = await _action(server.port, version,
          version == 11 ? 'zaizuo.upload_file' : 'upload_file', {
        'type': 'data',
        'name': '../photo?.png',
        'data': base64Encode(bytes),
        'zaizuo.mime': 'image/png',
        'zaizuo.purpose': 'image'
      });
      expectOk(up);
      final stage = up['data']['file_id'] as String;
      final getAction = version == 11 ? 'zaizuo.get_file' : 'get_file';
      final source = await _action(
          server.port, version, getAction, {'type': 'data', 'file_id': stage});
      expectOk(source);
      expect(base64Decode(source['data']['data'] as String), bytes);
      expect(source['data']['name'], '.._photo_.png');
      expect(source['data']['zaizuo.mime'], 'image/png');
      final forbidden = await _action(
          server.port, version, getAction, {'type': 'data', 'file_id': stage},
          auth: secondToken);
      expect(forbidden['retcode'], version == 11 ? 1403 : 35001);
      final sent = await _action(server.port, version,
          version == 11 ? 'send_group_msg' : 'send_message', {
        if (version == 12) 'detail_type': 'group',
        'group_id': version == 11 ? p.ids.encode('group', f.roomId) : f.roomId,
        'message': [
          {
            'type': 'image',
            'data': {version == 11 ? 'file' : 'file_id': stage}
          }
        ]
      });
      expectOk(sent);
      final record = f.service.state.messages.values.single;
      final data = record.parts.single['data'] as Map;
      expect(data.keys, ['attachment']);
      expect(data['attachment']['scope'], f.roomId);
      expect(data['attachment']['epoch'], 1);
      expect(jsonEncode(record.toJson()), isNot(contains(base64Encode(bytes))));
      expect(jsonEncode(record.toJson()), isNot(contains(stage)));
      final events = await _action(server.port, 12, 'get_latest_events', {});
      expectOk(events);
      final delivered = events['data'].single['message'].single['data'];
      expect(delivered.keys.toSet(), {'file_id', 'name', 'mime'});
      final retrieved = await _action(server.port, version, getAction,
          {'type': 'data', 'file_id': delivered['file_id']});
      expectOk(retrieved);
      expect(base64Decode(retrieved['data']['data'] as String), bytes);
      final other = await _action(server.port, version, getAction,
          {'type': 'data', 'file_id': delivered['file_id']},
          auth: secondToken);
      expect(other['status'], 'failed');
      final senderFail = await _action(
          server.port,
          version,
          version == 11 ? 'send_group_msg' : 'send_message',
          {
            if (version == 12) 'detail_type': 'group',
            'group_id':
                version == 11 ? p2.ids.encode('group', f.roomId) : f.roomId,
            'message': [
              {
                'type': 'file',
                'data': {'file_id': stage}
              }
            ]
          },
          auth: secondToken);
      expect(senderFail['status'], 'failed');
      expect(f.service.state.messages, hasLength(1));
      // 标准v11没有upload_file，不能因为扩展安装就伪装已实现。
      if (version == 11)
        expect((await _action(server.port, 11, 'upload_file', {}))['retcode'],
            1404);
    });

    test(
        'WS v$version roundtrips file/image and does not expose internal descriptor keys',
        () async {
      final f = Fixture();
      final host = _MediaHost(f);
      final b = host.backend('bot-a');
      final p = OneBotProjection(backend: b);
      final server = OneBotServer(
          bindings: [OneBotBinding(token: token, projection: p)],
          limits: OneBotLimits.media(maxMediaBytes: 1024));
      await server.start();
      final ws = await connectWs(server.port, version);
      final inbox = WsInbox(ws);
      addTearDown(() async {
        await ws.close();
        await inbox.close();
        await server.close();
        await p.close();
        await b.close();
        await f.close();
      });
      final upload = version == 11 ? 'zaizuo.upload_file' : 'upload_file';
      final get = version == 11 ? 'zaizuo.get_file' : 'get_file';
      for (final purpose in ['file', 'image']) {
        ws.add(jsonEncode({
          'action': upload,
          'params': {
            'type': 'data',
            'name': '$purpose.bin',
            'data': base64Encode([1, 2, 3]),
            'zaizuo.purpose': purpose,
            'zaizuo.mime':
                purpose == 'image' ? 'image/png' : 'application/octet-stream'
          },
          'echo': 'up-$purpose'
        }));
        final result =
            await inbox.next((value) => value['echo'] == 'up-$purpose');
        expectOk(result);
        final id = result['data']['file_id'] as String;
        ws.add(jsonEncode({
          'action': version == 11 ? 'send_group_msg' : 'send_message',
          'params': {
            if (version == 12) 'detail_type': 'group',
            'group_id':
                version == 11 ? p.ids.encode('group', f.roomId) : f.roomId,
            // v11 CQ原生image/file引用；不把base64://或URL放CQ。
            'message': version == 11
                ? '[CQ:$purpose,file=$id]'
                : [
                    {
                      'type': purpose,
                      'data': {'file_id': id}
                    }
                  ]
          },
          'echo': 'send-$purpose'
        }));
        expectOk(await inbox.next((value) => value['echo'] == 'send-$purpose'));
        final event = await inbox.next((value) =>
            value[version == 11 ? 'notice_type' : 'detail_type'] ==
            'zaizuo.message_sent');
        final media = event['message'].single['data'] as Map;
        expect(media['file_id'], isA<String>());
        expect(media.containsKey('attachment'), isFalse);
        expect(jsonEncode(event), isNot(contains('storage-secret')));
        ws.add(jsonEncode({
          'action': get,
          'params': {'type': 'data', 'file_id': media['file_id']},
          'echo': 'get-$purpose'
        }));
        final downloaded =
            await inbox.next((value) => value['echo'] == 'get-$purpose');
        expectOk(downloaded);
        expect(base64Decode(downloaded['data']['data'] as String), [1, 2, 3]);
      }
    });
  }

  test(
      'media security rejects URL/path/checksum/bad Base64/oversize before trusted upload callback',
      () async {
    final f = Fixture();
    final host = _MediaHost(f);
    final b = host.backend('bot-a', maxBytes: 16);
    final p = OneBotProjection(backend: b);
    addTearDown(() async {
      await p.close();
      await b.close();
      await f.close();
    });
    Future<Map<String, dynamic>> call(
            String action, Map<String, dynamic> params) =>
        p.handle(12, {'action': action, 'params': params});
    for (final request in [
      {'type': 'url', 'name': 'a', 'url': 'http://127.0.0.1/private'},
      {'type': 'path', 'name': 'a', 'path': r'C:\Users\secret'},
      {
        'type': 'data',
        'name': 'a',
        'data': 'AQ==',
        'headers': {'Authorization': 'secret'}
      },
      {'type': 'data', 'name': 'a', 'data': 'AQ==', 'sha256': '0' * 64},
      {'type': 'data', 'name': 'a', 'data': 'AQ'},
      {'type': 'data', 'name': 'a', 'data': '@@=='},
      {'type': 'data', 'name': 'a', 'data': base64Encode(List.filled(17, 1))},
      {'type': 'data', 'name': 'a' * 257, 'data': 'AQ=='},
      {
        'type': 'data',
        'name': 'a',
        'data': 'AQ==',
        'zaizuo.mime': 'text/plain\r\nsecret'
      },
    ]) {
      expect((await call('upload_file', request))['status'], 'failed');
    }
    expect(host.uploads, 0);
    for (final id in [
      'http://127.0.0.1/x',
      r'C:\secret',
      '../file',
      'base64://AQ=='
    ]) {
      expect(
          (await call('get_file', {'type': 'data', 'file_id': id}))['status'],
          'failed');
      expect(
          (await call('send_message', {
            'detail_type': 'group',
            'group_id': f.roomId,
            'message': [
              {
                'type': 'image',
                'data': {'file_id': id}
              }
            ]
          }))['status'],
          'failed');
    }
    expect(host.resolutions, 0);
    expect(f.service.state.messages, isEmpty);
  });

  test(
      'partial/no media configuration does not advertise or silently accept image/file',
      () async {
    final f = Fixture();
    final b = DomainOneBotBackend(f.service,
        botId: 'bot-a',
        mediaUploadHandler: (
                {required actor,
                required name,
                required bytes,
                required mime,
                required purpose}) =>
            {'file_id': 'unused'});
    final p = OneBotProjection(backend: b);
    addTearDown(() async {
      await p.close();
      await b.close();
      await f.close();
    });
    expect(
        (await p.handle(
            12, {'action': 'get_supported_actions', 'params': {}}))['data'],
        isNot(contains('upload_file')));
    expect(
        (await p.handle(12, {
          'action': 'upload_file',
          'params': {'type': 'data', 'name': 'a', 'data': 'AQ=='}
        }))['retcode'],
        10002);
    expect(
        (await p.handle(12, {
          'action': 'send_message',
          'params': {
            'detail_type': 'group',
            'group_id': f.roomId,
            'message': [
              {
                'type': 'file',
                'data': {'file_id': 'ref'}
              }
            ]
          }
        }))['retcode'],
        10005);
  });

  test(
      'media resolves after target permission/cap check and download rechecks revoked permission',
      () async {
    final f = Fixture();
    final host = _MediaHost(f);
    final b = host.backend('bot-a');
    final p = OneBotProjection(backend: b);
    addTearDown(() async {
      await p.close();
      await b.close();
      await f.close();
    });
    final upload = await p.handle(12, {
      'action': 'upload_file',
      'params': {'type': 'data', 'name': 'a.bin', 'data': 'AQ=='}
    });
    final id = upload['data']['file_id'];
    f.service.mute(actor: f.alice, spaceId: 'space', principalId: 'bot-a');
    final blocked = await p.handle(12, {
      'action': 'send_message',
      'params': {
        'detail_type': 'group',
        'group_id': f.roomId,
        'message': [
          {
            'type': 'file',
            'data': {'file_id': id}
          }
        ]
      }
    });
    expect(blocked['retcode'], 35001);
    expect(host.resolutions, 0);
    f.service.mute(
        actor: f.alice, spaceId: 'space', principalId: 'bot-a', muted: false);
    expectOk(await p.handle(12, {
      'action': 'send_message',
      'params': {
        'detail_type': 'group',
        'group_id': f.roomId,
        'message': [
          {
            'type': 'file',
            'data': {'file_id': id}
          }
        ]
      }
    }));
    final message = f.service.state.messages.values.single;
    final visible = await b.getMessage(message.id);
    final ref = visible.parts.single['data']['file_id'];
    f.service.setBotCaps(
        actor: f.alice, botId: 'bot-a', caps: {BotCapability.sendMessage});
    expect(
        (await p.handle(12, {
          'action': 'get_file',
          'params': {'type': 'data', 'file_id': ref}
        }))['retcode'],
        35001);
  });

  test(
      'asynchronous media projection preserves event order and sends no incomplete first frame',
      () async {
    final f = Fixture();
    final gate = Completer<void>();
    final started = Completer<void>();
    final host = _MediaHost(f, projectGate: () async {
      if (!started.isCompleted) started.complete();
      await gate.future;
    });
    final b = host.backend('bot-a');
    final p = OneBotProjection(backend: b);
    final events = <OneBotEvent>[];
    final sub = p.events.listen(events.add);
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await sub.cancel();
      await p.close();
      await b.close();
      await f.close();
    });
    final parts = await host.resolve(
        actor: f.service.actor('bot-a'),
        conversationId: f.roomId,
        parts: [
          {
            'type': 'file',
            'data': {
              'file_id': host.stage('bot-a', [1], 'file')
            }
          }
        ]);
    final media = f.service
        .sendMessage(actor: f.bob, conversationId: f.roomId, parts: parts);
    f.service.sendMessage(actor: f.bob, conversationId: f.roomId, parts: [
      {
        'type': 'text',
        'data': {'text': 'second'}
      }
    ]);
    await started.future;
    expect(events, isEmpty);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(2));
    expect(events.first.v12['message_id'], media.id);
    expect(events.first.v12['message'].single['type'], 'file');
    expect(events.last.v12['message'].single['data']['text'], 'second');
  });

  test(
      'forum/feed publish and authorized queries resolve/project image-file scopes without leaking descriptor',
      () async {
    final f = Fixture();
    f.service.configureCommunity(
        actor: f.alice, config: CommunityConfig(botPostsPerHour: 0));
    f.service.createRoom(
        actor: f.alice,
        spaceId: 'space',
        id: 'media-forum',
        title: 'Media',
        kind: 'forum');
    final host = _MediaHost(f);
    final b = host.backend('bot-a');
    final p = OneBotProjection(backend: b);
    addTearDown(() async {
      await p.close();
      await b.close();
      await f.close();
    });
    final stage = host.stage('bot-a', [1, 2], 'file');
    final message = [
      {
        'type': 'file',
        'data': {'file_id': stage}
      }
    ];
    final forum = await p.handle(12, {
      'action': 'zaizuo.post_forum',
      'params': {
        'room_id': 'media-forum',
        'title': 'with file',
        'message': message
      }
    });
    expectOk(forum);
    expect(forum['data']['message'].single['data'].keys.toSet(),
        {'file_id', 'name', 'mime'});
    expect(
        f.service.state.messages[forum['data']['message_id']]!.parts
            .single['data']['attachment']['scope'],
        'media-forum');
    final feed = await p.handle(11, {
      'action': 'zaizuo.post_feed',
      'params': {'visibility': 'private', 'message': message}
    });
    expectOk(feed);
    expect(
        f.service.state.feedPosts.values.single.parts.single['data']
            ['attachment']['scope'],
        'feed:bot-a:private');
    final read = await p.handle(12, {
      'action': 'zaizuo.get_feed',
      'params': {'post_id': feed['data']['post_id']}
    });
    expectOk(read);
    expect(jsonEncode(read), isNot(contains('storage-secret')));
    final file = await p.handle(12, {
      'action': 'get_file',
      'params': {
        'type': 'data',
        'file_id': read['data'].single['message'].single['data']['file_id']
      }
    });
    expectOk(file);
    expect(file['data']['data'], base64Encode([1, 2]));
  });

  test(
      'trusted Node-style opaque resolver defers encryption exactly once to committing handler',
      () async {
    final f = Fixture();
    final host = _MediaHost(f);
    final b = host.backend('bot-a', deferResolution: true);
    final p = OneBotProjection(backend: b);
    addTearDown(() async {
      await p.close();
      await b.close();
      await f.close();
    });
    final stage = host.stage('bot-a', [9, 8, 7], 'file');
    final result = await p.handle(12, {
      'action': 'send_message',
      'params': {
        'detail_type': 'group',
        'group_id': f.roomId,
        'message': [
          {
            'type': 'file',
            'data': {'file_id': stage}
          }
        ]
      }
    });
    expectOk(result);
    expect(host.resolutions, 1);
    expect(f.service.state.messages.values.single.parts.single['data'].keys,
        ['attachment']);
    final message =
        await b.getMessage(f.service.state.messages.values.single.id);
    expect(
        message.parts.single['data'].keys.toSet(), {'file_id', 'name', 'mime'});
  });

  test(
      'explicit media transport handles exact 8MiB upload/download without unbounded defaults',
      () async {
    final f = Fixture();
    final host = _MediaHost(f);
    final b = host.backend('bot-a');
    final p = OneBotProjection(backend: b);
    final limits = OneBotLimits.media();
    expect(limits.maxBodyBytes, ((8 * 1024 * 1024 + 2) ~/ 3) * 4 + 65536);
    expect(const OneBotLimits().maxBodyBytes, 65536);
    final server = OneBotServer(
        bindings: [OneBotBinding(token: token, projection: p)], limits: limits);
    await server.start();
    addTearDown(() async {
      await server.close();
      await p.close();
      await b.close();
      await f.close();
    });
    final bytes = List<int>.generate(8 * 1024 * 1024, (i) => i % 251);
    final uploaded = await _action(server.port, 12, 'upload_file',
        {'type': 'data', 'name': 'max.bin', 'data': base64Encode(bytes)});
    expectOk(uploaded);
    final downloaded = await _action(server.port, 12, 'get_file',
        {'type': 'data', 'file_id': uploaded['data']['file_id']});
    expectOk(downloaded);
    expect(downloaded['data']['zaizuo.size'], bytes.length);
    expect(base64Decode(downloaded['data']['data'] as String), bytes);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
      'media action concurrency is bounded independently of general action queue',
      () async {
    final f = Fixture();
    final gate = Completer<void>();
    final entered = Completer<void>();
    final host = _MediaHost(f, uploadGate: () async {
      if (!entered.isCompleted) entered.complete();
      await gate.future;
    });
    final b = host.backend('bot-a');
    final p = OneBotProjection(backend: b, maxConcurrentMediaActions: 1);
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await p.close();
      await b.close();
      await f.close();
    });
    final request = {
      'action': 'upload_file',
      'params': {'type': 'data', 'name': 'a', 'data': 'AQ=='}
    };
    final pending = p.handle(12, request);
    await entered.future;
    expect((await p.handle(12, request))['retcode'], 35004);
    gate.complete();
    expectOk(await pending);
  });
}

Future<Map<String, dynamic>> _action(
    int port, int version, String action, Map<String, dynamic> params,
    {String auth = token}) async {
  final result = await httpCall(
      port,
      '/onebot/v$version',
      {
        'action': action,
        'params': params,
        'echo': version == 11 ? {'media': true} : 'media'
      },
      authorization: auth);
  return result.json;
}

/// 测试用可信宿主，不是假装生产加密仓库；验证真实Domain adapter与协议边界。
/// 原始字节只在host内存map，消息只存scope/epoch/不透明descriptor；实际AES实现由runtime测试。
class _MediaHost {
  _MediaHost(this.f, {this.projectGate, this.uploadGate});
  final Fixture f;
  final Future<void> Function()? projectGate;
  final Future<void> Function()? uploadGate;
  final _stages = <String, ({String owner, List<int> bytes, String purpose})>{};
  final _objects = <String, List<int>>{};
  final _refs = <String, ({String owner, MessageRecord message, int index})>{};
  int _next = 0;
  int uploads = 0;
  int resolutions = 0;
  String stage(String bot, List<int> bytes, String purpose) {
    final id = 'stage_${++_next}';
    _stages[id] = (owner: bot, bytes: bytes, purpose: purpose);
    return id;
  }

  DomainOneBotBackend backend(String bot,
          {int maxBytes = 8 * 1024 * 1024, bool deferResolution = false}) =>
      DomainOneBotBackend(f.service,
          botId: bot,
          maxMediaBytes: maxBytes,
          mediaUploadHandler: (
              {required actor,
              required name,
              required bytes,
              required mime,
              required purpose}) async {
            uploads++;
            await uploadGate?.call();
            return {
              'file_id': stage(actor.id, bytes, purpose),
              'name': name,
              'mime': mime,
              'size': bytes.length
            };
          },
          mediaGetHandler: ({required actor, required fileId}) async =>
              get(actor, fileId),
          resolveMediaParts: deferResolution
              ? ({required actor, required conversationId, required parts}) =>
                  parts
              : resolve,
          sendHandler: deferResolution
              ? (
                  {required actor,
                  required conversationId,
                  required parts}) async {
                  final encrypted = await resolve(
                      actor: actor,
                      conversationId: conversationId,
                      parts: parts);
                  return f.service.sendMessage(
                      actor: actor,
                      conversationId: conversationId,
                      parts: encrypted);
                }
              : null,
          projectMediaParts: ({required actor, required message}) async {
            await projectGate?.call();
            return List.generate(message.parts.length, (i) {
              final part = message.parts[i];
              if (part['type'] != 'image' && part['type'] != 'file')
                return part;
              final id = 'ref_${++_next}';
              _refs[id] = (owner: actor.id, message: message, index: i);
              return {
                'type': part['type'],
                'data': {
                  'file_id': id,
                  'name': part['type'] == 'image' ? 'photo.png' : 'a.bin',
                  'mime': part['type'] == 'image'
                      ? 'image/png'
                      : 'application/octet-stream',
                  'attachment': 'storage-secret-ignored'
                }
              };
            });
          });
  Future<List<Map<String, dynamic>>> resolve(
      {required Actor actor,
      required String conversationId,
      required List<Map<String, dynamic>> parts}) async {
    resolutions++;
    return parts.map((part) {
      if (part['type'] != 'image' && part['type'] != 'file') return part;
      final id = (part['data'] as Map)['file_id'] as String;
      final staged = _stages[id];
      final List<int> bytes;
      if (staged != null) {
        if (staged.owner != actor.id)
          throw const OneBotFailure('forbidden', 'Not your upload');
        if (part['type'] == 'image' && staged.purpose != 'image')
          throw const OneBotFailure('forbidden', 'Not an image upload');
        bytes = staged.bytes;
      } else {
        bytes = base64Decode(get(actor, id)['data'] as String);
      }
      final object = 'object_${++_next}';
      _objects[object] = bytes;
      return <String, dynamic>{
        'type': part['type'],
        'data': {
          'attachment': {
            'scope': conversationId,
            'epoch': 1,
            'descriptor': {
              'object_id': object,
              'key': 'storage-secret',
              'name': part['type'] == 'image' ? 'photo.png' : 'a.bin'
            }
          }
        }
      };
    }).toList();
  }

  Map<String, dynamic> get(Actor actor, String id) {
    final stage = _stages[id];
    final List<int> bytes;
    if (stage != null) {
      if (stage.owner != actor.id)
        throw const OneBotFailure('forbidden', 'Not your file');
      bytes = stage.bytes;
    } else {
      final ref = _refs[id];
      if (ref == null || ref.owner != actor.id)
        throw const OneBotFailure('forbidden', 'Unknown reference');
      final record = ref.message;
      if (f.service.state.messages.containsKey(record.id)) {
        f.service.message(actor: actor, messageId: record.id);
      } else if (f.service.state.feedPosts.containsKey(record.id)) {
        f.service.feedPost(actor: actor, postId: record.id);
      } else {
        final comment = f.service.state.feedComments[record.id]!;
        f.service.feedComments(actor: actor, postId: comment.postId);
      }
      final object = ((record.parts[ref.index]['data'] as Map)['attachment']
          ['descriptor']['object_id']) as String;
      bytes = _objects[object]!;
    }
    return {
      'name': stage?.purpose == 'image' ? '.._photo_.png' : 'a.bin',
      'mime':
          stage?.purpose == 'image' ? 'image/png' : 'application/octet-stream',
      'size': bytes.length,
      'data': base64Encode(bytes)
    };
  }
}
