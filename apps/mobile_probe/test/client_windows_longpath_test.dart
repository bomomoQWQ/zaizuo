import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_mobile_probe/client_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Windows portable-length root syncs again after first device publication and reopens',
    () async {
      final temp = await Directory.systemTemp.createTemp('zlp-');
      final root = Directory(await temp.resolveSymbolicLinks());
      // Mirrors the user's portable dir + hashed managed Git dir. Incoming refs
      // add a nonce and a 64-character device id, exceeding MAX_PATH after a
      // first successful device push. No registry/global Git settings are changed.
      final clientRoot = Directory(
        '${root.path}/${'p' * (89 - root.path.length - 1)}',
      );
      final remote = Directory('${root.path}/r.git');
      final init = await Process.run(
        'git',
        ['init', '--bare', '--initial-branch=main', remote.path],
        environment: GitCliBackend.cleanEnvironment(),
        includeParentEnvironment: false,
      );
      expect(init.exitCode, 0);
      const fast = KdfParameters(memoryKiB: 32, iterations: 1);
      var client = ClientController(clientRoot, parameters: fast);
      try {
        await client.create(
          name: 'longpath',
          displayName: '长路径测试',
          password: 'Q8!FixtureR9#Local',
        );
        await client.createSpace('长路径的公开空间');
        final room = client.selectedConversationId!;
        await client.configureGit(remote.path);
        expect(client.error, isNull);
        final worktree = client.node!.git!.worktree.path;
        expect(worktree.length, greaterThanOrEqualTo(152));
        final refPath =
            '$worktree/.git/refs/zaizuo-incoming/${'a' * 24}/${'b' * 64}.lock';
        expect(refPath.length, greaterThan(260));
        await client.sync();
        expect(
          client.error,
          isNull,
          reason: 'the readback fetch after first publication must work',
        );
        expect(client.node!.completedSyncs, 1);
        client.selectConversation(room);
        await client.sendText('首次成功后再次发送必须能同步');
        expect(client.error, isNull);
        await client.sync();
        expect(client.error, isNull);
        expect(client.node!.completedSyncs, 2);
        expect(client.messages, hasLength(1));
        // Keep the exact existing managed config contract; longpaths is process-
        // scoped, never patched into on-disk config and never changes pins.
        final config = await File('$worktree/.git/config').readAsString();
        expect(config, isNot(contains('longpaths')));
        expect(config, isNot(contains('credential')));
        await client.shutdown();
        client = ClientController(clientRoot, parameters: fast);
        await client.unlock('Q8!FixtureR9#Local');
        client.selectConversation(room);
        expect(client.messages, hasLength(1));
        await client.configureGit(remote.path);
        await client.sync();
        expect(client.error, isNull);
        client.selectConversation(room);
        expect(
          client.messages,
          hasLength(1),
          reason: 'idempotent sync must not duplicate messages',
        );
      } finally {
        await client.shutdown();
        await root.delete(
          recursive: true,
        ); // Only this test-created isolated root.
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
