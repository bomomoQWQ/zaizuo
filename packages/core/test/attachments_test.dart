import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';

void main() {
  late Directory root;
  late EncryptedAttachments attachments;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('zaizuo-attachments-');
    attachments = EncryptedAttachments(root, maxBytes: 1024);
  });
  tearDown(() => root.delete(recursive: true));

  test('只存密文摘要，跨会话/epoch不能解且同明文非全局去重', () async {
    final clear = utf8.encode('opaque compressed bytes, not a WebP codec test');
    final firstKey = ConversationKey.generate('private-a', 1);
    final other = ConversationKey.generate('private-b', 1);
    final first = await attachments.put(clear, firstKey,
        name: 'a.webp', mime: 'image/webp');
    final repeated = await attachments.put(clear, firstKey,
        name: 'a.webp', mime: 'image/webp');
    final otherDescriptor =
        await attachments.put(clear, other, name: 'a.webp', mime: 'image/webp');
    expect(first.objectId, isNot(repeated.objectId));
    expect(first.objectId, isNot(otherDescriptor.objectId));
    expect(first.objectId, isNot(first.plainHash));
    final stored =
        File('${root.path}${Platform.pathSeparator}${first.objectId}.bin');
    expect(await sha256Hex(await stored.readAsBytes()), first.objectId);
    expect(await stored.readAsBytes(), isNot(clear));
    expect(await attachments.get(first, firstKey), clear);
    await expectLater(attachments.get(first, other), throwsA(anything));
    final wrongContext = ConversationKey(
        conversationId: 'private-b', epoch: 1, bytes: firstKey.bytes);
    final wrongEpoch = ConversationKey(
        conversationId: 'private-a', epoch: 2, bytes: firstKey.bytes);
    await expectLater(attachments.get(first, wrongContext), throwsA(anything));
    await expectLater(attachments.get(first, wrongEpoch), throwsA(anything));
  });

  test('密文损坏、描述tag/nonce/hash/size被改均不能成功返回', () async {
    final key = ConversationKey.generate('private-a', 1);
    final descriptor = await attachments
        .put([1, 2, 3, 4], key, name: 'a.webp', mime: 'image/webp');
    for (final field in ['tag', 'nonce', 'plain_hash', 'size']) {
      final changed = descriptor.toJson();
      changed[field] = switch (field) {
        'tag' => base64Encode(List<int>.filled(16, 0)),
        'nonce' => base64Encode(List<int>.filled(12, 0)),
        'plain_hash' => '0' * 64,
        _ => 3,
      };
      await expectLater(
          attachments.get(AttachmentDescriptor.fromJson(changed), key),
          throwsA(anything));
    }
    final file =
        File('${root.path}${Platform.pathSeparator}${descriptor.objectId}.bin');
    final corrupted = await file.readAsBytes();
    corrupted[0] ^= 1;
    await file.writeAsBytes(corrupted, flush: true);
    await expectLater(attachments.get(descriptor, key), throwsStateError);
  });

  test('限制大小并拒绝路径对象编号，不从name读写任意路径', () async {
    final key = ConversationKey.generate('private-a', 1);
    await expectLater(
        attachments.put([], key, name: 'x', mime: 'x'), throwsArgumentError);
    await expectLater(
        attachments.put(List<int>.filled(1025, 1), key, name: 'x', mime: 'x'),
        throwsArgumentError);
    final descriptor = await attachments.put([7], key,
        name: '../../not-a-path', mime: 'application/octet-stream');
    expect(await attachments.get(descriptor, key), [7]);
    final pathAttack = descriptor.toJson()..['object_id'] = '../../other';
    await expectLater(
        attachments.get(AttachmentDescriptor.fromJson(pathAttack), key),
        throwsFormatException);
    final smallerLoader = EncryptedAttachments(root, maxBytes: 1);
    final large = await attachments.put([1, 2], key, name: 'x', mime: 'x');
    await expectLater(smallerLoader.get(large, key), throwsStateError);
  });
}
