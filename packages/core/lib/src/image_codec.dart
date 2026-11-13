import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 不解码像素的静态 PNG/JPEG/WebP 尺寸预检。
///
/// 这些边界检查减少明显的超尺寸/动画输入进入编解码器，但不验证完整像素
/// bitstream，也不是 OS 内存/CPU 配额或原生解码器沙箱。宿主仍须限制输入
/// 字节数，并对真正的解码/编码操作使用独立 isolate 或有界可信子进程。
final class ImageDimensions {
  const ImageDimensions(this.format, this.width, this.height);
  final String format;
  final int width;
  final int height;
  int get pixels => width * height;
}

/// 只支持静态 PNG、8-bit JPEG 和静态 WebP；拒绝动画、未知格式、截断、
/// 矛盾尺寸、零尺寸以及超过 [maxPixels]/[maxDimension] 的输入。
/// 不信任扩展名，不在本函数中分配 width*height 像素缓冲。
ImageDimensions readImageDimensions(List<int> bytes,
    {int maxPixels = 16 * 1024 * 1024, int maxDimension = 16383}) {
  if (maxPixels < 1 ||
      maxPixels > 64 * 1024 * 1024 ||
      maxDimension < 1 ||
      maxDimension > 16383) {
    throw ArgumentError('图像像素/边长上限无效');
  }
  if (bytes.length > 20 * 1024 * 1024 ||
      bytes.any((byte) => byte < 0 || byte > 255)) {
    throw const FormatException('图像输入字节无效或过大');
  }
  ImageDimensions checked(String format, int width, int height) {
    if (width < 1 ||
        height < 1 ||
        width > maxDimension ||
        height > maxDimension ||
        width > maxPixels ~/ height) {
      throw const FormatException('图像尺寸/像素数超过本机上限');
    }
    return ImageDimensions(format, width, height);
  }

  if (_matches(bytes, 0, const [137, 80, 78, 71, 13, 10, 26, 10])) {
    return _png(bytes, checked);
  }
  if (_matches(bytes, 0, const [0xff, 0xd8])) return _jpeg(bytes, checked);
  if (_fourCC(bytes, 0, 'RIFF') && _fourCC(bytes, 8, 'WEBP')) {
    return _webp(bytes, checked);
  }
  throw const FormatException('仅支持静态PNG/JPEG/WebP图片');
}

typedef _CheckDimensions = ImageDimensions Function(String, int, int);

bool _matches(List<int> bytes, int offset, List<int> expected) {
  if (offset < 0 || offset + expected.length > bytes.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (bytes[offset + i] != expected[i]) return false;
  }
  return true;
}

bool _fourCC(List<int> bytes, int offset, String name) =>
    _matches(bytes, offset, name.codeUnits);
int _u16be(List<int> b, int p) => b[p] << 8 | b[p + 1];
int _u16le(List<int> b, int p) => b[p] | b[p + 1] << 8;
int _u24le(List<int> b, int p) => b[p] | b[p + 1] << 8 | b[p + 2] << 16;
int _u32be(List<int> b, int p) =>
    b[p] << 24 | b[p + 1] << 16 | b[p + 2] << 8 | b[p + 3];
int _u32le(List<int> b, int p) =>
    b[p] | b[p + 1] << 8 | b[p + 2] << 16 | b[p + 3] << 24;
Never _invalid() => throw const FormatException('图像头/分块格式无效');

ImageDimensions _png(List<int> b, _CheckDimensions checked) {
  if (b.length < 33 || _u32be(b, 8) != 13 || !_fourCC(b, 12, 'IHDR')) {
    return _invalid();
  }
  final dimensions = checked('png', _u32be(b, 16), _u32be(b, 20));
  final depth = b[24], color = b[25];
  final validDepth = switch (color) {
    0 => const [1, 2, 4, 8, 16].contains(depth),
    2 || 4 || 6 => const [8, 16].contains(depth),
    3 => const [1, 2, 4, 8].contains(depth),
    _ => false,
  };
  if (!validDepth || b[26] != 0 || b[27] != 0 || b[28] > 1) return _invalid();
  var offset = 8, chunks = 0;
  var dataSeen = false;
  while (offset < b.length) {
    if (++chunks > 4096 || offset + 12 > b.length) return _invalid();
    final length = _u32be(b, offset);
    if (length > b.length - offset - 12) return _invalid();
    if (_fourCC(b, offset + 4, 'acTL') ||
        _fourCC(b, offset + 4, 'fcTL') ||
        _fourCC(b, offset + 4, 'fdAT')) {
      throw const FormatException('暂不支持动画图片');
    }
    if (offset != 8 && _fourCC(b, offset + 4, 'IHDR')) return _invalid();
    if (_fourCC(b, offset + 4, 'IDAT') && length > 0) dataSeen = true;
    if (_fourCC(b, offset + 4, 'IEND')) {
      if (length != 0 || offset + 12 != b.length || !dataSeen)
        return _invalid();
      return dimensions;
    }
    offset += length + 12;
  }
  return _invalid();
}

