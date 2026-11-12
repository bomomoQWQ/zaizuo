import 'dart:async';
import 'dart:convert';

typedef OneBotMappingChanged = void Function(Map<String, dynamic> state);

/// v11 的整数编号与原生字符串 ID 的无碰撞双向映射。
///
/// 使用逐一分配而非截断 hash。message 范围限正 int32；其余也故意限制到
/// int32 以便 JSON/JS 客户端精确表示。达到上限时拒绝分配，绝不重用旧编号。
/// 同一内核的两个协议必须共享此实例，重启前需持久化 [toJson] 的完整结果。
class OneBotIdMap {
  OneBotIdMap({this.onChanged});

  /// 必须同步可靠保存后返回，不能使用async回调；失败使本实例永久fail-closed。
  final OneBotMappingChanged? onChanged;
  bool _persistenceFailed = false;
  bool _notifying = false;
  bool get persistenceFailed => _persistenceFailed;
  static const maxId = 0x7fffffff;
  static const _spaces = {'user', 'group', 'message'};
  final Map<String, Map<String, int>> _forward = {};
  final Map<String, Map<int, String>> _reverse = {};
  final Map<String, int> _next = {};

  int encode(String space, String nativeId) {
    _checkUsable();
    _checkSpace(space);
    if (nativeId.isEmpty) throw ArgumentError.value(nativeId, 'nativeId');
    final forward = _forward.putIfAbsent(space, () => {});
    final found = forward[nativeId];
    if (found != null) return found;
    final next = _next[space] ?? 1;
    if (next > maxId) throw StateError('OneBot v11 ID space exhausted');
    forward[nativeId] = next;
    _reverse.putIfAbsent(space, () => {})[next] = nativeId;
    _next[space] = next + 1;
    if (onChanged != null) {
      try {
        _notifying = true;
        // 即使调用者把async函数传给void函数型参数，也在返回前显式拒绝。
        final Object? outcome = Function.apply(onChanged!, [toJson()]);
        if (outcome is Future) {
          unawaited(outcome.then<void>((_) {}, onError: (Object _) {}));
          throw StateError('Mapping persistence callback must be synchronous');
        }
      } catch (_) {
        // 回滚未发布的新分配；持久化可能已经部分成功，禁止继续分配/重用，
        // 必须由宿主核对持久化状态后创建新实例恢复。
        forward.remove(nativeId);
        _reverse[space]!.remove(next);
        _next[space] = next;
        _persistenceFailed = true;
        rethrow;
      } finally {
        _notifying = false;
      }
    }
    return next;
  }

  String? decode(String space, Object? value) {
    _checkUsable();
    _checkSpace(space);
    final int? id;
    if (value is int) {
      id = value;
    } else if (value is String && RegExp(r'^[0-9]+$').hasMatch(value)) {
      id = int.tryParse(value);
    } else {
      return null;
    }
    if (id == null || id < 1 || id > maxId) return null;
    return _reverse[space]?[id];
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'spaces': {
          for (final space in _spaces)
            space: {
              'next': _next[space] ?? 1,
              'entries': {...?_forward[space]},
            }
        },
      };

  factory OneBotIdMap.fromJson(Map<String, dynamic> json,
      {OneBotMappingChanged? onChanged}) {
    if (json['version'] != 1 || json['spaces'] is! Map) {
      throw const FormatException('Invalid OneBot mapping state');
    }
    final result = OneBotIdMap(onChanged: onChanged);
    final spaces = json['spaces'] as Map;
    if (spaces.keys.toSet().difference(_spaces).isNotEmpty) {
      throw const FormatException('Unknown mapping namespace');
    }
    for (final space in _spaces) {
      final state = spaces[space];
      if (state is! Map || state['entries'] is! Map || state['next'] is! int) {
        throw const FormatException('Invalid mapping namespace');
      }
      final next = state['next'] as int;
      if (next < 1 || next > maxId + 1) {
        throw const FormatException('Invalid mapping sequence');
      }
      final entries = state['entries'] as Map;
      final forward = <String, int>{};
      final reverse = <int, String>{};
      for (final entry in entries.entries) {
        if (entry.key is! String ||
            (entry.key as String).isEmpty ||
            entry.value is! int) {
          throw const FormatException('Invalid mapping entry');
        }
        final id = entry.value as int;
        if (id < 1 || id >= next || id > maxId || reverse.containsKey(id)) {
          throw const FormatException('Duplicate or invalid mapping integer');
        }
        forward[entry.key as String] = id;
        reverse[id] = entry.key as String;
      }
      result._forward[space] = forward;
      result._reverse[space] = reverse;
      result._next[space] = next;
    }
    return result;
  }

  /// JSON 字符串形式便于交给调用方自己的原子写盘/事务存储。
  String exportState() => jsonEncode(toJson());
  factory OneBotIdMap.loadState(String state,
          {OneBotMappingChanged? onChanged}) =>
      OneBotIdMap.fromJson(jsonDecode(state) as Map<String, dynamic>,
          onChanged: onChanged);

  void _checkUsable() {
    if (_persistenceFailed || _notifying) {
      throw StateError('Mapping persistence failed or callback reentered');
    }
  }

  static void _checkSpace(String space) {
    if (!_spaces.contains(space)) throw ArgumentError.value(space, 'space');
  }
}
