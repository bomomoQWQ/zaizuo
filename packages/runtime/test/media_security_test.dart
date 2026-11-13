// Independent media-security invariants; production files are not changed here.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

const _password = 'Review!73#MediaOnly8';
const _fast = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
const _scope = 'security-room#main';

final class _Fixture {
  _Fixture(this.root, this.profile, this.node);
  final Directory root;
  final LocalProfile profile;
  final ZaizuoNode node;
  final additionalMedia = <MediaRepository>[];
  String get owner => profile.identity.public.accountId;
  static Future<_Fixture> create() async {
    final root =
        await Directory.systemTemp.createTemp('zaizuo-media-security-');
    await LocalProfile.initialize(root,
        name: 'reviewer',
        displayName: 'Reviewer',
        password: _password,
        parameters: _fast);
    final profile = await LocalProfile.open(root, _password);
    final node = await ZaizuoNode.open(profile: profile);
    final result = _Fixture(root, profile, node);
    await node.execute(operation: 'space.create', params: {
      'id': 'security-room',
      'title': 'Security room',
      'public_channel': true,
    });
    return result;
  }

  Future<MediaRepository> repository({int maxHandles = 4096}) async {
    final media = await MediaRepository.open(
        profile: profile, replica: node.replica, maxHandles: maxHandles);
    additionalMedia.add(media);
    return media;
  }

  Future<void> close() async {
    for (final media in additionalMedia) {
      await media.close();
    }
    await node.close();
    final actual = p.normalize(root.absolute.path);
    if (!p.isWithin(p.normalize(Directory.systemTemp.absolute.path), actual) ||
        !p.basename(actual).startsWith('zaizuo-media-security-')) {
      throw StateError('unexpected security fixture cleanup path');
    }
    await root.delete(recursive: true);
  }

  Future<int> objectCount(MediaRepository media) async =>
      !await media.objects.root.exists()
          ? 0
          : await media.objects.root
              .list(followLinks: false)
              .where((item) => item is File && item.path.endsWith('.bin'))
              .length;
}

Map<String, dynamic> _part(String id) => {
      'type': 'file',
      'data': {'file_id': id}
    };
AttachmentRef _reference(MessageRecord message) => AttachmentRef.fromJson(
    (message.parts.single['data'] as Map<String, dynamic>)['attachment']
        as Map<String, dynamic>);

