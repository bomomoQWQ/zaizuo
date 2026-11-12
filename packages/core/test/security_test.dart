import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';

const fast = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
const password = 'R7!mK2@wX9#vT4%p';
void main() {
  test('账号规则、完整哈希编号与昵称显示字符', () async {
    final a = await Identity.create('Alice_7');
    final b = await Identity.create('alice_7');
    expect(a.public.accountId, b.public.accountId);
    expect(a.public.accountId.length, 64);
    expect(
        () => normalizeAccountName('abcdefghijklmnop'), throwsFormatException);
    expect(() => normalizeAccountName('../evil'), throwsFormatException);
    validateDisplayName('👨‍👩‍👧‍👦');
    expect(() => validateDisplayName('一二三四五六七八九十一二三四五'), throwsFormatException);
    expect(() => validatePassword('alice', 'PasswordAAAAA'),
        throwsFormatException);
    expect(() => validatePassword('alice', 'aliceZx123456!'),
        throwsFormatException);
  });
  test('钥匙箱用密码解锁，密码错误与修改头拒绝', () async {
    final a = await Identity.create('alice');
    final vault = await PasswordVault.seal(a, password, parameters: fast);
    expect(canonicalJson(vault).contains(await a.sign('private')), isFalse);
    final restored = await PasswordVault.open(vault, password);
    expect(restored.public.toJson(), a.public.toJson());
    await expectLater(
        PasswordVault.open(vault, 'WrongStrong!Z97'), throwsA(anything));
    await expectLater(
        PasswordVault.open(
            {...vault, 'salt': base64Encode(secureBytes(16))}, password),
        throwsA(anything));
    final changed = jsonObject(canonicalJson(vault));
    (changed['kdf'] as Map<String, dynamic>)['memory_kib'] = 1 << 30;
    await expectLater(
        PasswordVault.open(changed, password), throwsFormatException);
  });
  test('扫码因素不在仓库里，密码独自不能解锁', () async {
    final owner = await Identity.create('alice');
    final factor = secureBytes(32);
    final vault = await PasswordVault.seal(owner, password,
        secondFactor: factor, parameters: fast);
    await expectLater(PasswordVault.open(vault, password), throwsStateError);
    await expectLater(
        PasswordVault.open(vault, password, secondFactor: secureBytes(32)),
        throwsA(anything));
    final device = await DeviceCredentials.create();
    final request = await PairingRequest.create(device,
        accountId: owner.public.accountId, communityId: 'test-community');
    final scanned = PairingRequest.decode(request.encode());
    expect(scanned.body, request.body);
    final approver = PairingApprover();
    final response = await approver.approve(scanned, owner, factor,
        communityId: 'test-community');
    final receiver = PairingReceiver();
    final recovered =
        await receiver.accept(response, request, device, owner.public);
    expect(recovered, factor);
    expect(
        (await PasswordVault.open(vault, password, secondFactor: recovered))
            .public
            .accountId,
        owner.public.accountId);
    await expectLater(receiver.accept(response, request, device, owner.public),
        throwsStateError);
    await expectLater(
        approver.approve(scanned, owner, factor, communityId: 'test-community'),
        throwsStateError);
  });
  test('过期和跨账号扫码请求拒绝', () async {
    final owner = await Identity.create('alice');
    final other = await Identity.create('bob');
    final device = await DeviceCredentials.create();
    final request = await PairingRequest.create(device,
        accountId: other.public.accountId, communityId: 'community');
    await expectLater(
        PairingApprover()
            .approve(request, owner, secureBytes(32), communityId: 'community'),
        throwsStateError);
    final expired = await PairingRequest.create(device,
        accountId: owner.public.accountId,
        communityId: 'community',
        now: DateTime.now().subtract(const Duration(hours: 1)));
    await expectLater(
        PairingApprover()
            .approve(expired, owner, secureBytes(32), communityId: 'community'),
        throwsFormatException);
  });
  test('会话密钥分发，非收件人无法解，独立新epoch隔离旧成员', () async {
    final alice = await Identity.create('alice');
    final bob = await Identity.create('bob');
    final key = ConversationKey.generate('room-a', 1);
    final wrapped = await key.wrapFor(alice.public,
        sender: alice, communityId: 'community');
    expect(
        (await ConversationKey.unwrap(wrapped, alice,
                authorizedSender: alice.public, communityId: 'community'))
            .bytes,
        key.bytes);
    await expectLater(
        ConversationKey.unwrap(wrapped, bob,
            authorizedSender: alice.public, communityId: 'community'),
        throwsStateError);
    final stolen = jsonObject(canonicalJson(wrapped));
    (stolen['body'] as Map<String, dynamic>)['recipient'] =
        bob.public.accountId;
    await expectLater(
        ConversationKey.unwrap(stolen, bob,
            authorizedSender: alice.public, communityId: 'community'),
        throwsA(anything));
    final fresh = ConversationKey.generate('room-a', 2);
    expect(fresh.bytes, isNot(key.bytes));
  });
  test('信任指纹固定仓库外，配置验签与防回退', () async {
    final owner = await Identity.create('alice');
    final stranger = await Identity.create('bob');
    final manifest =
        await CommunityManifest.create(owner, communityId: 'community');
    final pin = await manifest.fingerprint();
    await manifest.verify(pin);
    final next = await CommunityManifest.create(owner,
        communityId: 'community',
        revision: 2,
        previousHash: await objectHash(manifest.toJson()),
        accounts: [stranger.public]);
    await next.verify(pin, previous: manifest);
    await expectLater(manifest.verify(pin, previous: next), throwsStateError);
    final replacement =
        await CommunityManifest.create(stranger, communityId: 'community');
    await expectLater(replacement.verify(pin), throwsStateError);
    expect(
        manifest
            .invitation(repository: 'https://example.invalid/community.git')
            .contains('zaizuo://community/'),
        isTrue);
  });
  test('每设备链乱序补齐，篡改、错误会话、分叉拒绝', () async {
    final fixture = await setup();
    final device = fixture.device;
    final key = fixture.key;
    final first = await EncryptedEvent.create(
        communityId: 'community',
        device: device,
        key: key,
        sequence: 1,
        clock: 1,
        previous: null,
        body: {'text': '第一条'});
    final second = await EncryptedEvent.create(
        communityId: 'community',
        device: device,
        key: key,
        sequence: 2,
        clock: 10,
        previous: first.id,
        body: {'text': '第二条'});
    expect(await first.verify(device.certificate!), isTrue);
    expect(await first.decrypt(key), {'text': '第一条'});
    await expectLater(
        first.decrypt(ConversationKey.generate('other', 1)), throwsStateError);
    final changed = first.toJson();
    changed['ciphertext'] = base64Encode([1, 2, 3]);
    expect(await EncryptedEvent.fromJson(changed).verify(device.certificate!),
        isFalse);
    final index = EventIndex();
    expect(index.acceptVerified(second), isEmpty);
    expect(index.pendingCount, 1);
    expect(index.headSequence(first.origin), 0);
    expect(index.acceptVerified(first).map((e) => e.id), [first.id, second.id]);
    expect(index.acceptVerified(first), isEmpty);
    final fork = await EncryptedEvent.create(
        communityId: 'community',
        device: device,
        key: key,
        sequence: 2,
        clock: 20,
        previous: first.id,
        body: {'text': '分叉'});
    expect(() => index.acceptVerified(fork), throwsStateError);
  });
  test('真实文件日志flush/重启/游标/唯一写者与重复导入', () async {
    final f = await setup();
    final directory = await Directory.systemTemp.createTemp('zaizuo-core-');
    addTearDown(() => directory.delete(recursive: true));
    final store = await FileEventStore.open(directory, f.trust);
    final first = await store
        .append(device: f.device, key: f.key, body: {'text': '重启后可读'});
    final sync = await store.sync();
    expect((sync['events'] as List).length, 1);
    final cursor = sync['next_cursor'] as String;
    expect(await store.import(first), isFalse);
    await expectLater(
        FileEventStore.open(directory, f.trust), throwsStateError);
    await store.close();
    final reopened = await FileEventStore.open(directory, f.trust);
    expect(reopened.allEnvelopes.single.id, first.id);
    final second = await reopened
        .append(device: f.device, key: f.key, body: {'text': '新增'});
    final delta = await reopened.sync(cursor: cursor);
    expect(
        ((delta['events'] as List).single as Map)['header']['id'], second.id);
    expect(second.sequence, 2);
    await reopened.close();
  });
  test('未完成日志尾部拒绝继续写入，不静默丢弃', () async {
    final f = await setup();
    final directory = await Directory.systemTemp.createTemp('zaizuo-partial-');
    addTearDown(() => directory.delete(recursive: true));
    final store = await FileEventStore.open(directory, f.trust);
    await store.append(device: f.device, key: f.key, body: {'text': 'ok'});
    await store.close();
    final log = File('${directory.path}/events.jsonl');
    await log.writeAsString('{"partial":', mode: FileMode.append, flush: true);
    await expectLater(
        FileEventStore.open(directory, f.trust), throwsStateError);
    expect(await log.readAsString(), endsWith('{"partial":'));
  });
  test('会话密钥分发绑定授权发送者、签名、社区及上下文', () async {
    final owner = await Identity.create('alice');
    final receiver = await Identity.create('bob');
    final stranger = await Identity.create('charlie');
    final key = ConversationKey.generate('private-room', 1);
    final signed = await key.wrapFor(receiver.public,
        sender: owner, communityId: 'community');
    await expectLater(
        ConversationKey.unwrap(signed, receiver,
            authorizedSender: owner.public, communityId: 'other-community'),
        throwsStateError);
    final attack = await ConversationKey.generate('private-room', 1)
        .wrapFor(receiver.public, sender: stranger, communityId: 'community');
    await expectLater(
        ConversationKey.unwrap(attack, receiver,
            authorizedSender: owner.public, communityId: 'community'),
        throwsStateError);
    final forged = jsonObject(canonicalJson(attack));
    (forged['body'] as Map<String, dynamic>)['sender'] = owner.public.accountId;
    await expectLater(
        ConversationKey.unwrap(forged, receiver,
            authorizedSender: owner.public, communityId: 'community'),
        throwsStateError);
    for (final field in ['conversation', 'epoch']) {
      final changed = jsonObject(canonicalJson(signed));
      (changed['body'] as Map<String, dynamic>)[field] =
          field == 'epoch' ? 2 : 'other-room';
      await expectLater(
          ConversationKey.unwrap(changed, receiver,
              authorizedSender: owner.public, communityId: 'community'),
          throwsStateError);
    }
  });

  test('扫码请求和响应并发只接纳一次且检查目标账号', () async {
    final owner = await Identity.create('alice');
    final other = await Identity.create('bob');
    final device = await DeviceCredentials.create();
    final request = await PairingRequest.create(device,
        accountId: owner.public.accountId, communityId: 'community');
    final factor = secureBytes(32);
    final approver = PairingApprover();
    final first =
        approver.approve(request, owner, factor, communityId: 'community');
    await expectLater(
        approver.approve(request, owner, factor, communityId: 'community'),
        throwsStateError);
    final response = await first;
    final receiver = PairingReceiver();
    final accepted = receiver.accept(response, request, device, owner.public);
    await expectLater(receiver.accept(response, request, device, owner.public),
        throwsStateError);
    expect(await accepted, factor);
    final wrongCertificate = await device.authorize(other, 'community');
    final wrongBody = <String, dynamic>{
      'request_id': request.requestId,
      'request_hash': await objectHash(request.body),
      'certificate': wrongCertificate.toJson(),
      'factor': await wrapSecret(
          factor, readBase64(request.body, 'exchange', size: 32),
          context: 'zaizuo.pair.v1:${request.requestId}')
    };
    final wrongResponse = {
      'body': wrongBody,
      'signature': await other.sign(wrongBody)
    };
    await expectLater(
        PairingReceiver().accept(wrongResponse, request, device, other.public),
        throwsStateError);
  });

  test('扫码过期精确边界与失败响应不消耗有效重试', () async {
    final owner = await Identity.create('alice');
    final device = await DeviceCredentials.create();
    final now = DateTime.now().toUtc();
    final request = await PairingRequest.create(device,
        accountId: owner.public.accountId, communityId: 'community', now: now);
    expect(() => request.validate(now.add(const Duration(minutes: 5))),
        throwsFormatException);
    final response = await PairingApprover().approve(
        request, owner, secureBytes(32),
        communityId: 'community', now: now);
    final receiver = PairingReceiver();
    final changed = jsonObject(canonicalJson(response));
    changed['signature'] = base64Encode(List<int>.filled(64, 0));
    await expectLater(
        receiver.accept(changed, request, device, owner.public, now: now),
        throwsStateError);
    expect(
        (await receiver.accept(response, request, device, owner.public,
                now: now))
            .length,
        32);
  });

  test('签名配置嵌套数据不可变，调用方不能验签后改settings', () async {
    final owner = await Identity.create('alice');
    final settings = <String, dynamic>{
      'nested': {'enabled': true},
      'list': [1]
    };
    final manifest = await CommunityManifest.create(owner, settings: settings);
    (settings['nested'] as Map<String, dynamic>)['enabled'] = false;
    expect(((manifest.body['settings'] as Map)['nested'] as Map)['enabled'],
        isTrue);
    expect(
        () => ((manifest.body['settings'] as Map)['nested'] as Map)['enabled'] =
            false,
        throwsUnsupportedError);
    expect(
        () => ((manifest.body['accounts'] as List).first as Map)['name'] =
            'changed',
        throwsUnsupportedError);
    await manifest.verify(await manifest.fingerprint());
    final json = jsonObject(canonicalJson(manifest.toJson()));
    final imported = CommunityManifest.fromJson(json);
    ((json['body'] as Map)['settings'] as Map)['changed'] = true;
    await imported.verify(await imported.fingerprint());
  });

  test('设备证书未来时间边界和公开信任映射不能绕过授权入口', () async {
    final owner = await Identity.create('alice');
    final device = await DeviceCredentials.create();
    final now = DateTime.now().toUtc();
    final atBoundary = await device.authorize(owner, 'community',
        now: now.add(const Duration(minutes: 5)));
    expect(
        await atBoundary.verify(owner.public, 'community', now: now), isTrue);
    final future = await device.authorize(owner, 'community',
        now: now.add(const Duration(minutes: 5, milliseconds: 1)));
    expect(await future.verify(owner.public, 'community', now: now), isFalse);
    final trust = TrustStore('community')..trustAccount(owner.public);
    expect(() => trust.devices[future.id] = future, throwsUnsupportedError);
    expect(() => trust.accounts.clear(), throwsUnsupportedError);
    final malformedBody = Map<String, dynamic>.of(atBoundary.body)
      ..['signing'] = 'AQID';
    final malformed =
        DeviceCertificate(malformedBody, await owner.sign(malformedBody));
    expect(
        await malformed.verify(owner.public, 'community', now: now), isFalse);
  });

  test('同设备公钥不能通过第二账号证书静默替换原授权', () async {
    final owner = await Identity.create('alice');
    final other = await Identity.create('bob');
    final device = await DeviceCredentials.create();
    final certificate = await device.authorize(owner, 'community');
    final trust = TrustStore('community')
      ..trustAccount(owner.public)
      ..trustAccount(other.public);
    await trust.authorizeDevice(certificate);
    final reassigned = await device.authorize(other, 'community');
    await expectLater(trust.authorizeDevice(reassigned), throwsStateError);
    expect(trust.devices[certificate.id]!.accountId, owner.public.accountId);
  });

  test('未知/非正初始配置版本即使有根签名也拒绝', () async {
    final owner = await Identity.create('alice');
    final valid =
        await CommunityManifest.create(owner, communityId: 'community');
    final body = jsonObject(canonicalJson(valid.body))..['revision'] = 0;
    final malformed = CommunityManifest.fromJson(
        {'body': body, 'signature': await owner.sign(body)});
    await expectLater(
        malformed.verify(await valid.fingerprint()), throwsFormatException);
  });

  test('同ID待补事件不能覆盖内容，重复待补事件幂等', () async {
    final fixture = await setup();
    final pending = await EncryptedEvent.create(
        communityId: 'community',
        device: fixture.device,
        key: fixture.key,
        sequence: 2,
        clock: 2,
        previous: randomId(),
        body: {'text': 'one'});
    final index = EventIndex();
    expect(index.acceptVerified(pending), isEmpty);
    expect(index.acceptVerified(pending), isEmpty);
    expect(index.pendingCount, 1);
    final conflict = await EncryptedEvent.create(
        communityId: 'community',
        device: fixture.device,
        key: fixture.key,
        sequence: 3,
        clock: 3,
        previous: randomId(),
        eventId: pending.id,
        body: {'text': 'different'});
    expect(() => index.acceptVerified(conflict), throwsStateError);
    expect(index.pendingCount, 1);
  });

  test('持久化未来毒事件隔离，不阻塞正确缺口、恢复和游标', () async {
    final fixture = await setup();
    final root = await Directory.systemTemp.createTemp('zaizuo-poison-');
    addTearDown(() => root.delete(recursive: true));
    var store = await FileEventStore.open(root, fixture.trust);
    final first = await EncryptedEvent.create(
        communityId: 'community',
        device: fixture.device,
        key: fixture.key,
        sequence: 1,
        clock: 1,
        previous: null,
        body: {'n': 1});
    final poison = await EncryptedEvent.create(
        communityId: 'community',
        device: fixture.device,
        key: fixture.key,
        sequence: 2,
        clock: 2,
        previous: randomId(),
        body: {'n': 99});
    expect(await store.import(poison), isTrue);
    expect((await store.sync())['events'], isEmpty);
    expect(await store.import(first), isTrue);
    expect(store.index.headSequence(first.origin), 1);
    expect(store.index.quarantined[poison.id], 'invalid_chain_link');
    final cursor = (await store.sync())['next_cursor'] as String;
    await store.close();
    store = await FileEventStore.open(root, fixture.trust);
    final second = await EncryptedEvent.create(
        communityId: 'community',
        device: fixture.device,
        key: fixture.key,
        sequence: 2,
        clock: 2,
        previous: first.id,
        body: {'n': 2});
    expect(await store.import(second), isTrue);
    final delta = await store.sync(cursor: cursor);
    expect(
        ((delta['events'] as List).single as Map)['header']['id'], second.id);
    expect(store.allEnvelopes.length,
        3); // poison retained, never silently deleted
    expect(store.index.quarantined.containsKey(poison.id), isTrue);
    await store.close();
  });

  test('日志写入失败后fail-stop，不能在不确定尾部继续确认', () async {
    final fixture = await setup();
    final root = await Directory.systemTemp.createTemp('zaizuo-failstop-');
    addTearDown(() => root.delete(recursive: true));
    final store = await FileEventStore.open(root, fixture.trust);
    addTearDown(store.close);
    // No log exists yet: a directory at that exact filename forces the real
    // append to fail without relying on platform-specific ACLs or a disk fill.
    final blockedPath = Directory(store.logFile.path);
    await blockedPath.create();
    await expectLater(
        store.append(device: fixture.device, key: fixture.key, body: {'n': 1}),
        throwsA(isA<FileSystemException>()));
    expect(
        blockedPath.path, '${root.path}${Platform.pathSeparator}events.jsonl');
    await blockedPath.delete();
    await expectLater(
        store.append(device: fixture.device, key: fixture.key, body: {'n': 2}),
        throwsStateError);
    await expectLater(store.sync(), throwsStateError);
    expect(store.allEnvelopes, isEmpty);
    expect(await store.logFile.exists(), isFalse);
  });

  test('关闭立即拒绝新写入且并发close共享Future', () async {
    final fixture = await setup();
    final root = await Directory.systemTemp.createTemp('zaizuo-close-');
    addTearDown(() => root.delete(recursive: true));
    final store = await FileEventStore.open(root, fixture.trust);
    final first =
        store.append(device: fixture.device, key: fixture.key, body: {'n': 1});
    final closing = store.close();
    expect(identical(closing, store.close()), isTrue);
    await expectLater(
        store.append(device: fixture.device, key: fixture.key, body: {'n': 2}),
        throwsStateError);
    await first;
    await closing;
    final reopened = await FileEventStore.open(root, fixture.trust);
    expect(reopened.allEnvelopes.length, 1);
    await reopened.close();
  });

  test('跨进程OS独占锁拒绝第二写者，不依赖静态Set', () async {
    final fixture = await setup();
    final root = await Directory.systemTemp.createTemp('zaizuo-process-lock-');
    addTearDown(() => root.delete(recursive: true));
    final packageConfig =
        File('.dart_tool/package_config.json').absolute.uri.toString();
    final script = File('${root.path}${Platform.pathSeparator}holder.dart');
    await script.writeAsString('''
import 'dart:io';
import 'package:zaizuo_core/zaizuo_core.dart';
Future<void> main(List<String> args) async {
  final store = await FileEventStore.open(Directory(args[0]), TrustStore('community'));
  stdout.writeln('locked');
  await stdin.first;
  await store.close();
}
''', flush: true);
    final holder = await Process.start(Platform.resolvedExecutable,
        ['--packages=$packageConfig', script.path, root.path],
        runInShell: false);
    final stderrDone = holder.stderr.drain<void>();
    final output = StreamIterator<String>(
        utf8.decoder.bind(holder.stdout).transform(const LineSplitter()));
    try {
      expect(
          await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      expect(output.current, 'locked');
      await expectLater(
          FileEventStore.open(root, fixture.trust), throwsA(anything));
      holder.stdin.writeln('release');
      await holder.stdin.close();
      expect(await holder.exitCode.timeout(const Duration(seconds: 10)), 0);
      await stderrDone;
      final reopened = await FileEventStore.open(root, fixture.trust);
      await reopened.close();
    } finally {
      holder.kill();
      await holder.exitCode.timeout(const Duration(seconds: 10));
      await output.cancel();
      await stderrDone;
    }
  });

  test('省电仅调度策略，退避且允许手动', () {
    expect(PowerPolicy.manual.nextDelay(foreground: false, failures: 0),
        Duration.zero);
    expect(PowerPolicy.balanced.nextDelay(foreground: false, failures: 0),
        const Duration(minutes: 15));
    expect(PowerPolicy.saver.nextDelay(foreground: true, failures: 2),
        const Duration(minutes: 4));
  });
}

Future<
    ({
      Identity identity,
      DeviceCredentials device,
      ConversationKey key,
      TrustStore trust
    })> setup() async {
  final identity = await Identity.create('alice');
  final device = await DeviceCredentials.create();
  await device.authorize(identity, 'community');
  final trust = TrustStore('community')..trustAccount(identity.public);
  await trust.authorizeDevice(device.certificate!);
  return (
    identity: identity,
    device: device,
    key: ConversationKey.generate('room-a', 1),
    trust: trust
  );
}
