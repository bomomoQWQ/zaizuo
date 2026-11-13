import 'backend.dart';
import 'id_map.dart';
import 'media.dart';

/// CQ 转义必须先解析边界，再解码实体（&amp; 最后解），避免二次解析注入。
class CqCodec {
  static String escape(String value, {bool parameter = false}) {
    var text = value
        .replaceAll('&', '&amp;')
        .replaceAll('[', '&#91;')
        .replaceAll(']', '&#93;');
    if (parameter) text = text.replaceAll(',', '&#44;');
    return text;
  }

  static String unescape(String value, {bool parameter = false}) {
    var text = value.replaceAll('&#91;', '[').replaceAll('&#93;', ']');
    if (parameter) text = text.replaceAll('&#44;', ',');
    return text.replaceAll('&amp;', '&');
  }

  static List<Map<String, dynamic>> parse(String value) {
    final result = <Map<String, dynamic>>[];
    var offset = 0;
    for (final match in RegExp(r'\[CQ:([A-Za-z0-9_.-]+)((?:,[^\[\]]*)?)\]')
        .allMatches(value)) {
      if (match.start > offset) {
        result.add({
          'type': 'text',
          'data': {
            'text': unescape(value.substring(offset, match.start)),
          }
        });
      }
      final data = <String, dynamic>{};
      final raw = match.group(2)!;
      if (raw.isNotEmpty) {
        for (final parameter in raw.substring(1).split(',')) {
          final split = parameter.indexOf('=');
          if (split < 1 || data.containsKey(parameter.substring(0, split))) {
            throw const OneBotFailure('bad_segment', 'Invalid CQ parameter');
          }
          data[parameter.substring(0, split)] =
              unescape(parameter.substring(split + 1), parameter: true);
        }
      }
      result.add({'type': match.group(1)!, 'data': data});
      offset = match.end;
    }
    if (offset < value.length || result.isEmpty) {
      result.add({
        'type': 'text',
        'data': {
          'text': unescape(value.substring(offset)),
        }
      });
    }
    return result;
  }

  static String format(List<Map<String, dynamic>> parts) => parts.map((part) {
        final type = part['type'] as String;
        final data = part['data'] as Map;
        if (type == 'text') return escape(data['text'] as String);
        return '[CQ:$type${data.entries.map((entry) => ',${entry.key}=${escape('${entry.value}', parameter: true)}').join()}]';
      }).join();
}

/// 内部采用v12语义；image/file仅在可信媒体后端完整配置时接收。
class OneBotMessageCodec {
  OneBotMessageCodec(this.ids, {this.allowMedia = false});
  final OneBotIdMap ids;
  final bool allowMedia;