void main() {
  test('quota拒绝resolve不得先落盘新随机密文，无重复失败磁盘放大', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final media = await f.repository(maxHandles: 1);
    final upload = await media
        .upload(actorId: f.owner, name: 'bounded.bin', bytes: [1, 2, 3]);
    final handle = upload['file_id'] as String;
    await media.resolve(
        actorId: f.owner, conversationId: _scope, parts: [_part(handle)]);
    final before = await f.objectCount(media);
    for (var i = 0; i < 3; i++) {
      await expectLater(
          media.resolve(
              actorId: f.owner, conversationId: _scope, parts: [_part(handle)]),
          throwsA(isA<DomainException>()
              .having((e) => e.code, 'code', 'quota_exceeded')));
      expect(await f.objectCount(media), before,
          reason:
              'quota failure must not leave an unindexed ciphertext object');
    }
  });

  test('cache字节配额拒绝新upload和resolve且不留对象，已有暂存仍能get', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final media = await MediaRepository.open(
        profile: f.profile,
        replica: f.node.replica,
        maxMediaBytes: 4,
        maxCacheBytes: 4,
        maxStagedBytes: 8);
    f.additionalMedia.add(media);
    final upload = await media
        .upload(actorId: f.owner, name: 'full.bin', bytes: [1, 2, 3, 4]);
    final handle = upload['file_id'] as String;
    final before = await f.objectCount(media);
    await expectLater(
        media.upload(actorId: f.owner, name: 'extra.bin', bytes: [5]),
        throwsA(isA<DomainException>()
            .having((e) => e.code, 'code', 'quota_exceeded')));
    await expectLater(
        media.resolve(
            actorId: f.owner, conversationId: _scope, parts: [_part(handle)]),
        throwsA(isA<DomainException>()
            .having((e) => e.code, 'code', 'quota_exceeded')));
    expect(await f.objectCount(media), before);
    expect(
        base64Decode((await media.get(actorId: f.owner, fileId: handle))['data']
            as String),
        [1, 2, 3, 4]);
  });

  test('同一owner的不同bot不得借用upload或record handle，转发仍查原记录权限', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    for (final bot in ['review-bot-a', 'review-bot-b']) {
      await f.node.execute(
          operation: 'bot.register', params: {'id': bot, 'display_name': bot});
      await f.node.execute(
          operation: 'space.join',
          params: {'space': 'security-room', 'bot_id': bot});
    }
    final upload = await f.node.media
        .upload(actorId: 'review-bot-a', name: 'private.bin', bytes: [4, 5, 6]);
    final stageHandle = upload['file_id'] as String;
    await expectLater(
        f.node.media.get(actorId: 'review-bot-b', fileId: stageHandle),
        throwsA(isA<DomainException>()));
    await expectLater(
        f.node.execute(
            actorId: 'review-bot-b',
            operation: 'message.send',
            params: {
              'conversation': _scope,
              'parts': [_part(stageHandle)]
            }),
        throwsA(isA<DomainException>()));
    final sent = await f.node
        .execute(actorId: 'review-bot-a', operation: 'message.send', params: {
      'conversation': _scope,
      'parts': [_part(stageHandle)]
    });
    final record =
        MessageRecord.fromJson(sent['result'] as Map<String, dynamic>);
    final parts =
        await f.node.media.project(actorId: 'review-bot-b', message: record);
    final received = (parts.single['data'] as Map)['file_id'] as String;
    expect(received, isNot(stageHandle));
    expect(
        base64Decode((await f.node.media
            .get(actorId: 'review-bot-b', fileId: received))['data'] as String),
        [4, 5, 6]);
    await f.node.execute(
        operation: 'content.hide',
        params: {'kind': 'message', 'content_id': record.id, 'hidden': true});
    await expectLater(
        f.node.media.get(actorId: 'review-bot-b', fileId: received),
        throwsA(isA<DomainException>()));
    await expectLater(
        f.node.execute(
            actorId: 'review-bot-b',
            operation: 'message.send',
            params: {
              'conversation': _scope,
              'parts': [_part(received)]
            }),
        throwsA(isA<DomainException>()));
  });

  test('opaque发送拒绝URL/path/descriptor注入，失败不产生密文或消息', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final upload = await f.node.media
        .upload(actorId: f.owner, name: 'safe.bin', bytes: [1]);
    final handle = upload['file_id'] as String;
    final count = f.node.store.allEnvelopes.length;
    final files = await f.objectCount(f.node.media);
    for (final data in <Map<String, dynamic>>[
      {'file_id': handle, 'url': 'http://127.0.0.1:1/private'},
      {'file_id': handle, 'path': '../../private'},
      {'file_id': 'file:///etc/passwd'},
      {'file_id': '../../private'},
      {
        'file_id': handle,
        'attachment': <String, dynamic>{
          'scope': _scope,
          'epoch': 1,
          'descriptor': <String, dynamic>{}
        }
      },
    ]) {
      await expectLater(
          f.node.execute(operation: 'message.send', params: {
            'conversation': _scope,
            'parts': [
              {'type': 'file', 'data': data}
            ],
          }),
          throwsA(isA<DomainException>()));
    }
    expect(await f.objectCount(f.node.media), files);
    expect(f.node.store.allEnvelopes.length, count);
  });

  test('replica直接opaque/scope/epoch篡改拒绝，引用必须匹配外层加密事件', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final upload = await f.node.media
        .upload(actorId: f.owner, name: 'safe.bin', bytes: [7, 8]);
    final sent = await f.node.execute(operation: 'message.send', params: {
      'conversation': _scope,
      'parts': [_part(upload['file_id'] as String)]
    });
    final record =
        MessageRecord.fromJson(sent['result'] as Map<String, dynamic>);
    final ref = _reference(record);
    final count = f.node.store.allEnvelopes.length;
    for (final part in <Map<String, dynamic>>[
      _part(upload['file_id'] as String),
      {
        'type': 'file',
        'data': {
          'attachment': {...ref.toJson(), 'scope': 'other-scope'}
        }
      },
      {
        'type': 'file',
        'data': {
          'attachment': {...ref.toJson(), 'epoch': ref.epoch + 1}
        }
      },
      {
        'type': 'image',
        'data': {'attachment': ref.toJson()}
      }, // non-WebP MIME
    ]) {
      await expectLater(
          f.node.replica.execute(
              actorId: f.owner,
              operation: 'message.send',
              conversation: _scope,
              params: {
                'conversation': _scope,
                'parts': [part]
              }),
          throwsA(isA<DomainException>()));
    }
    expect(f.node.store.allEnvelopes.length, count);
  });

  test('合法媒体状态大于1MiB后仍可重新读取，不可写成功后重启锁死', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final upload = await f.node.media
        .upload(actorId: f.owner, name: 'n' * 240, bytes: [1]);
    final stored = await f.profile.readSecretState('media-state.enc');
    final template = Map<String, dynamic>.from(
        (stored!['entries'] as Map)[upload['file_id']] as Map);
    final entries = <String, dynamic>{};
    for (var i = 0; i < 2200; i++) {
      entries[i.toRadixString(16).padLeft(48, '0')] =
          Map<String, dynamic>.from(template);
    }
    final state = {
      'version': 1,
      'entries': entries,
      'outbox': <String, dynamic>{}
    };
    expect(utf8.encode(canonicalJson(state)).length, greaterThan(1024 * 1024));
    expect(utf8.encode(canonicalJson(state)).length, lessThan(6 * 1024 * 1024));
    await f.profile.writeSecretState('media-state.enc', state);
    final reopened = await f.profile.readSecretState('media-state.enc');
    expect((reopened!['entries'] as Map).length, 2200);
  });
}
