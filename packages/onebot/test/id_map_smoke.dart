// 可在domain被并行编辑时独立验证ID落盘失败边界。
import '../lib/src/id_map.dart';

void main() {
  Map<String, dynamic>? saved;
  var failing = false;
  final map = OneBotIdMap(onChanged: (state) {
    if (failing) throw StateError('simulated write failure');
    saved = state;
  });
  if (map.encode('message', 'published') != 1) throw StateError('first ID');
  failing = true;
  try {
    map.encode('message', 'unpublished');
    throw StateError('failure was ignored');
  } catch (_) {
    if (!map.persistenceFailed) rethrow;
  }
  final restored = OneBotIdMap.fromJson(saved!);
  if (restored.encode('message', 'published') != 1 ||
      restored.encode('message', 'next') != 2)
    throw StateError('mapping changed');
  final asyncMap = OneBotIdMap(onChanged: (state) async {});
  try {
    asyncMap.encode('user', 'bad');
    throw StateError('async callback accepted');
  } catch (_) {
    if (!asyncMap.persistenceFailed) rethrow;
  }
  print('ID mapping smoke passed');
}