  List<Map<String, dynamic>> decode(Object? message, int version,
      {bool autoEscape = false}) {
    final Object? input;
    if (message is String) {
      input = version == 11 && !autoEscape
          ? CqCodec.parse(message)
          : [
              {
                'type': 'text',
                'data': {'text': message}
              },
            ];
    } else if (message is Map) {
      input = [message];
    } else {
      input = message;
    }
    if (input is! List || input.isEmpty || input.length > 256) {
      throw const OneBotFailure(
          'bad_segment', 'Message must contain 1..256 segments');
    }
    final result = <Map<String, dynamic>>[];
    for (final segment in input) {
      if (segment is! Map ||
          segment['type'] is! String ||
          segment['data'] is! Map) {
        throw const OneBotFailure('bad_segment', 'Invalid segment shape');
      }
      var type = segment['type'] as String;
      final raw = segment['data'] as Map;
      if (raw.keys.any((key) => key is! String)) {
        throw const OneBotFailure('bad_segment', 'Invalid segment data');
      }
      var data = Map<String, dynamic>.from(raw);
      if (version == 11 && type == 'at') {
        if (data.keys.any((key) => key != 'qq')) {
          throw const OneBotFailure(
              'unsupported_segment_data', 'Unsupported at parameter');
        }
        final qq = data['qq'];
        if (qq == 'all') {
          type = 'mention_all';
          data = {};
        } else {
          final native = ids.decode('user', qq);
          if (native == null) {
            throw const OneBotFailure('bad_segment', 'Unknown mention ID');
          }
          type = 'mention';
          data = {'user_id': native};
        }
      } else if (version == 11 && type == 'reply') {
        if (data.keys.any((key) => key != 'id')) {
          throw const OneBotFailure(
              'unsupported_segment_data', 'Unsupported reply parameter');
        }
        final native = ids.decode('message', data['id']);
        if (native == null) {
          throw const OneBotFailure('bad_segment', 'Unknown reply ID');
        }
        data = {'message_id': native};
      }
      if (type == 'image' || type == 'file') {
        if (!allowMedia) {
          throw const OneBotFailure(
              'unsupported_segment', 'Media backend is not installed');
        }
        if (version == 11 && data.containsKey('file')) {
          if (data.containsKey('file_id')) {
            throw const OneBotFailure(
                'bad_segment', 'Ambiguous media reference');
          }
          data['file_id'] = data.remove('file');
        }
        if (data.keys
            .any((key) => !{'file_id', 'name', 'mime'}.contains(key))) {
          throw const OneBotFailure('unsupported_segment_data',
              'Only opaque file references are accepted');
        }
        data = publicMediaData(data);
      }
      final allowed = switch (type) {
        'text' => {'text'},
        'mention' => {'user_id'},
        'mention_all' => <String>{},
        'reply' => {'message_id', 'user_id'},
        'image' || 'file' => {'file_id', 'name', 'mime'},
        _ => throw const OneBotFailure(
            'unsupported_segment', 'Unsupported message segment'),
      };
      if (data.keys.any((key) => !allowed.contains(key))) {
        throw const OneBotFailure(
            'unsupported_segment_data', 'Unsupported segment parameter');
      }
      final requiredKey = switch (type) {
        'text' => 'text',
        'mention' => 'user_id',
        'reply' => 'message_id',
        _ => null,
      };
      if (requiredKey != null &&
          (data[requiredKey] is! String ||
              (type != 'text' && (data[requiredKey] as String).isEmpty))) {
        throw const OneBotFailure('bad_segment', 'Invalid segment parameter');
      }
      if (data.containsKey('user_id') && data['user_id'] is! String) {
        throw const OneBotFailure('bad_segment', 'Invalid user ID');
      }
      result.add({'type': type, 'data': data});
    }
    return result;
  }

  List<Map<String, dynamic>> encode(
      List<Map<String, dynamic>> parts, int version) {
    return parts.map((part) {
      final type = part['type'];
      final data = Map<String, dynamic>.from(part['data'] as Map);
      if (version == 11 && type == 'mention') {
        return <String, dynamic>{
          'type': 'at',
          'data': {
            'qq': '${ids.encode('user', data['user_id'] as String)}',
          }
        };
      }
      if (version == 11 && type == 'mention_all') {
        return <String, dynamic>{
          'type': 'at',
          'data': {'qq': 'all'}
        };
      }
      if (version == 11 && type == 'reply') {
        return <String, dynamic>{
          'type': 'reply',
          'data': {
            'id': '${ids.encode('message', data['message_id'] as String)}',
          }
        };
      }
      if ((type == 'image' || type == 'file') && allowMedia) {
        final safe = publicMediaData(data);
        return <String, dynamic>{
          'type': type,
          'data': version == 11 ? {'file': safe['file_id'], ...safe} : safe
        };
      }
      if (!{'text', 'mention', 'mention_all', 'reply'}.contains(type)) {
        // 不把未实现的内部段伪装成标准段；显式命名为在座扩展。
        return <String, dynamic>{
          'type': 'zaizuo.unsupported',
          'data': {
            'original_type': '$type',
          }
        };
      }
      return <String, dynamic>{'type': type, 'data': data};
    }).toList(growable: false);
  }

  String alt(List<Map<String, dynamic>> parts) => parts.map((part) {
        final data = part['data'] as Map;
        return switch (part['type']) {
          'text' => data['text'] as String,
          'mention' => '@${data['user_id']}',
          'mention_all' => '@全体成员',
          'reply' => '[回复]',
          'image' => '[图片]',
          'file' => '[文件]',
          _ => '[不支持的消息段]',
        };
      }).join();
}
