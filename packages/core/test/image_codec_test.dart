import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';

img.Image _rgba() {
  final image = img.Image(width: 3, height: 2, numChannels: 4);
  image.setPixelRgba(
      0, 0, 17, 34, 51, 0); // invisible RGB must survive exact=true
  image.setPixelRgba(1, 0, 250, 128, 7, 128);
  image.setPixelRgba(2, 0, 255, 255, 255, 255);
  image.setPixelRgba(0, 1, 0, 0, 0, 255);
  image.setPixelRgba(1, 1, 25, 80, 160, 1);
  image.setPixelRgba(2, 1, 101, 202, 33, 254);
  return image;
}

void _samePixels(img.Image actual, img.Image expected) {
  expect(actual.width, expected.width);
  expect(actual.height, expected.height);
  for (var y = 0; y < expected.height; y++) {
    for (var x = 0; x < expected.width; x++) {
      final a = actual.getPixel(x, y), e = expected.getPixel(x, y);
      expect([a.r, a.g, a.b, a.a], [e.r, e.g, e.b, e.a], reason: 'RGBA $x,$y');
    }
  }
}

void _u32be(List<int> bytes, int offset, int value) {
  for (var i = 0; i < 4; i++) {
    bytes[offset + i] = value >> (24 - 8 * i) & 255;
  }
}

