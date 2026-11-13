import 'dart:async';
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
        .put([1, 2, 3, 4], key, name: '图片.webp', mime: 'image/webp');
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
        attachments.put([], key, name: 'x', mime: 'application/octet-stream'),
        throwsArgumentError);
    await expectLater(
        attachments.put(List<int>.filled(1025, 1), key,
            name: 'x', mime: 'application/octet-stream'),
        throwsArgumentError);
    await expectLater(
        attachments.put([7], key,
            name: '../../not-a-path', mime: 'application/octet-stream'),
        throwsFormatException);
    final descriptor = await attachments
        .put([7], key, name: '文档.bin', mime: 'application/octet-stream');
    expect(await attachments.get(descriptor, key), [7]);
    final pathAttack = descriptor.toJson()..['object_id'] = '../../other';
    expect(
        () => AttachmentDescriptor.fromJson(pathAttack), throwsFormatException);
    final smallerLoader = EncryptedAttachments(root, maxBytes: 1);
    final large = await attachments
        .put([1, 2], key, name: 'x', mime: 'application/octet-stream');
    await expectLater(smallerLoader.get(large, key), throwsStateError);
  });

  test('严格descriptor字段/类型/nonce/tag/hash/name/mime验证', () async {
    final key = ConversationKey.generate('strict', 1);
    final descriptor = await attachments
        .put([1], key, name: '你好.bin', mime: 'application/octet-stream');
    final mutations = <Map<String, dynamic>>[
      {...descriptor.toJson(), 'object_id': 'A' * 64},
      {...descriptor.toJson(), 'object_id': '../bad'},
      {...descriptor.toJson(), 'plain_hash': 'g' * 64},
      {...descriptor.toJson(), 'size': 0},
      {...descriptor.toJson(), 'size': 20 * 1024 * 1024 + 1},
      {...descriptor.toJson(), 'size': 1.0},
      {...descriptor.toJson(), 'nonce': base64Encode(List.filled(11, 0))},
      {...descriptor.toJson(), 'nonce': '${descriptor.nonce}\n'},
      {...descriptor.toJson(), 'tag': descriptor.tag.replaceAll('=', '')},
      {...descriptor.toJson(), 'tag': base64Encode(List.filled(15, 0))},
      {...descriptor.toJson(), 'name': '../secret'},
      {...descriptor.toJson(), 'name': r'a\b'},
      {...descriptor.toJson(), 'name': '.'},
      {...descriptor.toJson(), 'name': 'a\u0000b'},
      {...descriptor.toJson(), 'name': ' a.bin'},
      {...descriptor.toJson(), 'mime': 'image/webp\r\nX:x'},
      {...descriptor.toJson(), 'mime': 'image'},
      {...descriptor.toJson(), 'mime': 'image/webp; x=1'},
      {...descriptor.toJson(), 'extra': true},
      {...descriptor.toJson()}..remove('tag'),
    ];
    for (final json in mutations) {
      expect(() => AttachmentDescriptor.fromJson(json), throwsFormatException);
    }
    expect(
        () => AttachmentDescriptor(
            objectId: '../bad',
            name: 'x',
            mime: 'image/webp',
            size: 1,
            plainHash: descriptor.plainHash,
            nonce: descriptor.nonce,
            tag: descriptor.tag),
        throwsFormatException);
  });

  test('两端密文export/import无密钥不解密，原子导入后只有正确scope+epoch可get', () async {
    final remote = EncryptedAttachments(Directory('${root.path}/receiver'),
        maxBytes: 1024);
    final key = ConversationKey.generate('chat-a', 4);
    final clear = utf8.encode('private file transfer');
    final descriptor =
        await attachments.put(clear, key, name: '文件.txt', mime: 'text/plain');
    final ciphertext = await attachments.exportCiphertext(descriptor);
    expect(ciphertext.length, clear.length);
    expect(ciphertext, isNot(clear));
    expect(await sha256Hex(ciphertext), descriptor.objectId);
    await remote.importCiphertext(descriptor, ciphertext);
    await remote.importCiphertext(descriptor, ciphertext); // idempotent
    expect(await remote.exportCiphertext(descriptor), ciphertext);
    expect(await remote.get(descriptor, key), clear);
    await expectLater(
        remote.get(
            descriptor,
            ConversationKey(
                conversationId: 'chat-b', epoch: 4, bytes: key.bytes)),
        throwsA(anything));
    await expectLater(
        remote.get(
            descriptor,
            ConversationKey(
                conversationId: 'chat-a', epoch: 5, bytes: key.bytes)),
        throwsA(anything));
    final files = await remote.root.list(recursive: true).toList();
    expect(files.whereType<File>().length, 1);
    expect(files.whereType<File>().single.path,
        endsWith('${descriptor.objectId}.bin'));
    expect(files.whereType<Directory>(), isEmpty); // no staging paths remain
  });

  test('put和import在异步hash前snapshot调用方bytes', () async {
    final key = ConversationKey.generate('snapshot', 1);
    final bytes = <int>[1, 2, 3, 4];
    final putting = attachments.put(bytes, key,
        name: 'x.bin', mime: 'application/octet-stream');
    bytes.fillRange(0, bytes.length, 99);
    final descriptor = await putting;
    expect(await attachments.get(descriptor, key), [1, 2, 3, 4]);
    final remote =
        EncryptedAttachments(Directory('${root.path}/remote'), maxBytes: 1024);
    final ciphertext =
        List<int>.from(await attachments.exportCiphertext(descriptor));
    final importing = remote.importCiphertext(descriptor, ciphertext);
    ciphertext.fillRange(0, ciphertext.length, 0);
    await importing;
    expect(await remote.get(descriptor, key), [1, 2, 3, 4]);
  });

  test('密文错误大小/hash/字节及本机上限导入先拒绝，不留半对象', () async {
    final key = ConversationKey.generate('bounds', 1);
    final descriptor = await attachments.put([1, 2, 3, 4], key,
        name: 'x.bin', mime: 'application/octet-stream');
    final ciphertext = await attachments.exportCiphertext(descriptor);
    final remote =
        EncryptedAttachments(Directory('${root.path}/remote'), maxBytes: 1024);
    for (final data in [
      ciphertext.sublist(1),
      [...ciphertext]..[0] ^= 1
    ]) {
      await expectLater(
          remote.importCiphertext(descriptor, data), throwsStateError);
    }
    await expectLater(remote.importCiphertext(descriptor, [0, 0, 0, 256]),
        throwsArgumentError);
    final smaller =
        EncryptedAttachments(Directory('${root.path}/small'), maxBytes: 3);
    await expectLater(
        smaller.importCiphertext(descriptor, ciphertext), throwsStateError);
    expect(await remote.root.exists(), isFalse);
    await remote.importCiphertext(descriptor, ciphertext);
    final target = File('${remote.root.path}/${descriptor.objectId}.bin');
    await target.writeAsBytes([1, 2, 3, 4]);
    await expectLater(
        remote.importCiphertext(descriptor, ciphertext), throwsStateError);
    expect(await target.readAsBytes(),
        [1, 2, 3, 4]); // never overwrite corrupted object
    await target.writeAsBytes(List.filled(1025, 1));
    await expectLater(remote.exportCiphertext(descriptor), throwsStateError);
  });

  test('并发相同hash导入只发布完整对象且清理stage', () async {
    final key = ConversationKey.generate('atomic', 1);
    final descriptor = await attachments.put(
        List.generate(512, (i) => i % 256), key,
        name: 'x.bin', mime: 'application/octet-stream');
    final ciphertext = await attachments.exportCiphertext(descriptor);
    final remote =
        EncryptedAttachments(Directory('${root.path}/remote'), maxBytes: 1024);
    await Future.wait(List.generate(
        8, (_) => remote.importCiphertext(descriptor, ciphertext)));
    expect(
        await remote.get(descriptor, key), List.generate(512, (i) => i % 256));
    expect(await remote.root.list().length, 1);
  });

  test('附件IO总期限为正，极短deadline明确失败不无限等待', () async {
    expect(() => EncryptedAttachments(root, ioTimeout: Duration.zero),
        throwsArgumentError);
    final key = ConversationKey.generate('timeout', 1);
    final tiny = EncryptedAttachments(Directory('${root.path}/tiny'),
        ioTimeout: const Duration(microseconds: 1));
    await expectLater(
            tiny.put([1], key, name: 'x.bin', mime: 'application/octet-stream'),
            throwsA(isA<TimeoutException>()))
        .timeout(const Duration(seconds: 3));
  });
}