ImageDimensions _jpeg(List<int> b, _CheckDimensions checked) {
  var offset = 2, scans = 0;
  var entropy = false;
  ImageDimensions? dimensions;
  while (offset < b.length) {
    if (entropy) {
      while (offset < b.length && b[offset] != 0xff) {
        offset++;
      }
    }
    if (offset >= b.length || b[offset++] != 0xff) return _invalid();
    while (offset < b.length && b[offset] == 0xff) {
      offset++;
    }
    if (offset >= b.length) return _invalid();
    final marker = b[offset++];
    if (entropy && (marker == 0 || marker >= 0xd0 && marker <= 0xd7)) continue;
    entropy = false;
    if (marker == 0xd9) {
      if (dimensions == null || scans == 0 || offset != b.length)
        return _invalid();
      return dimensions;
    }
    // DNL can change height after the first frame header. Multi-frame JPEG and
    // unsupported standalone markers are not accepted by this static guard.
    if (marker == 0 ||
        marker == 0xd8 ||
        marker == 0xdc ||
        marker == 1 ||
        marker >= 0xd0 && marker <= 0xd7 ||
        offset + 2 > b.length) {
      return _invalid();
    }
    final length = _u16be(b, offset);
    if (length < 2 || length > b.length - offset) return _invalid();
    final isSof = marker >= 0xc0 &&
        marker <= 0xcf &&
        marker != 0xc4 &&
        marker != 0xc8 &&
        marker != 0xcc;
    if (isSof) {
      if (dimensions != null ||
          !const [0xc0, 0xc1, 0xc2].contains(marker) ||
          length < 8 ||
          b[offset + 2] != 8) return _invalid();
      final components = b[offset + 7];
      if (!const [1, 3, 4].contains(components) ||
          length != 8 + 3 * components) {
        return _invalid();
      }
      dimensions =
          checked('jpeg', _u16be(b, offset + 5), _u16be(b, offset + 3));
    }
    if (marker == 0xda) {
      if (dimensions == null ||
          ++scans > 1000 ||
          length < 6 ||
          b[offset + 2] < 1 ||
          b[offset + 2] > 4 ||
          length != 6 + 2 * b[offset + 2]) return _invalid();
      entropy = true;
    }
    offset += length;
  }
  return _invalid();
}

ImageDimensions _webp(List<int> b, _CheckDimensions checked) {
  if (b.length < 20 || _u32le(b, 4) + 8 != b.length) return _invalid();
  var offset = 12, chunks = 0;
  ImageDimensions? canvas, frame;
  while (offset < b.length) {
    if (++chunks > 4096 || offset + 8 > b.length) return _invalid();
    final length = _u32le(b, offset + 4);
    final data = offset + 8;
    if (length > b.length - data || data + length + (length & 1) > b.length) {
      return _invalid();
    }
    if (_fourCC(b, offset, 'ANIM') || _fourCC(b, offset, 'ANMF')) {
      throw const FormatException('暂不支持动画图片');
    }
    if (_fourCC(b, offset, 'VP8X')) {
      if (offset != 12 ||
          canvas != null ||
          length != 10 ||
          b[data] & 0xc1 != 0 ||
          b[data + 1] != 0 ||
          b[data + 2] != 0 ||
          b[data + 3] != 0) return _invalid();
      if (b[data] & 2 != 0) throw const FormatException('暂不支持动画图片');
      canvas =
          checked('webp', _u24le(b, data + 4) + 1, _u24le(b, data + 7) + 1);
    } else if (_fourCC(b, offset, 'VP8 ')) {
      if (frame != null ||
          length < 10 ||
          b[data] & 1 != 0 ||
          !_matches(b, data + 3, const [0x9d, 1, 0x2a])) return _invalid();
      frame = checked(
          'webp', _u16le(b, data + 6) & 0x3fff, _u16le(b, data + 8) & 0x3fff);
    } else if (_fourCC(b, offset, 'VP8L')) {
      if (frame != null || length < 5 || b[data] != 0x2f) return _invalid();
      final bits = _u32le(b, data + 1);
      if (bits >> 29 != 0) return _invalid();
      frame = checked('webp', (bits & 0x3fff) + 1, (bits >> 14 & 0x3fff) + 1);
    }
    offset = data + length + (length & 1);
  }
  if (frame == null ||
      canvas != null &&
          (canvas.width != frame.width || canvas.height != frame.height)) {
    return _invalid();
  }
  return canvas ?? frame;
}

