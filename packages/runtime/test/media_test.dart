import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

const _password = 'Media!72#LocalOnly9';
const _fastKdf = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
const _lobby = 'media-lobby#main';

void main() {
  test(
      'opaque upload -> encrypted stage -> scoped file -> real Git -> projection/get and persistent handle',
      () async {
    final fixture = await _MediaFixture.create();
    addTearDown(fixture.close);
    final plain = Uint8List.fromList([
      ...utf8.encode('Private file bytes, never a public Git blob!'),
      ...List<int>.generate(2048, (i) => i % 256),
    ]);
    final uploaded = await fixture.a.media.upload(
        actorId: fixture.aliceId,
        name: 'private-file.bin',
        bytes: plain,
        purpose: 'file');
    final fileId = uploaded['file_id'] as String;
    final secret = await fixture.alice.readSecretState('media-state.enc');
    final stage = (secret!['entries'] as Map)[fileId] as Map<String, dynamic>;
    final stageRef =
        AttachmentRef.fromJson(stage['ref'] as Map<String, dynamic>);
    final stageKey = stage['key'] as String;
    final staged = File(p.join(fixture.alice.root.path, 'attachments',
        '${stageRef.descriptor.objectId}.bin'));
    final stageBytes = await staged.readAsBytes();
    expect(stageBytes, isNot(plain));
    expect(await sha256Hex(stageBytes), stageRef.descriptor.objectId);
    final secretDisk =
        await fixture.alice.file('media-state.enc').readAsString();
    expect(secretDisk, isNot(contains(fileId)));
    expect(secretDisk, isNot(contains(stageKey)));
    final count = fixture.a.store.allEnvelopes.length;
    final sent = await fixture.a.execute(operation: 'message.send', params: {
      'conversation': _lobby,
      'parts': [_part('file', fileId)],
    });
    final event = fixture.a.store.allEnvelopes
        .singleWhere((e) => e.id == sent['event_id']);
    final body = await event
        .decrypt(fixture.key(fixture.a, event.conversation, event.epoch));
    final signedParams = canonicalJson(body['params']);
    expect(signedParams, isNot(contains(fileId)));
    expect(signedParams, isNot(contains('file_id')));
    expect(signedParams, isNot(contains('stage:')));
    expect(signedParams, isNot(contains(stageKey)));
    final message =
        MessageRecord.fromJson(sent['result'] as Map<String, dynamic>);
    final ref = _ref(message.parts.single);
    expect(ref.scope, _lobby);
    expect(ref.descriptor.objectId, isNot(stageRef.descriptor.objectId));
    expect(fixture.a.store.allEnvelopes.length, count + 1);
    // resolve must publish ciphertext before message.send's durable event is
    // returned, before the next dev-branch synchronization has happened.
    final remoteCipher = await fixture.remoteObject(ref.descriptor.objectId);
    expect(await sha256Hex(remoteCipher), ref.descriptor.objectId);
    expect(remoteCipher, isNot(plain));
    expect(remoteCipher, isNot(stageBytes));
    await fixture.exchange();
    final received = fixture.b.replica.service.message(
        actor: fixture.b.replica.service.actor(fixture.bobId),
        messageId: message.id);
    final projected = await fixture.b.media
        .project(actorId: fixture.bobId, message: received);
    final receivedId = (projected.single['data'] as Map)['file_id'] as String;
    expect(receivedId, isNot(fileId));
    final loaded =
        await fixture.b.media.get(actorId: fixture.bobId, fileId: receivedId);
    expect(base64Decode(loaded['data'] as String), plain);
    expect(loaded['name'], 'private-file.bin');
    await expectLater(
        fixture.b.media.get(actorId: fixture.aliceId, fileId: receivedId),
        throwsA(
            isA<DomainException>().having((e) => e.code, 'code', 'forbidden')));
    await expectLater(
        fixture.b.media.get(actorId: fixture.bobId, fileId: fileId),
        throwsA(
            isA<DomainException>().having((e) => e.code, 'code', 'forbidden')));
    await fixture.b.execute(
        operation: 'bot.register',
        params: {'id': 'media-bob-bot', 'display_name': 'Media Bot'});
    await expectLater(
        fixture.b.media.get(actorId: 'media-bob-bot', fileId: receivedId),
        throwsA(
            isA<DomainException>().having((e) => e.code, 'code', 'forbidden')));
    final originalObject = ref.descriptor.objectId;
    await fixture.b.execute(operation: 'space.create', params: {
      'id': 'bob-private',
      'title': 'Bob private',
      'public_channel': false,
    });
    final forwarded =
        await fixture.b.execute(operation: 'message.send', params: {
      'conversation': 'bob-private#main',
      'parts': [_part('file', receivedId)],
    });
    final forwardRef = _ref(
        MessageRecord.fromJson(forwarded['result'] as Map<String, dynamic>)
            .parts
            .single);
    expect(forwardRef.scope, 'bob-private#main');
    expect(forwardRef.descriptor.objectId, isNot(originalObject));
    expect(forwardRef.descriptor.nonce, isNot(ref.descriptor.nonce));
    expect(await fixture.remoteObject(forwardRef.descriptor.objectId),
        isNot(remoteCipher));
    await fixture.reopenBob();
    final afterRestart =
        await fixture.b.media.get(actorId: fixture.bobId, fileId: receivedId);
    expect(base64Decode(afterRestart['data'] as String), plain);
    expect(fixture.b.replica.rejected, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test(
      'RGBA PNG upload becomes lossless WebP across encrypted scope and Git, all pixels preserved',
      () async {
    final fixture = await _MediaFixture.create();
    addTearDown(fixture.close);
    final original = image.Image(width: 4, height: 3, numChannels: 4);
    for (var y = 0; y < original.height; y++) {
      for (var x = 0; x < original.width; x++) {
        original.setPixelRgba(
            x, y, 20 + x * 40, 30 + y * 60, 200 - x * 20, [0, 64, 127, 255][x]);
      }
    }
    final png = image.encodePng(original);
    final upload = await fixture.a.media.upload(
        actorId: fixture.aliceId,
        name: 'rgba.png',
        bytes: png,
        mime: 'image/png',
        purpose: 'image');
    expect(upload['mime'], 'image/webp');
    expect(upload['name'], 'rgba.webp');
    final sent = await fixture.a.execute(operation: 'message.send', params: {
      'conversation': _lobby,
      'parts': [_part('image', upload['file_id'] as String)],
    });
    final message =
        MessageRecord.fromJson(sent['result'] as Map<String, dynamic>);
    final reference = _ref(message.parts.single);
    expect(
        await sha256Hex(
            await fixture.remoteObject(reference.descriptor.objectId)),
        reference.descriptor.objectId);
    await fixture.exchange();
    final received = fixture.b.replica.service.message(
        actor: fixture.b.replica.service.actor(fixture.bobId),
        messageId: message.id);
    final projection = await fixture.b.media
        .project(actorId: fixture.bobId, message: received);
    final data = await fixture.b.media.get(
        actorId: fixture.bobId,
        fileId: (projection.single['data'] as Map)['file_id'] as String);
    final webp = base64Decode(data['data'] as String);
    final restored = image.decodeWebP(webp)!;
    expect(
        [restored.width, restored.height], [original.width, original.height]);
    for (var y = 0; y < original.height; y++) {
      for (var x = 0; x < original.width; x++) {
        final expected = original.getPixel(x, y);
        final actual = restored.getPixel(x, y);
        expect([
          actual.r,
          actual.g,
          actual.b,
          actual.a
        ], [
          expected.r,
          expected.g,
          expected.b,
          expected.a
        ], reason: 'RGBA($x,$y)');
      }
    }
    expect(data['mime'], 'image/webp');
    expect(fixture.a.replica.rejected, isEmpty);
    expect(fixture.b.replica.rejected, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'leaving denies new attachment epoch while already-authorized history remains retrievable',
      () async {
    final fixture = await _MediaFixture.create();
    printOnFailure('leave/history fixture: ${fixture.root.path}');
    var passed = false;
    addTearDown(() => fixture.close(preserve: !passed));
    final upload = await fixture.a.media.upload(
        actorId: fixture.aliceId,
        name: 'history.bin',
        bytes: [0, 1, 2, 3, 255]);
    final old = await fixture.a.execute(operation: 'message.send', params: {
      'conversation': _lobby,
      'parts': [_part('file', upload['file_id'] as String)],
    });
    final oldMessage =
        MessageRecord.fromJson(old['result'] as Map<String, dynamic>);
    await fixture.exchange();
    final oldParts = await fixture.b.media.project(
        actorId: fixture.bobId,
        message: fixture.b.replica.service.message(
            actor: fixture.b.replica.service.actor(fixture.bobId),
            messageId: oldMessage.id));
    final oldHandle = (oldParts.single['data'] as Map)['file_id'] as String;
    final oldRef = _ref(oldMessage.parts.single);
    // Do not fetch old bytes before leaving: availability and history read
    // eligibility must be rechecked on-demand after membership changes too.
    await fixture.b
        .execute(operation: 'space.leave', params: {'space': 'media-lobby'});
    await fixture.exchange();
    final next = await fixture.a.execute(operation: 'message.send', params: {
      'conversation': _lobby,
      'parts': [_part('file', upload['file_id'] as String)],
    });
    final nextMessage =
        MessageRecord.fromJson(next['result'] as Map<String, dynamic>);
    final nextRef = _ref(nextMessage.parts.single);
    expect(nextRef.epoch, greaterThan(oldRef.epoch));
    await fixture.exchange();
    expect(
        fixture.b.replica.keys
            .any((k) => k.conversationId == _lobby && k.epoch == nextRef.epoch),
        isFalse);
    expect(fixture.b.replica.service.state.messages.containsKey(nextMessage.id),
        isFalse);
    final oldData =
        await fixture.b.media.get(actorId: fixture.bobId, fileId: oldHandle);
    expect(base64Decode(oldData['data'] as String), [0, 1, 2, 3, 255]);
    await expectLater(
        fixture.b.media.project(actorId: fixture.bobId, message: nextMessage),
        throwsA(isA<DomainException>()));
    passed = true;
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'forum and private-feed attachments use the same opaque pipeline and private feed denies another account',
      () async {
    final fixture = await _MediaFixture.create();
    addTearDown(fixture.close);
    await fixture.a.execute(operation: 'room.create', params: {
      'space': 'media-lobby',
      'id': 'media-forum',
      'title': 'Media Forum',
      'kind': 'forum',
    });
    await fixture.exchange();
    final bytes = utf8.encode('Forum and private feed attachment contents');
    final upload = await fixture.a.media.upload(
        actorId: fixture.aliceId,
        name: 'forum.txt',
        bytes: bytes,
        mime: 'text/plain');
    final post = await fixture.a.execute(operation: 'forum.post', params: {
      'room': 'media-forum',
      'title': 'Attachment post',
      'parts': [_part('file', upload['file_id'] as String)],
    });
    final messageId = (post['result'] as Map)['messageId'] as String;
    final forumMessage = fixture.a.replica.service.message(
        actor: fixture.a.replica.service.actor(fixture.aliceId),
        messageId: messageId);
    final forumRef = _ref(forumMessage.parts.single);
    expect(forumRef.scope, 'media-forum');
    expect(
        await sha256Hex(
            await fixture.remoteObject(forumRef.descriptor.objectId)),
        forumRef.descriptor.objectId);
    await fixture.exchange();
    final received = fixture.b.replica.service.message(
        actor: fixture.b.replica.service.actor(fixture.bobId),
        messageId: messageId);
    final projected = await fixture.b.media
        .project(actorId: fixture.bobId, message: received);
    expect(
        base64Decode((await fixture.b.media.get(
            actorId: fixture.bobId,
            fileId: (projected.single['data'] as Map)['file_id']
                as String))['data'] as String),
        bytes);
    final feed = await fixture.a.execute(operation: 'feed.post', params: {
      'visibility': 'private',
      'parts': [_part('file', upload['file_id'] as String)],
    });
    final feedId = (feed['result'] as Map)['id'] as String;
    final feedRecord =
        _feedMessage(fixture.a.replica.service.state.feedPosts[feedId]!);
    final feedRef = _ref(feedRecord.parts.single);
    expect(feedRef.scope, 'feed:${fixture.aliceId}:private');
    expect(feedRef.descriptor.objectId, isNot(forumRef.descriptor.objectId));
    final ownerProjection = await fixture.a.media
        .project(actorId: fixture.aliceId, message: feedRecord);
    final ownerHandle =
        (ownerProjection.single['data'] as Map)['file_id'] as String;
    expect(
        base64Decode((await fixture.a.media.get(
            actorId: fixture.aliceId, fileId: ownerHandle))['data'] as String),
        bytes);
    await fixture.exchange();
    expect(
        fixture.b.replica.service.state.feedPosts.containsKey(feedId), isFalse);
    await expectLater(
        fixture.b.media.project(actorId: fixture.bobId, message: feedRecord),
        throwsA(isA<DomainException>()));
    await expectLater(
        fixture.b.media.get(actorId: fixture.bobId, fileId: ownerHandle),
        throwsA(
            isA<DomainException>().having((e) => e.code, 'code', 'forbidden')));
    expect(fixture.a.replica.rejected, isEmpty);
    expect(fixture.b.replica.rejected, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Map<String, dynamic> _part(String type, String fileId) => {
      'type': type,
      'data': {'file_id': fileId}
    };
AttachmentRef _ref(Map<String, dynamic> part) =>
    AttachmentRef.fromJson((part['data'] as Map<String, dynamic>)['attachment']
        as Map<String, dynamic>);
MessageRecord _feedMessage(FeedPostRecord post) => MessageRecord(
    id: post.id,
    conversationId: 'feed:${post.authorId}:${post.visibility}',
    senderId: post.authorId,
    parts: post.parts,
    createdAtMs: post.createdAtMs);

class _MediaFixture {
  final Directory root;
  final Directory remote;
  final LocalProfile alice;
  late LocalProfile bob;
  late GitSync aGit;
  late GitSync bGit;
  late ZaizuoNode a;
  late ZaizuoNode b;
  final nodes = <ZaizuoNode>[];
  final repositories = <GitSync>[];
  String get aliceId => alice.identity.public.accountId;
  String get bobId => bob.identity.public.accountId;
  _MediaFixture(this.root, this.remote, this.alice);

  static Future<_MediaFixture> create() async {
    final root = await Directory.systemTemp.createTemp('zaizuo-media-e2e-');
    final remote = Directory(p.join(root.path, 'remote.git'));
    final init = await Process.run('git', [
      'init',
      '--bare',
      '--template=',
      '--initial-branch=main',
      remote.path
    ]);
    if (init.exitCode != 0) throw StateError('local bare git init failed');
    final aDir = Directory(p.join(root.path, 'alice'));
    await LocalProfile.initialize(aDir,
        name: 'alice',
        displayName: 'Alice',
        password: _password,
        parameters: _fastKdf);
    final alice = await LocalProfile.open(aDir, _password);
    final fixture = _MediaFixture(root, remote, alice);
    final bDir = Directory(p.join(root.path, 'bob'));
    await LocalProfile.initialize(bDir,
        name: 'bob',
        displayName: 'Bob',
        password: _password,
        parameters: _fastKdf,
        community: alice.manifest,
        pinnedFingerprint: await alice.manifest.fingerprint());
    fixture.bob = await LocalProfile.open(bDir, _password);
    fixture.aGit =
        await fixture.repository('a-git', alice.device.certificate!.id);
    fixture.bGit =
        await fixture.repository('b-git', fixture.bob.device.certificate!.id);
    fixture.a = await ZaizuoNode.open(profile: alice, git: fixture.aGit);
    fixture.nodes.add(fixture.a);
    await fixture.a.admit(await fixture.bob.joinRequest());
    fixture.b = await ZaizuoNode.open(profile: fixture.bob, git: fixture.bGit);
    fixture.nodes.add(fixture.b);
    await fixture.exchange();
    await fixture.a.execute(operation: 'space.create', params: {
      'id': 'media-lobby',
      'title': 'Media Lobby',
      'public_channel': true,
    });
    await fixture.exchange();
    await fixture.b
        .execute(operation: 'space.join', params: {'space': 'media-lobby'});
    await fixture.exchange();
    expect(fixture.a.replica.rejected, isEmpty);
    expect(fixture.b.replica.rejected, isEmpty);
    return fixture;
  }

  ConversationKey key(ZaizuoNode node, String scope, int epoch) =>
      node.replica.keys
          .singleWhere((k) => k.conversationId == scope && k.epoch == epoch);

  Future<GitSync> repository(String name, String deviceId) async {
    final git = await GitSync.initialize(
        worktree: Directory(p.join(root.path, name)),
        remoteUrl: remote.path,
        deviceId: deviceId);
    repositories.add(git);
    return git;
  }

  Future<void> exchange() async {
    await a.syncOnce();
    await b.syncOnce();
    await a.syncOnce();
    await b.syncOnce();
  }

  Future<Uint8List> remoteObject(String objectId) async {
    final result = await Process.run(
        'git',
        [
          '--git-dir=${remote.path}',
          'show',
          'refs/heads/attachment/$objectId:object.bin'
        ],
        runInShell: false,
        stdoutEncoding: null);
    expect(result.exitCode, 0,
        reason: 'attachment ref must exist before event publication');
    return Uint8List.fromList(result.stdout as List<int>);
  }

  Future<void> reopenBob() async {
    await b.close();
    bob = await LocalProfile.open(bob.root, _password);
    b = await ZaizuoNode.open(profile: bob, git: bGit);
    nodes.add(b);
  }

  Future<void> close({bool preserve = false}) async {
    for (final node in nodes) {
      await node.close();
    }
    for (final git in repositories) {
      await git.close();
    }
    if (preserve) return;
    final absolute = p.normalize(p.absolute(root.path));
    if (p.isWithin(
            p.normalize(p.absolute(Directory.systemTemp.path)), absolute) &&
        p.basename(absolute).startsWith('zaizuo-media-e2e-')) {
      await root.delete(recursive: true);
    } else {
      throw StateError('unexpected media test cleanup path');
    }
  }
}
