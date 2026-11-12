import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// 固定 JSON 编码：键按 Unicode code unit 排序；协议只允许整数，不使用浮点。
String canonicalJson(Object? value) => jsonEncode(_canonical(value));
Object? _canonical(Object? value) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is List) return value.map(_canonical).toList(growable: false);
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  throw FormatException('协议不允许的 JSON 值: ${value.runtimeType}');
}

Map<String, dynamic> jsonObject(String text) {
  final value = jsonDecode(text);
  if (value is! Map<String, dynamic>) {
    throw const FormatException('需要 JSON 对象');
  }
  return value;
}

List<int> secureBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256),
      growable: false);
}

String hexEncode(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
Future<String> sha256Hex(List<int> bytes) async =>
    hexEncode((await Sha256().hash(bytes)).bytes);
Future<String> objectHash(Object? value) =>
    sha256Hex(utf8.encode(canonicalJson(value)));
String randomId([int bytes = 24]) => hexEncode(secureBytes(bytes));

String readString(Map<String, dynamic> value, String key, {int max = 4096}) {
  final item = value[key];
  if (item is! String || item.isEmpty || item.length > max) {
    throw FormatException('无效字符串 $key');
  }
  return item;
}

int readInt(Map<String, dynamic> value, String key,
    {int min = 0, int max = 0x1fffffffffffff}) {
  final item = value[key];
  if (item is! int || item < min || item > max) {
    throw FormatException('无效整数 $key');
  }
  return item;
}

List<int> readBase64(Map<String, dynamic> value, String key,
    {int? size, int max = 1048576}) {
  final text = readString(value, key, max: max * 2);
  final bytes = base64Decode(text);
  if (base64Encode(bytes) != text ||
      bytes.length > max ||
      (size != null && bytes.length != size)) {
    throw FormatException('无效 Base64 $key');
  }
  return bytes;
}

bool equalBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