void main() {
  test('PNG/JPEG/losslessWebP/lossyWebP真实头尺寸，非扩展名推测', () {
    final image = _rgba();
    final fixtures = [
      (img.encodePng(image), 'png'),
      (img.encodeJpg(image), 'jpeg'),
      (img.encodeWebP(image, lossless: true), 'webp'),
      (img.encodeWebP(image, lossless: false), 'webp'),
    ];
    for (final (bytes, format) in fixtures) {
      final dimensions = readImageDimensions(bytes);
      expect(dimensions.format, format);
      expect(
          (dimensions.width, dimensions.height, dimensions.pixels), (3, 2, 6));
    }
  });

  test('纯Dart默认lossless PNG->WebP逐点RGBA一致，包括透明下RGB', () async {
    final source = _rgba();
    final png = img.encodePng(source);
    final encoded = await PreferredImageEncoder().encodeBytes(png);
    final dimensions = readImageDimensions(encoded);
    expect(dimensions.format, 'webp');
    final decoded = img.decodeWebP(Uint8List.fromList(encoded));
    expect(decoded, isNotNull);
    _samePixels(decoded!, source);
  });

  test('lossless重编码真实JPEG与WebP，按解码后像素比较', () async {
    final source = _rgba();
    for (final bytes in [img.encodeJpg(source), img.encodeWebP(source)]) {
      final original = img.decodeImage(bytes)!;
      final encoded = await PreferredImageEncoder().encodeBytes(bytes);
      _samePixels(img.decodeWebP(Uint8List.fromList(encoded))!, original);
    }
  });

  test('JPEG EXIF方向按SDK应用且输出尺寸与旋正像素一致', () async {
    final source = _rgba();
    source.exif.imageIfd.orientation = 6;
    final jpeg = img.encodeJpg(source);
    final decoded = img.decodeJpg(jpeg)!;
    expect((decoded.width, decoded.height), (2, 3));
    final encoded = await PreferredImageEncoder().encodeBytes(jpeg);
    _samePixels(img.decodeWebP(Uint8List.fromList(encoded))!, decoded);
    expect((
      readImageDimensions(encoded).width,
      readImageDimensions(encoded).height
    ), (
      2,
      3
    ));
  });

  test('编码输出去除EXIF/ICC/文本等源metadata，保留像素', () async {
    final source = _rgba();
    source.addTextData({'Author': 'private-native-metadata'});
    source.exif.imageIfd.make = 'private-camera';
    final inputs = [img.encodePng(source), img.encodeWebP(source)];
    expect(img.decodePng(inputs[0])!.textData, contains('Author'));
    expect(img.decodeWebP(inputs[1])!.exif.isEmpty, isFalse);
    for (final bytes in inputs) {
      final encoded = await PreferredImageEncoder().encodeBytes(bytes);
      final decoded = img.decodeWebP(Uint8List.fromList(encoded))!;
      _samePixels(decoded, _rgba());
      expect(decoded.exif.isEmpty, isTrue);
      expect(decoded.iccProfile, isNull);
      expect(decoded.textData == null || decoded.textData!.isEmpty, isTrue);
      expect(String.fromCharCodes(encoded), isNot(contains('private-')));
    }
  });

  test('encode(File)真实PNG与encodeBytes同协议输出，不依赖本机exe', () async {
    final root = await Directory.systemTemp.createTemp('zaizuo-image-test-');
    try {
      final file = await File(p.join(root.path, 'not-really-a-jpeg.jpg'))
          .writeAsBytes(img.encodePng(_rgba()));
      final output = await PreferredImageEncoder().encode(file);
      _samePixels(img.decodeWebP(Uint8List.fromList(output))!, _rgba());
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('bytes入口首个await前快照，调用方改原buffer不改变任务', () async {
    final png = img.encodePng(_rgba());
    final operation = PreferredImageEncoder().encodeBytes(png);
    png.fillRange(0, png.length, 0);
    final encoded = await operation;
    _samePixels(img.decodeWebP(Uint8List.fromList(encoded))!, _rgba());
  });

  test('pixel/dimension/input/output限额及无效配置', () async {
    final png = img.encodePng(_rgba());
    expect(() => PreferredImageEncoder(maxPixels: 0), throwsArgumentError);
    expect(
        () => PreferredImageEncoder(maxDimension: 16384), throwsArgumentError);
    expect(() => PreferredImageEncoder(timeout: Duration.zero),
        throwsArgumentError);
    await expectLater(PreferredImageEncoder(maxPixels: 5).encodeBytes(png),
        throwsFormatException);
    await expectLater(PreferredImageEncoder(maxDimension: 2).encodeBytes(png),
        throwsFormatException);
    await expectLater(
        PreferredImageEncoder(maxInputBytes: png.length - 1).encodeBytes(png),
        throwsArgumentError);
    await expectLater(PreferredImageEncoder(maxOutputBytes: 1).encodeBytes(png),
        throwsStateError);
    await expectLater(
        PreferredImageEncoder().encodeBytes([0, 256]), throwsArgumentError);
    await expectLater(
        PreferredImageEncoder().encodeBytes([]), throwsArgumentError);
  });

  test('压缩小文件声明巨大尺寸在像素decode前拒绝', () async {
    final png = img.encodePng(_rgba());
    _u32be(png, 16, 0x7fffffff);
    _u32be(png, 20, 0x7fffffff);
    expect(() => readImageDimensions(png), throwsFormatException);
    await expectLater(
        PreferredImageEncoder().encodeBytes(png), throwsFormatException);
  });

  test('截断/损坏/未知格式拒绝，不因有合法尺寸就成功', () async {
    final png = img.encodePng(_rgba());
    final damaged = Uint8List.fromList(png)..[29] ^= 1; // IHDR CRC
    final truncated = png.sublist(0, png.length - 1);
    for (final bytes in [
      damaged,
      truncated,
      [1, 2, 3, 4],
      img.encodeGif(_rgba())
    ]) {
      await expectLater(
          PreferredImageEncoder().encodeBytes(bytes), throwsFormatException);
    }
    final jpg = img.encodeJpg(_rgba());
    expect(() => readImageDimensions(jpg.sublist(0, jpg.length - 2)),
        throwsFormatException);
    final webp = img.encodeWebP(_rgba());
    expect(() => readImageDimensions(webp.sublist(0, webp.length - 1)),
        throwsFormatException);
  });

  test('真实APNG/WebP动画在解码像素前拒绝，不默默截首帧', () async {
    final animation = _rgba();
    animation.addFrame(_rgba());
    for (final bytes in [img.encodePng(animation), img.encodeWebP(animation)]) {
      expect(() => readImageDimensions(bytes), throwsFormatException);
      await expectLater(
          PreferredImageEncoder().encodeBytes(bytes), throwsFormatException);
    }
  });

  test('头解析截断与极端分块长度只返回FormatException不越界', () {
    final fixtures = [
      img.encodePng(_rgba()),
      img.encodeJpg(_rgba()),
      img.encodeWebP(_rgba())
    ];
    for (final bytes in fixtures) {
      for (var length = 0; length < bytes.length; length++) {
        expect(() => readImageDimensions(bytes.sublist(0, length)),
            throwsFormatException);
      }
    }
    final png = img.encodePng(_rgba());
    _u32be(png, 8, 0x7fffffff);
    expect(() => readImageDimensions(png), throwsFormatException);
    final webp = img.encodeWebP(_rgba());
    for (var i = 16; i < 20; i++) {
      webp[i] = 255;
    }
    expect(() => readImageDimensions(webp), throwsFormatException);
  });

  test('完整PNG->losslessWebP->会话加密->密文传输->解密像素一致', () async {
    final root =
        await Directory.systemTemp.createTemp('zaizuo-image-transfer-');
    try {
      final encoded =
          await PreferredImageEncoder().encodeBytes(img.encodePng(_rgba()));
      final sender =
          EncryptedAttachments(Directory(p.join(root.path, 'sender')));
      final receiver =
          EncryptedAttachments(Directory(p.join(root.path, 'receiver')));
      final key = ConversationKey.generate('image-chat', 2);
      final descriptor =
          await sender.put(encoded, key, name: '透明图片.webp', mime: 'image/webp');
      final ciphertext = await sender.exportCiphertext(descriptor);
      expect(ciphertext, isNot(encoded));
      await receiver.importCiphertext(
          AttachmentDescriptor.fromJson(descriptor.toJson()), ciphertext);
      final clear = await receiver.get(descriptor, key);
      _samePixels(img.decodeWebP(Uint8List.fromList(clear))!, _rgba());
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('绝对timeout返回并kill工作isolate，而非让重CPU留在宿主isolate', () async {
    final source = img.Image(width: 128, height: 128, numChannels: 4);
    final watch = Stopwatch()..start();
    await expectLater(
            PreferredImageEncoder(timeout: const Duration(microseconds: 1))
                .encodeBytes(img.encodePng(source)),
            throwsA(isA<TimeoutException>()))
        .timeout(const Duration(seconds: 5));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    // A subsequent independent task still completes normally after timed-out spawn.
    final next =
        await PreferredImageEncoder().encodeBytes(img.encodePng(_rgba()));
    expect(readImageDimensions(next).width, 3);
  });
}