/// 首选跨平台纯Dart图片编码器（Dart VM / Flutter Native，无本机exe要求）。
///
/// 使用固定依赖 image 4.12.0 的真实编解码器；预检PNG/JPEG/WebP尺寸后，
/// 在独立isolate解码，再核对实际尺寸/帧数，转8-bit RGBA并默认lossless WebP、
/// exact=true保留全透明像素的RGB。JPEG重压缩无损仅相对解码后的像素，不能
/// 恢复JPEG原先已丢失的内容。16-bit输入会转为8-bit，不声称16-bit逐位无损。
///
/// timeout后kill工作isolate；像素/字节限制降低风险但不是OS内存/CPU硬配额，
/// 也不保证第三方编解码器无漏洞。isolate并不形成进程级安全沙箱。
class PreferredImageEncoder {
  PreferredImageEncoder({
    this.lossless = true,
    this.quality = 85,
    this.maxInputBytes = 20 * 1024 * 1024,
    this.maxOutputBytes = 20 * 1024 * 1024,
    this.maxPixels = 16 * 1024 * 1024,
    this.maxDimension = 16383,
    this.timeout = const Duration(seconds: 30),
  }) {
    if (quality < 0 ||
        quality > 100 ||
        maxInputBytes < 1 ||
        maxInputBytes > 20 * 1024 * 1024 ||
        maxOutputBytes < 1 ||
        maxOutputBytes > 20 * 1024 * 1024 ||
        timeout <= Duration.zero ||
        maxPixels < 1 ||
        maxPixels > 64 * 1024 * 1024 ||
        maxDimension < 1 ||
        maxDimension > 16383) {
      throw ArgumentError('图像编码资源配置无效');
    }
  }
  final bool lossless;
  final int quality;
  final int maxInputBytes;
  final int maxOutputBytes;
  final int maxPixels;
  final int maxDimension;
  final Duration timeout;

  Future<List<int>> encode(File input) async {
    final watch = Stopwatch()..start();
    final remaining = () => timeout - watch.elapsed;
    try {
      final bytes = await _readImageFile(input, maxInputBytes, () {
        if (remaining() <= Duration.zero) throw TimeoutException('图像操作超时');
      }).timeout(timeout);
      final left = remaining();
      if (left <= Duration.zero) throw TimeoutException('图像操作超时');
      return await _encodeSnapshot(bytes, left);
    } on FileSystemException {
      throw StateError('图片文件无法读取');
    }
  }

  Future<List<int>> encodeBytes(List<int> bytes) {
    // Snapshot before the first async suspension; callers may reuse their buffer.
    if (bytes.isEmpty ||
        bytes.length > maxInputBytes ||
        bytes.any((b) => b < 0 || b > 255)) {
      return Future.error(ArgumentError('图片字节为空、无效或超过上限'));
    }
    return _encodeSnapshot(Uint8List.fromList(bytes), timeout);
  }

  Future<List<int>> _encodeSnapshot(Uint8List bytes, Duration limit) async {
    final messages = ReceivePort();
    Isolate? worker;
    var finished = false;
    final watch = Stopwatch()..start();
    try {
      final starting = Isolate.spawn<List<Object?>>(
          _imageWorker,
          [
            messages.sendPort,
            TransferableTypedData.fromList([bytes]),
            maxPixels,
            maxDimension,
            maxOutputBytes,
            lossless,
            quality,
          ],
          onError: messages.sendPort,
          onExit: messages.sendPort,
          errorsAreFatal: true,
          debugName: 'zaizuo-image-codec');
      unawaited(starting.then<void>((lateWorker) {
        if (finished) lateWorker.kill(priority: Isolate.immediate);
      }, onError: (Object _) {}));
      worker = await starting.timeout(limit);
      final remaining = limit - watch.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('图像操作超时');
      final result = await messages.first.timeout(remaining);
      if (result is TransferableTypedData) {
        final output = result.materialize().asUint8List();
        if (output.isEmpty || output.length > maxOutputBytes) {
          throw StateError('WebP输出超过本机上限');
        }
        return output;
      }
      if (result is String && result == 'invalid_image') {
        throw const FormatException('图片损坏、动画或超出尺寸上限');
      }
      if (result is String && result == 'output_limit') {
        throw StateError('WebP输出超过本机上限');
      }
      throw StateError('图片编解码未成功完成');
    } on TimeoutException {
      throw TimeoutException('图像编码达到本机总期限');
    } finally {
      finished = true;
      worker?.kill(priority: Isolate.immediate);
      messages.close();
    }
  }
}

