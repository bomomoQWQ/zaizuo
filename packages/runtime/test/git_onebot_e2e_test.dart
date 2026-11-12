import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_onebot/zaizuo_onebot.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

const password = 'R7!mK2@wX9#vT4%p';
const fast = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
void main() {
  test('两个真实账户通过裸Git同步密文，OneBot11/12同内核发送并持久化', () async {
    final root = await Directory.systemTemp.createTemp('zaizuo-git-bot-');
    addTearDown(() => root.delete(recursive: true));
    final bare = Directory('${root.path}/remote.git');
    final init = await Process.run(
        'git', ['init', '--bare', '--initial-branch=main', bare.path]);
    expect(init.exitCode, 0);
    final aDir = Directory('${root.path}/alice');
    final bDir = Directory('${root.path}/bob');
    await LocalProfile.initialize(aDir,
        name: 'alice',
        displayName: '爱丽丝',
        password: password,
        parameters: fast);
    final alice = await LocalProfile.open(aDir, password);
    await LocalProfile.initialize(bDir,
        name: 'bob',
        displayName: '鲍勃',
        password: password,
        community: alice.manifest,
        pinnedFingerprint: await alice.manifest.fingerprint(),
        parameters: fast);
    final bob = await LocalProfile.open(bDir, password);
    final next = await alice.admit(await bob.joinRequest());
    final aGit = await GitSync.initialize(
        worktree: Directory('${root.path}/a-git'),
        remoteUrl: bare.path,
        deviceId: alice.device.certificate!.id);
    final bGit = await GitSync.initialize(
        worktree: Directory('${root.path}/b-git'),
        remoteUrl: bare.path,
        deviceId: bob.device.certificate!.id);
    addTearDown(aGit.close);
    addTearDown(bGit.close);
    final aMain = CommunityGit(
        repository: aGit,
        pinnedFingerprint: await alice.manifest.fingerprint());
    final bMain = CommunityGit(
        repository: bGit,
        pinnedFingerprint: await alice.manifest.fingerprint());
    await aMain.publish(alice.manifest);
    await aMain.publish(next);
    await alice.acceptManifest(next);
    final history = await bMain.readHistory();
    for (final manifest
        in history.where((m) => m.revision > bob.manifest.revision))
      await bob.acceptManifest(manifest);
    final (aStore, aReplica) = await alice.replica();
    final (bStore0, bReplica0) = await bob.replica();
    // 公开频道先创建/加入，私密正文不会放控制通道。
    await aReplica.execute(
        actorId: alice.identity.public.accountId,
        operation: 'space.create',
        params: {'id': 'lobby', 'title': '在座讨论', 'public_channel': true},
        conversation: 'control:${alice.manifest.communityId}');
    await aGit.push(aStore);
    await bGit.pull(bStore0);
    await bReplica0.refresh();
    await bReplica0.execute(
        actorId: bob.identity.public.accountId,
        operation: 'space.join',
        params: {'space': 'lobby'},
        conversation: 'control:${bob.manifest.communityId}');
    await bGit.push(bStore0);
    await aGit.pull(aStore);
    await aReplica.refresh();
    await aReplica.ensureConversationKey('lobby#main');
    await aGit.push(aStore);
    await bGit.pull(bStore0);
    await bReplica0.refresh();
    expect(bReplica0.keys.any((k) => k.conversationId == 'lobby#main'), isTrue);
    final sent = await aReplica.execute(
        actorId: alice.identity.public.accountId,
        operation: 'message.send',
        params: {
          'conversation': 'lobby#main',
          'parts': [
            {
              'type': 'text',
              'data': {'text': '不会出现在Git里的明文'}
            }
          ]
        },
        conversation: 'lobby#main');
    await aGit.push(aStore);
    await bGit.pull(bStore0);
    await bReplica0.refresh();
    expect(
        bReplica0.service
            .message(
                actor: bReplica0.service.actor(bob.identity.public.accountId),
                messageId: (sent['result'] as Map)['id'] as String)
            .parts
            .single['data']['text'],
        '不会出现在Git里的明文');
    for (final envelope in aStore.allEnvelopes)
      expect(
          canonicalJson(envelope.toJson()).contains('不会出现在Git里的明文'), isFalse);
    // 在Bob端注册bot并为它入群；OneBot固定绑定该bot。
    await bReplica0.execute(
        actorId: bob.identity.public.accountId,
        operation: 'bot.register',
        params: {'id': 'bob_bot', 'display_name': '小在'},
        conversation: 'control:${bob.manifest.communityId}');
    await bReplica0.execute(
        actorId: bob.identity.public.accountId,
        operation: 'space.join',
        params: {'space': 'lobby', 'bot_id': 'bob_bot'},
        conversation: 'control:${bob.manifest.communityId}');
    final backend = DomainOneBotBackend(bReplica0.service,
        botId: 'bob_bot',
        serviceProvider: () => bReplica0.service,
        messageStream: bReplica0.messages,
        sendHandler: (
            {required actor, required conversationId, required parts}) async {
          final result = await bReplica0.execute(
              actorId: actor.id,
              operation: 'message.send',
              params: {'conversation': conversationId, 'parts': parts},
              conversation: conversationId);
          return MessageRecord.fromJson(
              result['result'] as Map<String, dynamic>);
        });
    final ids = OneBotIdMap();
    final projection = OneBotProjection(backend: backend, ids: ids);
    const token = 'test-only-abcdefghijklmnopqrstuvwxyz0123456789';
    final server = OneBotServer(
        bindings: [OneBotBinding(token: token, projection: projection)]);
    await server.start();
    try {
      final v12 = await action(server.port, token, 12, {
        'action': 'send_message',
        'params': {
          'detail_type': 'group',
          'group_id': 'lobby#main',
          'message': '12协议成功'
        },
        'echo': 'echo12'
      });
      expect(v12['retcode'], 0);
      expect(v12['echo'], 'echo12');
      final group = ids.encode('group', 'lobby#main');
      final v11 = await action(server.port, token, 11, {
        'action': 'send_group_msg',
        'params': {'group_id': group, 'message': '11协议成功'},
        'echo': {'same': true}
      });
      expect(v11['retcode'], 0);
      expect(v11['echo'], {'same': true});
      await bGit.push(bStore0);
      await aGit.pull(aStore);
      await aReplica.refresh();
      final messages = aReplica.service.messages(
          actor: aReplica.service.actor(alice.identity.public.accountId),
          conversationId: 'lobby#main');
      expect(messages.where((m) => m.senderId == 'bob_bot').length, 2);
      expect(messages.map((m) => m.parts.single['data']['text']),
          containsAll(['12协议成功', '11协议成功']));
    } finally {
      await server.close();
      await projection.close();
      await backend.close();
    }
    await aReplica.close();
    await aStore.close();
    await bReplica0.close();
    await bStore0.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<Map<String, dynamic>> action(
    int port, String token, int version, Map<String, dynamic> request) async {
  final client = HttpClient();
  try {
    final q = await client
        .postUrl(Uri.parse('http://127.0.0.1:$port/onebot/v$version'));
    q.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    q.headers.contentType = ContentType.json;
    q.write(jsonEncode(request));
    final r = await q.close();
    return jsonObject(await utf8.decoder.bind(r).join());
  } finally {
    client.close(force: true);
  }
}
