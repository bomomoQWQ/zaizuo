@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

import 'support/native_factory.dart';
import 'support/native_fixture.dart';

Matcher failure(String code) => throwsA(
  isA<GitSyncException>().having((error) => error.code, 'code', code),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CLI and native nodes: signed admission, bidirectional file/RGBA, lazy get and reopen', () async {
    final f = await NativeFixture.create(nativeBackend, profiles: true);
    addTearDown(f.dispose);
    expect(f.b.profile.manifest.revision, 2);
    expect(
      await Directory('${f.native.worktree.path}/logs').exists(),
      isFalse,
      reason: 'remote device trees are read as objects, never checked out',
    );
    expect(
      f.b.store.trust.devices.keys,
      contains(f.alice.device.certificate!.id),
    );
    expect(
      f.a.store.trust.devices.keys,
      contains(f.bob.device.certificate!.id),
    );
    final rgba = image.Image(width: 4, height: 3, numChannels: 4);
    for (var y = 0; y < 3; y++) {
      for (var x = 0; x < 4; x++) {
        rgba.setPixelRgba(
          x,
          y,
          20 + x * 40,
          30 + y * 60,
          200 - x * 20,
          [0, 64, 127, 255][x],
        );
      }
    }
    String? nativeHandle;
    List<int>? nativePlain;
    for (final direction in [true, false]) {
      final sender = direction ? f.a : f.b;
      final receiver = direction ? f.b : f.a;
      final receivingGit = direction ? f.native : f.cli;
      final senderId = sender.profile.identity.public.accountId;
      final receiverId = receiver.profile.identity.public.accountId;
      for (final kind in ['file', 'image']) {
        final plain = kind == 'file'
            ? List<int>.generate(1024, (i) => (i * 7) % 256)
            : image.encodePng(rgba);
        final uploaded = await sender.media.upload(
          actorId: senderId,
          name: '$kind.${kind == 'image' ? 'png' : 'bin'}',
          bytes: plain,
          purpose: kind,
        );
        final result = await sender.execute(
          operation: 'message.send',
          params: {
            'conversation': fixtureLobby,
            'parts': [
              {
                'type': kind,
                'data': {'file_id': uploaded['file_id']},
              },
            ],
          },
        );
        final message = MessageRecord.fromJson(
          result['result'] as Map<String, dynamic>,
        );
        final reference = AttachmentRef.fromJson(
          (message.parts.single['data'] as Map)['attachment']
              as Map<String, dynamic>,
        );
        final id = reference.descriptor.objectId;
        final cipher = await f.remoteObject(id);
        expect(await sha256Hex(cipher), id);
        expect(cipher, isNot(plain));
        final main = await f.head('refs/heads/main');
        await f.exchange();
        final pinFile = f.metadata(receivingGit, 'attachment_pins.json');
        final before = await pinFile.exists()
            ? jsonObject(await pinFile.readAsString())['objects'] as Map
            : <String, dynamic>{};
        expect(
          before.containsKey(id),
          isFalse,
          reason: 'sync imports descriptors only; no attachment ref eagerly fetched',
        );
        final received = receiver.replica.service.message(
          actor: receiver.replica.service.actor(receiverId),
          messageId: message.id,
        );
        final deviceHead = await f.head(sender.git!.branchRef);
        final parts = await receiver.media.project(
          actorId: receiverId,
          message: received,
        );
        final handle = (parts.single['data'] as Map)['file_id'] as String;
        final loaded = await receiver.media.get(
          actorId: receiverId,
          fileId: handle,
        );
        final bytes = base64Decode(loaded['data'] as String);
        if (kind == 'file') {
          expect(bytes, plain);
          if (direction) {
            nativeHandle = handle;
            nativePlain = plain;
          }
        } else {
          final decoded = image.decodeWebP(bytes)!;
          expect([decoded.width, decoded.height], [4, 3]);
          for (var y = 0; y < 3; y++) {
            for (var x = 0; x < 4; x++) {
              final actual = decoded.getPixel(x, y);
              final expected = rgba.getPixel(x, y);
              expect(
                [actual.r, actual.g, actual.b, actual.a],
                [expected.r, expected.g, expected.b, expected.a],
                reason: 'RGBA($x,$y)',
              );
            }
          }
        }
        expect(await f.head('refs/heads/main'), main);
        expect(
          await f.head(sender.git!.branchRef),
          deviceHead,
          reason: 'on-demand attachment get cannot mutate the device log',
        );
        expect(
          (jsonObject(await f.attachmentPins(receivingGit))['objects'] as Map)
              .keys,
          contains(id),
        );
      }
    }
    final pins = await f.pins(f.native);
    final attachmentPins = await f.attachmentPins(f.native);
    final count = f.b.store.allEnvelopes.length;
    await f.reopenNative();
    expect(await f.pins(f.native), pins);
    expect(await f.attachmentPins(f.native), attachmentPins);
    expect(
      base64Decode(
        (await f.b.media.get(
              actorId: f.bob.identity.public.accountId,
              fileId: nativeHandle!,
            ))['data']
            as String,
      ),
      nativePlain,
    );
    await f.exchange();
    expect(f.b.store.allEnvelopes.length, count);
    expect(f.b.profile.manifestHistory.map((m) => m.revision), [1, 2]);
    expect(f.a.replica.rejected, isEmpty);
    expect(f.b.replica.rejected, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('deterministic attachment root OID matches CLI oracle; two native repos serialize callbacks', () async {
    final f = await NativeFixture.create(nativeBackend);
    addTearDown(f.dispose);
    final cli = await f.repository('cli', 'a' * 64, nativeBackend: false);
    final first = await f.repository('native-one', 'b' * 64);
    final second = await f.repository('native-two', 'c' * 64);
    final (id, file) = await f.ciphertext(
      List<int>.generate(4096, (i) => i % 251),
    );
    await Future.wait([
      cli.publishAttachment(objectId: id, ciphertext: file),
      first.publishAttachment(objectId: id, ciphertext: file),
      second.publishAttachment(objectId: id, ciphertext: file),
    ]);
    final head = await f.head(f.attachmentRef(id));
    final commit = await f.git([
      '--git-dir=${f.remote.path}',
      'cat-file',
      'commit',
      head,
    ]);
    final tree = (await f.git([
      '--git-dir=${f.remote.path}',
      'rev-parse',
      '$head^{tree}',
    ])).trim();
    final expectedCommit =
        'tree $tree\n'
        'author zaizuo <attachment@zaizuo.invalid> 946684800 +0000\n'
        'committer zaizuo <attachment@zaizuo.invalid> 946684800 +0000\n\n'
        'zaizuo: ciphertext attachment $id\n';
    expect(commit, expectedCommit, reason: 'exact canonical root, no parents');
    final oracleFile = await f.ciphertext(utf8.encode(expectedCommit));
    final oracleOid = (await f.git([
      '--git-dir=${f.remote.path}',
      'hash-object',
      '-t',
      'commit',
      '--no-filters',
      '--',
      oracleFile.$2.path,
    ])).trim();
    expect(head, oracleOid);
    // Independently construct the canonical object through native plumbing even
    // if the CLI won the concurrent push and native publication deduplicated.
    final plumbing = nativeBackend();
    await plumbing.open(
      worktreePath: '${f.root.path}/native-plumbing',
      remoteUrl: f.remote.path,
      create: true,
    );
    try {
      final blob = await plumbing.createBlob(await file.readAsBytes());
      final nativeTree = await plumbing.createTree({'object.bin': blob});
      expect(nativeTree, tree);
      final nativeOid = await plumbing.createCommit(
        tree: nativeTree,
        parents: [],
        message: 'zaizuo: ciphertext attachment $id',
        authorName: 'zaizuo',
        authorEmail: 'attachment@zaizuo.invalid',
        committerName: 'zaizuo',
        committerEmail: 'attachment@zaizuo.invalid',
        authorDate: '946684800 +0000',
        committerDate: '946684800 +0000',
      );
      expect(nativeOid, oracleOid);
    } finally {
      await plumbing.close();
    }
    for (final repo in [cli, first, second]) {
      expect(
        (jsonObject(await f.attachmentPins(repo))['objects'] as Map)[id],
        head,
        reason:
            'each backend independently validated the same exact remote OID',
      );
    }
    expect(
      await Future.wait([
        first.fetchAttachment(id),
        second.fetchAttachment(id),
      ]),
      [await file.readAsBytes(), await file.readAsBytes()],
    );
    expect(
      (await f.git(['--git-dir=${f.remote.path}', 'rev-list', '--count', head]))
          .trim(),
      '1',
    );
  });

  test('native refuses attachment wrong hash and executable/symlink/extra/gitlink trees without pins', () async {
    final f = await NativeFixture.create(nativeBackend);
    addTearDown(f.dispose);
    final repo = await f.repository('native', 'a' * 64);
    final bytes = [5, 4, 3, 2, 1];
    final id = await sha256Hex(bytes);
    await f.publishRaw(f.attachmentRef(id), {
      'object.bin': [9, 9, 9],
    });
    await expectLater(repo.fetchAttachment(id), failure('attachment_hash'));
    for (final mode in ['100755', '120000']) {
      await f.publishRaw(f.attachmentRef(id), {
        'object.bin': bytes,
      }, mode: mode);
      await expectLater(
        repo.fetchAttachment(id),
        failure('attachment_collision'),
      );
    }
    final parent = await f.publishRaw(f.attachmentRef(id), {
      'object.bin': bytes,
      '.gitattributes': utf8.encode('* filter=unsafe\n'),
    });
    await expectLater(
      repo.fetchAttachment(id),
      failure('attachment_collision'),
    );
    await f.publishRaw(f.attachmentRef(id), {
      'object.bin': bytes,
    }, gitlink: parent);
    await expectLater(
      repo.fetchAttachment(id),
      failure('attachment_collision'),
    );
    expect(jsonObject(await f.attachmentPins(repo))['objects'], isEmpty);
  });

  test('native persists device pins and refuses rollback, deletion and descendant rewriting old events', () async {
    final f = await NativeFixture.create(nativeBackend, profiles: true);
    addTearDown(f.dispose);
    final ref = f.cli.branchRef;
    final old = await f.head(ref);
    await f.a.execute(
      operation: 'bot.register',
      params: {'id': 'pin-bot', 'display_name': 'Pin Bot'},
    );
    await f.exchange();
    final latest = await f.head(ref);
    final pins = await f.pins(f.native);
    final ids = f.b.store.allEnvelopes.map((e) => e.id).toList();
    await f.reopenNative();
    await f.git(['--git-dir=${f.remote.path}', 'update-ref', ref, old]);
    await expectLater(f.native.pull(f.b.store), failure('remote_rewrite'));
    expect(await f.pins(f.native), pins);
    await f.git(['--git-dir=${f.remote.path}', 'update-ref', '-d', ref]);
    await expectLater(f.native.pull(f.b.store), failure('remote_deleted'));
    expect(await f.pins(f.native), pins);
    await f.git(['--git-dir=${f.remote.path}', 'update-ref', ref, latest]);
    final first = f.a.store.allEnvelopes.firstWhere(
      (e) => e.origin == f.alice.device.certificate!.id,
    );
    final key = f.a.replica.keys.singleWhere(
      (k) => k.conversationId == first.conversation && k.epoch == first.epoch,
    );
    final rewritten = await EncryptedEvent.create(
      communityId: f.alice.manifest.communityId,
      device: f.alice.device,
      key: key,
      sequence: 1,
      clock: first.clock,
      previous: null,
      body: {'message': 'validly signed replacement history'},
    );
    await f.publishRaw(ref, {
      'logs/${first.origin}/00000000.jsonl': utf8.encode(
        '${canonicalJson(rewritten.toJson())}\n',
      ),
    }, parent: latest);
    await expectLater(f.native.pull(f.b.store), failure('archive_rewrite'));
    expect(await f.pins(f.native), pins);
    expect(f.b.store.allEnvelopes.map((e) => e.id), ids);
  });

  test('native rejects first-seen invalid event signature before import/pin advance', () async {
    final f = await NativeFixture.create(nativeBackend, profiles: true);
    addTearDown(f.dispose);
    final newRepo = await f.repository(
      'fresh-native-reader',
      f.bob.device.certificate!.id,
    );
    final freshStore = await FileEventStore.open(
      Directory('${f.root.path}/fresh-events'),
      f.bob.trust,
    );
    addTearDown(freshStore.close);
    final event = f.a.store.allEnvelopes.first;
    final bad = event.toJson()
      ..['signature'] = base64Encode(List<int>.filled(64, 0));
    await f.publishRaw('refs/heads/dev/${event.origin}', {
      'logs/${event.origin}/00000000.jsonl': utf8.encode(
        '${canonicalJson(bad)}\n',
      ),
    });
    final before = await f.pins(newRepo);
    await expectLater(newRepo.pull(freshStore), throwsStateError);
    expect(freshStore.allEnvelopes, isEmpty);
    expect(await f.pins(newRepo), before);
  });
}
