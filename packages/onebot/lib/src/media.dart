import 'dart:convert';

import 'backend.dart';

const oneBotDefaultMaxMediaBytes = 8 * 1024 * 1024;

/// 附件仅使用宿主签发的opaque ID，不把URL/本机路径当可访问资源。
String validateOpaqueFileId(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 512 ||
      !RegExp(r'^[A-Za-z0-9_.~-]+$').hasMatch(value) ||
      value == '.' ||
      value == '..') {
    throw const OneBotFailure('bad_param', 'Invalid opaque file ID');
  }
  return value;
}

/// 名字只是元数据，永远不是此包可打开的path；清理跨平台危险字符。
String sanitizeMediaName(Object? value) {
  if (value is! String || value.isEmpty || value.runes.length > 256) {
    throw const OneBotFailure(
        'bad_param', 'File name must contain 1..256 characters');
  }
  var name = value.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_').trim();
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') name = 'attachment';
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
          caseSensitive: false)
      .hasMatch(name)) {
    name = '_$name';
  }
  return name;
}

String validateMediaMime(Object? value) {
  if (value is! String ||
      value.length > 127 ||
      !RegExp(r'^[a-zA-Z0-9!#$&^_.+-]+/[a-zA-Z0-9!#$&^_.+-]+$')
          .hasMatch(value)) {
    throw const OneBotFailure('bad_param', 'Invalid media MIME type');
  }
  return value.toLowerCase();
}

String validateMediaPurpose(Object? value) {
  if (value != 'image' && value != 'file') {
    throw const OneBotFailure(
        'bad_param', 'Media purpose must be image or file');
  }
  return value as String;
}

List<int> decodeMediaBase64(Object? value, int maxBytes) {
  final maxEncoded = ((maxBytes + 2) ~/ 3) * 4;
  if (value is! String || value.length > maxEncoded || value.length % 4 != 0) {
    throw const OneBotFailure('bad_param', 'Invalid or oversized Base64 data');
  }
  // MiB级数据用线性扫描，避免重复分组RegExp栈溢出。
  var padding = 0;
  for (var i = 0; i < value.length; i++) {
    final code = value.codeUnitAt(i);
    final alphabet = code >= 65 && code <= 90 ||
        code >= 97 && code <= 122 ||
        code >= 48 && code <= 57 ||
        code == 43 ||
        code == 47;
    if (code == 61) {
      padding++;
      if (padding > 2 || i < value.length - 2) {
        throw const OneBotFailure('bad_param', 'Invalid Base64 padding');
      }
    } else if (!alphabet || padding != 0) {
      throw const OneBotFailure('bad_param', 'Invalid Base64 data');
    }
  }
  final bytes = base64Decode(value);
  if (bytes.length > maxBytes || base64Encode(bytes) != value) {
    throw const OneBotFailure('bad_param', 'Invalid or oversized Base64 data');
  }
  return bytes;
}

/// 只允许把后端确认后的公开元数据投影出去，descriptor/key/epoch不会穿透。
Map<String, dynamic> publicMediaData(Map data) => {
      'file_id': validateOpaqueFileId(data['file_id']),
      if (data.containsKey('name')) 'name': sanitizeMediaName(data['name']),
      if (data.containsKey('mime')) 'mime': validateMediaMime(data['mime']),
    };

bool hasMediaParts(List<Map<String, dynamic>> parts) =>
    parts.any((part) => part['type'] == 'image' || part['type'] == 'file');
