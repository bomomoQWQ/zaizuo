import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

const password = 'CrossHost!Only7_Test2026';
const room = 'cross-host#main';
const fast = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
void check(bool valid, String message) {
  if (!valid) throw StateError(message);
}

List<int> originalFile() => utf8.encode(
    '在座真实跨电脑附件测试\n${List.generate(4096, (i) => (i % 251).toRadixString(16)).join(',')}\n');
img.Image originalImage() {
  final image = img.Image(width: 48, height: 32, numChannels: 4);
  for (var y = 0; y < 32; y++)
    for (var x = 0; x < 48; x++)
      image.setPixelRgba(x, y, (x * 5) % 256, (y * 7) % 256, (x + y) * 3 % 256,
          (x + y) % 3 == 0 ? 0 : 255);
  return image;
}

Future<void> main(List<String> args) async {
  if (args.length < 3)
    throw ArgumentError(
        'peer <stage> <privateRoot> <remote> [public exchange file]');
  final stage = args[0],
      root = Directory(p.absolute(args[1])),
      remote = args[2];
  if (stage == 'prepare-a') {
    await LocalProfile.initialize(root,
        name: 'alice',
        displayName: 'Alice跨机测试',
        password: password,
        parameters: fast);
  } else if (stage == 'prepare-b') {
    final exchange = jsonObject(await File(args[3]).readAsString());
    final manifest = CommunityManifest.fromJson(
        exchange['manifest'] as Map<String, dynamic>);
    await LocalProfile.initialize(root,
        name: 'bob',
        displayName: 'Bob跨机测试',
        password: password,
        parameters: fast,
        community: manifest,
        pinnedFingerprint: exchange['fingerprint'] as String);
  }
  final profile = await LocalProfile.open(root, password);
  if (stage == 'prepare-b') {
    final output = File(p.join(root.path, 'join-request.json'));
    await output.writeAsString(canonicalJson(await profile.joinRequest()),
        flush: true);
    stdout.writeln(jsonEncode(
        {'stage': stage, 'ok': true, 'public_request': output.path}));
    return;
  }
  final git = await GitSync.initialize(
      worktree: Directory('${root.path}-git'),
      remoteUrl: remote,
      deviceId: profile.device.certificate!.id);
  final node = await ZaizuoNode.open(profile: profile, git: git);
  try {
    switch (stage) {
      case 'prepare-a':
        await node.execute(operation: 'space.create', params: {
          'id': 'cross-host',
          'title': '跨电脑测试频道',
          'public_channel': true
        });
        await node.syncOnce();
        final file = File(p.join(root.path, 'public-community.json'));
        await file.writeAsString(
            canonicalJson({
              'manifest': profile.manifest.toJson(),
              'fingerprint': await profile.manifest.fingerprint()
            }),
            flush: true);
      case 'admit-a':
        await node.syncOnce();
        await node.admit(jsonObject(await File(args[3]).readAsString()));
        await node.syncOnce();
      case 'join-b':
        await node.syncOnce();
        await node
            .execute(operation: 'space.join', params: {'space': 'cross-host'});
        await node.syncOnce();
      case 'send-a':
        await node.syncOnce();
        final file = await node.media.upload(
            actorId: profile.identity.public.accountId,
            name: '跨机文件.bin',
            bytes: originalFile(),
            mime: 'application/octet-stream');
        final image = await node.media.upload(
            actorId: profile.identity.public.accountId,
            name: '透明测试.png',
            bytes: img.encodePng(originalImage()),
            purpose: 'image');
        final sent = await node.execute(operation: 'message.send', params: {
          'conversation': room,
          'parts': [
            {
              'type': 'text',
              'data': {'text': 'Windows→Ubuntu'}
            },
            {
              'type': 'file',
              'data': {'file_id': file['file_id']}
            },
            {
              'type': 'image',
              'data': {'file_id': image['file_id']}
            }
          ]
        });
        await node.syncOnce();
        stdout.writeln(jsonEncode({
          'stage': stage,
          'ok': true,
          'message': (sent['result'] as Map)['id'],
          'file_hash': await sha256Hex(originalFile())
        }));
        return;
      case 'receive-b':
        await node.syncOnce();
        final actor =
            node.replica.service.actor(profile.identity.public.accountId);
        final message = node.replica.service
            .messages(actor: actor, conversationId: room)
            .firstWhere((m) => m.parts.any((q) => q['type'] == 'image'));
        final projected =
            await node.media.project(actorId: actor.id, message: message);
        final plainFile = await node.media.get(
            actorId: actor.id,
            fileId: projected.firstWhere((q) => q['type'] == 'file')['data']
                ['file_id'] as String);
        check(
            await sha256Hex(base64Decode(plainFile['data'] as String)) ==
                await sha256Hex(originalFile()),
            '跨机文件不一致');
        final imageResult = await node.media.get(
            actorId: actor.id,
            fileId: projected.firstWhere((q) => q['type'] == 'image')['data']
                ['file_id'] as String);
        final image =
            img.decodeWebP(base64Decode(imageResult['data'] as String));
        check(image != null, 'WebP解码失败');
        final source = originalImage();
        check(image!.width == source.width && image.height == source.height,
            '图片尺寸不符');
        for (var y = 0; y < source.height; y++)
          for (var x = 0; x < source.width; x++) {
            final a = source.getPixel(x, y), b = image.getPixel(x, y);
            check(a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a,
                'RGBA像素不一致');
          }
        final own = await node.media.upload(
            actorId: actor.id, name: 'ubuntu-reply.bin', bytes: originalFile());
        await node.execute(operation: 'message.send', params: {
          'conversation': room,
          'parts': [
            {
              'type': 'text',
              'data': {'text': 'Ubuntu→Windows'}
            },
            {
              'type': 'file',
              'data': {'file_id': own['file_id']}
            }
          ]
        });
        await node.syncOnce();
        check(node.replica.rejected.isEmpty, '接收存在被拒命令');
        stdout.writeln(jsonEncode({
          'stage': stage,
          'ok': true,
          'actual_file_bytes': plainFile['size'],
          'image': '48x32 rgba lossless',
          'attachment_fetch': 'on-demand Git',
          'rejected': 0
        }));
        return;
      case 'verify-a':
        await node.syncOnce();
        final actor =
            node.replica.service.actor(profile.identity.public.accountId);
        final message = node.replica.service
            .messages(actor: actor, conversationId: room)
            .firstWhere((m) => m.parts.any((q) =>
                q['type'] == 'text' && q['data']['text'] == 'Ubuntu→Windows'));
        final projected =
            await node.media.project(actorId: actor.id, message: message);
        final downloaded = await node.media.get(
            actorId: actor.id,
            fileId: projected.firstWhere((q) => q['type'] == 'file')['data']
                ['file_id'] as String);
        check(
            await sha256Hex(base64Decode(downloaded['data'] as String)) ==
                await sha256Hex(originalFile()),
            'Ubuntu回件不一致');
        check(node.replica.rejected.isEmpty, 'Windows存在被拒命令');
        stdout.writeln(jsonEncode({
          'stage': stage,
          'ok': true,
          'download_hash':
              await sha256Hex(base64Decode(downloaded['data'] as String)),
          'rejected': 0
        }));
        return;
      default:
        throw ArgumentError('未知阶段');
    }
    stdout.writeln(jsonEncode({
      'stage': stage,
      'ok': true,
      'events': node.store.allEnvelopes.length,
      'revision': profile.manifest.revision,
      'rejected': node.replica.rejected.length
    }));
  } finally {
    await node.close();
    await git.close();
  }
}
