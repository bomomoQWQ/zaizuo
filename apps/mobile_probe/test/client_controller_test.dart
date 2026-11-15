import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_mobile_probe/client_controller.dart';

const _fast = KdfParameters(memoryKiB: 32, iterations: 1);
const _password = 'StrongTest!Secret987';

void main() {
  late Directory root;
  final controllers = <ClientController>[];
  ClientController controller(String name, {GitFactory? gitFactory}) {
    final result = ClientController(
      Directory('${root.path}/$name'),
      parameters: _fast,
      gitFactory: gitFactory,
    );
    controllers.add(result);
    return result;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zaizuo-client-test-');
  });
  tearDown(() async {
    for (final item in controllers) {
      await item.shutdown();
      item.dispose();
    }
    controllers.clear();
    // root 是本测试 createTemp 返回的独立目录，仅回收测试自己创建的数据。
    await root.delete(recursive: true);
  });

  test('密码校验先于任何资料写入，失败后可直接更正重试', () async {
    final current = controller('validation');
    await current.create(
      name: 'bbtest',
      displayName: '测试员',
      password: '123456789012',
    );
    expect(current.error, contains('[invalid_password]'));
    expect(
      await Directory('${root.path}/validation/profile').exists(),
      isFalse,
    );
    await current.create(
      name: 'bbtest',
      displayName: '测试员',
      password: 'M8!vR2@kL9#sT6%z',
    );
    expect(current.error, isNull);
    expect(current.isOpen, isTrue);
  });

  test('既有不完整资料明确提示且绝不覆盖', () async {
    final current = controller('partial');
    final directory = Directory('${root.path}/partial/profile');
    await directory.create(recursive: true);
    final marker = File('${directory.path}/community.json');
    await marker.writeAsString('preserve-original');
    await current.create(
      name: 'bbtest',
      displayName: '测试员',
      password: 'M8!vR2@kL9#sT6%z',
    );
    expect(current.error, contains('[incomplete_profile]'));
    expect(await marker.readAsString(), 'preserve-original');
  });

  test('真实资料创建、授权会话、排队发送、锁定及新控制器重开', () async {
    final first = controller('alice');
    var notifications = 0;
    first.addListener(() => notifications++);
    await first.create(name: 'alice', displayName: '小甲', password: _password);
    expect(first.error, isNull);
    expect(first.admitted, isTrue);
    expect(first.displayName, '小甲');
    expect(first.profile!.root.path, '${root.path}/alice/profile');
    await first.createSpace('测试频道');
    final selected = first.selectedConversationId;
    expect(selected, isNotNull);
    expect(first.selectedConversation!.title, '测试频道');
    expect(first.spaces.single.publicChannel, isTrue);
    final sendOne = first.sendText('本机第一条');
    final sendTwo = first.sendText('本机第二条');
    expect(first.busy, isTrue);
    await Future.wait([sendOne, sendTwo]);
    expect(first.busy, isFalse);
    expect(first.error, isNull);
    expect(first.messages.map((m) => (m.parts.single['data'] as Map)['text']), [
      '本机第一条',
      '本机第二条',
    ]);
    final authorized = first.conversations.map((c) => c.id).toSet();
    first.selectConversation('not-authorized');
    expect(first.error, contains('[forbidden]'));
    expect(first.selectedConversationId, selected);
    expect(authorized, contains(selected));
    await first.lock();
    expect(first.node, isNull);
    expect(first.messages, isEmpty);
    expect(first.conversations, isEmpty);
    await first.shutdown();

    final reopened = controller('alice');
    await reopened.unlock('wrong-password-do-not-print');
    expect(reopened.node, isNull);
    expect(reopened.error, contains('[operation_failed]'));
    expect(reopened.error, isNot(contains('wrong-password')));
    expect(reopened.error, isNot(contains(root.path)));
    await reopened.unlock(_password);
    expect(reopened.error, isNull);
    reopened.selectConversation(selected!);
    expect(reopened.messages, hasLength(2));
    expect(notifications, greaterThan(5));
  });

  test('图片走真实媒体加密投影并可在锁定重开后读取', () async {
    final first = controller('image_owner');
    await first.create(
      name: 'image_owner',
      displayName: '图片测试',
      password: _password,
    );
    await first.createSpace('图片频道');
    final room = first.selectedConversationId!;
    final png = await File('assets/probe.png').readAsBytes();
    await first.sendImage(png, 'probe.png');
    expect(first.error, isNull);
    expect(first.messages, hasLength(1));
    expect(first.messages.single.parts.single['data'], contains('attachment'));
    final parts = await first.projectMessage(first.messages.single);
    final data = parts.single['data'] as Map;
    expect(data['mime'], 'image/webp');
    final loaded = await first.loadMedia(data['file_id'] as String);
    expect(base64Decode(loaded['data'] as String), isNotEmpty);
    expect(loaded['mime'], 'image/webp');
    await first.lock();
    await first.unlock(_password);
    first.selectConversation(room);
    final again = await first.projectMessage(first.messages.single);
    expect(
      await first.loadMedia((again.single['data'] as Map)['file_id'] as String),
      loaded,
    );
  });

  test('node.changes 通知刷新；锁定排在已有发送后，无活动文件句柄竞争', () async {
    final first = controller('queued');
    await first.create(name: 'queued', displayName: '队列', password: _password);
    await first.createSpace('队列频道');
    final selected = first.selectedConversationId!;
    var changes = 0;
    first.addListener(() => changes++);
    await first.node!.execute(
      operation: 'message.send',
      params: {
        'conversation': selected,
        'parts': [
          {
            'type': 'text',
            'data': {'text': 'runtime直接变化'},
          },
        ],
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(changes, greaterThan(0));
    final send = first.sendText('关闭前落盘');
    final lock = first.lock();
    await Future.wait([send, lock]);
    await first.unlock(_password);
    first.selectConversation(selected);
    expect(first.messages, hasLength(2));
    await first.sendText('');
    expect(first.error, contains('[bad_request]'));
    expect(first.messages, hasLength(2));
  });

  test('Git factory 错误只显示固定码，恢复原资料离线节点', () async {
    final first = controller(
      'factory',
      gitFactory: (_, _, _) async {
        throw const GitSyncException(
          'git_failed',
          '/secret/path?token=do-not-leak',
        );
      },
    );
    await first.create(name: 'factory', displayName: '工厂', password: _password);
    await first.createSpace('恢复频道');
    await first.configureGit('https://invalid.example/repo.git');
    expect(first.isOpen, isTrue);
    expect(first.error, 'Git 同步失败，请检查仓库与凭据 [git_failed]');
    expect(first.error, isNot(contains('secret')));
    expect(first.gitRemote, isNull);
    await first.sendText('恢复离线后可发送');
    expect(first.error, isNull);
    expect(first.messages, hasLength(1));
  });

  test('两位真实用户经本地 bare Git 入驻、加入频道并双向同步', () async {
    final bare = Directory('${root.path}/remote.git');
    final init = await Process.run('git', ['init', '--bare', bare.path]);
    expect(init.exitCode, 0, reason: '本地 Git 测试仓库初始化必须成功');
    final alice = controller('a');
    await alice.create(name: 'alice', displayName: '小甲', password: _password);
    final bob = controller('b');
    await bob.create(
      name: 'bob',
      displayName: '小乙',
      password: _password,
      communityJson: alice.exportCommunity(),
      fingerprint: await alice.exportFingerprint(),
    );
    expect(bob.admitted, isFalse);
    expect(bob.conversations, isEmpty);
    await alice.admit(await bob.exportJoinRequest());
    expect(alice.error, isNull);
    await alice.configureGit(bare.path);
    expect(alice.error, isNull);
    await alice.sync();
    expect(alice.error, isNull);
    await bob.configureGit(bare.path);
    await bob.sync();
    expect(bob.error, isNull);
    expect(bob.admitted, isTrue);
    await alice.createSpace('共享频道');
    final space = alice.spaces.single;
    await alice.sync();
    await bob.sync();
    expect(bob.spaces.single.id, space.id);
    expect(bob.conversations, isEmpty);
    await bob.joinSpace(space.id);
    expect(bob.error, isNull);
    expect(bob.selectedConversationId, space.defaultRoomId);
    await bob.sync();
    await alice.sync();
    await bob.sync(); // 获取 owner 对入驻范围生成的当期密钥公告。
    await bob.sendText('来自小乙');
    expect(bob.error, isNull);
    await bob.sync();
    await alice.sync();
    expect(alice.error, isNull);
    alice.selectConversation(space.defaultRoomId);
    expect(alice.messages.single.senderId, bob.ownerId);
    await alice.sendText('来自小甲');
    await alice.sync();
    await bob.sync();
    expect(bob.error, isNull);
    expect(bob.messages, hasLength(2));
    await bob.startDirect(alice.ownerId);
    expect(bob.error, contains('[forbidden]'));
    expect(bob.selectedConversationId, space.defaultRoomId);
    await bob.addFriend(alice.ownerId);
    expect(bob.error, isNull);
    await bob.startDirect(alice.ownerId);
    expect(bob.error, isNull);
    expect(bob.selectedConversation!.kind, 'direct');
    await bob.sendText('显式好友之后的私聊');
    expect(bob.error, isNull);
    expect(bob.messages, hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
