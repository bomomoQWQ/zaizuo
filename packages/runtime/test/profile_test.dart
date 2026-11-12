import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

void main() {
  test('本机账号创建、密码解锁、加密资料防篡改与重启命令回放', () async {
    final root = await Directory.systemTemp.createTemp('zaizuo-profile-');
    addTearDown(() => root.delete(recursive: true));
    const password = 'R7!mK2@wX9#vT4%p';
    await LocalProfile.initialize(root,
        name: 'alice',
        displayName: '爱丽丝',
        password: password,
        parameters:
            const KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1));
    final profile = await LocalProfile.open(root, password);
    final (store, replica) = await profile.replica();
    final accountId = profile.identity.public.accountId;
    await replica.execute(
        actorId: accountId,
        operation: 'bot.register',
        params: {'id': 'testbot', 'display_name': '小在'},
        conversation: 'control:${profile.manifest.communityId}');
    await replica.execute(
        actorId: accountId,
        operation: 'space.create',
        params: {'id': 'hello', 'title': '欢迎', 'public_channel': true},
        conversation: 'control:${profile.manifest.communityId}');
    await replica.ensureConversationKey('hello#main');
    await profile.savePrivate(seed: profile.seed, keys: replica.keys);
    await replica.execute(
        actorId: accountId,
        operation: 'message.send',
        params: {
          'conversation': 'hello#main',
          'parts': [
            {
              'type': 'text',
              'data': {'text': '重启后还在'}
            }
          ]
        },
        conversation: 'hello#main');
    await replica.close();
    await store.close();
    final reopened = await LocalProfile.open(root, password);
    final (store2, replica2) = await reopened.replica();
    expect(replica2.service.state.bots['testbot']!.ownerId, accountId);
    expect(
        replica2.service
            .messages(
                actor: replica2.service.actor(accountId),
                conversationId: 'hello#main')
            .single
            .parts
            .single['data']['text'],
        '重启后还在');
    await replica2.close();
    await store2.close();
    await expectLater(
        LocalProfile.open(root, 'Wrong!XyZ9800'), throwsA(anything));
    final privateFile = File('${root.path}/local-private.json');
    final original = await privateFile.readAsString();
    final fake = await wrapSecret(
        '{}'.codeUnits, profile.identity.public.exchangeKey,
        context: 'zaizuo.local-profile.v1:$accountId');
    await privateFile.writeAsString(canonicalJson(fake), flush: true);
    await expectLater(LocalProfile.open(root, password), throwsA(anything));
    await privateFile.writeAsString(original, flush: true);
    final vaultText = await File('${root.path}/account.keybox').readAsString();
    expect(vaultText.contains('signing_seed'), isFalse);
    expect(original.contains('重启后还在'), isFalse);
  });
}
