import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

const fast = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
const password = 'R7!mK2@wX9#vT4%p';
void main() {
  test('第二账号入驻、根签名成员/设备/控制密钥及配置防回退', () async {
    final root = await Directory.systemTemp.createTemp('zaizuo-membership-');
    addTearDown(() => root.delete(recursive: true));
    final aDir = Directory('${root.path}/alice');
    final bDir = Directory('${root.path}/bob');
    await LocalProfile.initialize(aDir,
        name: 'alice',
        displayName: '爱丽丝',
        password: password,
        parameters: fast);
    final a = await LocalProfile.open(aDir, password);
    await LocalProfile.initialize(bDir,
        name: 'bob',
        displayName: '鲍勃',
        password: password,
        community: a.manifest,
        pinnedFingerprint: await a.manifest.fingerprint(),
        parameters: fast);
    final b = await LocalProfile.open(bDir, password);
    expect(b.keys, isEmpty);
    final oldManifest = a.manifest;
    final next = await a.admit(await b.joinRequest());
    await a.acceptManifest(next);
    await b.acceptManifest(next);
    expect(b.keys.single.conversationId, 'control:${a.manifest.communityId}');
    expect(b.keys.single.bytes, a.keys.single.bytes);
    expect(b.trust.devices.containsKey(a.device.certificate!.id), isTrue);
    final reopened = await LocalProfile.open(bDir, password);
    expect(reopened.manifest.revision, 2);
    expect(reopened.seed.accounts.length, 2);
    await File('${bDir.path}/community.json')
        .writeAsString(canonicalJson(oldManifest.toJson()), flush: true);
    await expectLater(LocalProfile.open(bDir, password), throwsStateError);
  });
}
