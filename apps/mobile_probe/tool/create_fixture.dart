import 'dart:io';
import 'dart:typed_data';

// Deterministic tiny RGBA PNG; no downloaded image or image-library dependency.
// Bright gradient and fully transparent pixels exercise lossless alpha handling.
int crc32(List<int> input) {
  var crc = 0xffffffff;
  for (final byte in input) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

List<int> u32(int value) => [
  value >> 24 & 255,
  value >> 16 & 255,
  value >> 8 & 255,
  value & 255,
];
List<int> chunk(String name, List<int> bytes) {
  final body = [...name.codeUnits, ...bytes];
  return [...u32(bytes.length), ...body, ...u32(crc32(body))];
}

Future<void> main() async {
  const width = 64, height = 48;
  final pixels = BytesBuilder();
  for (var y = 0; y < height; y++) {
    pixels.addByte(0);
    for (var x = 0; x < width; x++) {
      pixels.add([x * 4, y * 5, (x + y) * 2, x < 8 ? 0 : (y < 8 ? 128 : 255)]);
    }
  }
  final png = [
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ...chunk('IHDR', [...u32(width), ...u32(height), 8, 6, 0, 0, 0]),
    ...chunk('IDAT', ZLibEncoder().convert(pixels.takeBytes())),
    ...chunk('IEND', []),
  ];
  await Directory('assets').create(recursive: true);
  await File('assets/probe.png').writeAsBytes(png, flush: true);
  stdout.writeln('Generated 64x48 RGBA local fixture (${png.length} bytes).');
}