void _imageWorker(List<Object?> arguments) {
  final output = arguments[0] as SendPort;
  try {
    final bytes =
        (arguments[1] as TransferableTypedData).materialize().asUint8List();
    final maxPixels = arguments[2] as int;
    final maxDimension = arguments[3] as int;
    final maxOutput = arguments[4] as int;
    final lossless = arguments[5] as bool;
    final quality = arguments[6] as int;
    final dimensions = readImageDimensions(bytes,
        maxPixels: maxPixels, maxDimension: maxDimension);
    final img.Decoder decoder = switch (dimensions.format) {
      'png' => img.PngDecoder(maxPixels: maxPixels),
      'jpeg' => img.JpegDecoder(maxPixels: maxPixels),
      'webp' => img.WebPDecoder()..maxPixels = maxPixels,
      _ => throw const FormatException(),
    };
    // image's JPEG decoder applies EXIF orientation. Account for an explicit
    // 90-degree orientation before comparing dimensions; pixel count is unchanged.
    final orientation = dimensions.format == 'jpeg'
        ? img.decodeJpgExif(bytes)?.imageIfd.orientation ?? 1
        : 1;
    final swap = orientation >= 5 && orientation <= 8;
    final expectedWidth = swap ? dimensions.height : dimensions.width;
    final expectedHeight = swap ? dimensions.width : dimensions.height;
    final decoded = decoder.decode(bytes, frame: 0);
    if (decoded == null ||
        decoded.hasAnimation ||
        decoded.width != expectedWidth ||
        decoded.height != expectedHeight) {
      throw const FormatException();
    }
    // Copy only bounded pixel data, not untrusted ICC/EXIF/text metadata that
    // could trigger decompression or carry identifying data on re-encoding.
    final rgba =
        img.Image(width: decoded.width, height: decoded.height, numChannels: 4);
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        final pixel = decoded.getPixel(x, y);
        final scale = 255 / pixel.maxChannelValue;
        rgba.setPixelRgba(
            x,
            y,
            (pixel.r * scale).round(),
            (pixel.g * scale).round(),
            (pixel.b * scale).round(),
            (pixel.a * scale).round());
      }
    }
    final encoded = img.encodeWebP(rgba,
        singleFrame: true,
        exact: true,
        lossless: lossless,
        quality: quality,
        alphaQuality: 100);
    if (encoded.length > maxOutput) {
      output.send('output_limit');
      return;
    }
    final result = readImageDimensions(encoded,
        maxPixels: maxPixels, maxDimension: maxDimension);
    if (result.format != 'webp' ||
        result.width != expectedWidth ||
        result.height != expectedHeight) throw const FormatException();
    output.send(TransferableTypedData.fromList([encoded]));
  } catch (_) {
    // Do not include paths, bytes, metadata or third-party diagnostics in errors.
    output.send('invalid_image');
  }
}

Future<Uint8List> _readImageFile(
    File input, int limit, void Function() check) async {
  var path = p.normalize(input.absolute.path);
  while (true) {
    check();
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('图片路径不接受符号链接');
    }
    final parent = p.dirname(path);
    if (parent == path) break;
    path = parent;
  }
  if (await FileSystemEntity.type(input.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError('图片必须是本机普通文件');
  }
  final handle = await input.open(mode: FileMode.read);
  try {
    if (await handle.length() > limit) throw StateError('图片字节超过本机上限');
    final builder = BytesBuilder(copy: false);
    while (builder.length <= limit) {
      check();
      final chunk =
          await handle.read((limit + 1 - builder.length).clamp(1, 64 * 1024));
      if (chunk.isEmpty) break;
      builder.add(chunk);
    }
    if (builder.isEmpty || builder.length > limit)
      throw StateError('图片为空或超过上限');
    return builder.takeBytes();
  } finally {
    await handle.close();
  }
}
