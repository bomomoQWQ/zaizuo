import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_onebot/zaizuo_onebot.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

const _password = 'Integration!42#NoRealAccount';
const _tinyKdf = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
const _token = 'test-onebot-persistence-only-0123456789abcdef';
const _room = 'integration-lobby#main';
const _bot = 'integration-alice-bot';
const _receiverBot = 'integration-bob-bot';
const _anotherBot = 'integration-alice-other-bot';

void main() {
  test('真实HTTP11/WS12发送落密文日志，立即重开profile/store/replica与磁盘IDmap后保持同一原消息',
      () async {
    final fixture = await _Profiles.create();
    addTearDown(fixture.close);
    final running = await _Running.open(fixture.alice, fixture.aliceReplica);
    addTearDown(running.close);
    final groups = await _http(running.port, 11, 'get_group_list');
    _ok(groups);
    final mappedGroup = (groups['data'] as List).singleWhere(
            (value) => value['group_name'] == 'Persistence lobby')['group_id']
        as int;
    final ws = await _WsClient.connect(running.port, 12);
    addTearDown(ws.close);
    const firstText = 'HTTP11 durable [not plaintext in event log]';
    final first = await _http(running.port, 11, 'send_group_msg', {
      'group_id': mappedGroup,
      'message': firstText,
    }, {
      'json': [11, true]
    });
    _ok(first);
    expect(first['echo'], {
      'json': [11, true]
    });
    final int firstMapped = first['data']['message_id'] as int;
    final firstNative = running.ids.decode('message', firstMapped)!;
    final persistedAfterHttp = OneBotIdMap.loadState(
        await fixture.alice.file('onebot-ids.json').readAsString());
    // 响应已经返回时同步onChanged必须已flush映射，不靠退出时再保存。
    expect(persistedAfterHttp.decode('message', firstMapped), firstNative);
    final beforeWs = fixture.aliceStore.allEnvelopes.length;
    const secondText = 'WS12 durable native message';
    ws.send({
      'action': 'send_message',
      'params': {
        'detail_type': 'group',
        'group_id': _room,
        'message': secondText,
      },
      'echo': 'ws12-durable'
    });
    final second = await ws.next((value) => value['echo'] == 'ws12-durable');
    _ok(second);
    final secondNative = second['data']['message_id'] as String;
    expect(fixture.aliceStore.allEnvelopes.length, beforeWs + 1);
    final secondMapped = running.ids.encode('message', secondNative);
    final expectedRecords = <String, Map<String, dynamic>>{
      firstNative:
          fixture.aliceReplica.service.state.messages[firstNative]!.toJson(),
      secondNative:
          fixture.aliceReplica.service.state.messages[secondNative]!.toJson(),
    };
    expect(expectedRecords.values.map((record) => record['senderId']),
        everyElement(_bot));
    final last = fixture.aliceStore.allEnvelopes.last;
    expect(last.conversation, _room);
    final body = await last.decrypt(fixture.roomKey);
    expect(body['actor'], _bot);
    expect(body['operation'], 'message.send');
    expect(body['params']['parts'].single['data']['text'], secondText);
    final encryptedLog = await fixture.aliceStore.logFile.readAsString();
    expect(encryptedLog, isNot(contains(firstText)));
    expect(encryptedLog, isNot(contains(secondText)));
    expect(encryptedLog.endsWith('\n'), isTrue);

    // 不再saveState/导出映射：收到成功后立刻关闭，重开只能靠已flush持久化。
    await ws.close();
    await running.close();
    await fixture.closeAlice();
    final reopened = await LocalProfile.open(fixture.alice.root, _password);
    final (store2, replica2) = await reopened.replica();
    addTearDown(() async {
      await replica2.close();
      await store2.close();
    });
    expect(replica2.rejected, isEmpty);
    for (final entry in expectedRecords.entries) {
      final record = replica2.service
          .message(actor: replica2.service.actor(_bot), messageId: entry.key);
      expect(record.toJson(), entry.value);
    }
    final restored = await _Running.open(reopened, replica2);
    addTearDown(restored.close);
    expect(restored.ids.decode('message', firstMapped), firstNative);
    expect(restored.ids.decode('message', secondMapped), secondNative);
    for (final pair in [
      (firstMapped, firstNative),
      (secondMapped, secondNative)
    ]) {
      final result =
          await _http(restored.port, 11, 'get_msg', {'message_id': pair.$1});
      _ok(result);
      expect(result['data']['message_id'], pair.$1);
      expect(result['data']['sender']['user_id'],
          restored.ids.encode('user', _bot));
      expect(result['data']['message'], expectedRecords[pair.$2]!['parts']);
      // 12返回过的原生ID与11映射均指向重放出的同一MessageRecord。
      expect(restored.ids.decode('message', result['data']['message_id']),
          pair.$2);
    }
    final afterRestart12 = await _http(restored.port, 12, 'get_self_info');
    _ok(afterRestart12);
    expect(afterRestart12['data']['user_id'], _bot);
    final afterRestart11 = await _http(restored.port, 11, 'get_login_info');
    _ok(afterRestart11);
    expect(
        afterRestart11['data']['user_id'], restored.ids.encode('user', _bot));
    expect(store2.allEnvelopes.length, fixture.aliceStore.allEnvelopes.length);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('固定bot拒绝self/owner冒用、无好友私聊发送与owner-only私聊读取，不新增加密事件', () async {
    final fixture = await _Profiles.create();
    addTearDown(fixture.close);
    final running = await _Running.open(fixture.alice, fixture.aliceReplica);
    addTearDown(running.close);
    final owner = fixture.alice.identity.public.accountId;
    final other = fixture.bob.identity.public.accountId;
    // 私聊只属于两个主账户，bot不能继承owner历史读取权限。
    await fixture.ownerCommand('friend.add', {'target': other});
    final direct =
        await fixture.ownerCommand('direct.create', {'target': other});
    final ownerConversation = (direct['result'] as Map)['id'] as String;
    await fixture.aliceReplica.ensureConversationKey(ownerConversation);
    fixture.alice.keys
      ..clear()
      ..addAll(fixture.aliceReplica.keys);
    await fixture.alice
        .savePrivate(seed: fixture.alice.seed, keys: fixture.alice.keys);
    final secret = await fixture.aliceReplica.execute(
        actorId: owner,
        operation: 'message.send',
        conversation: ownerConversation,
        params: {
          'conversation': ownerConversation,
          'parts': _text('owner-only private secret'),
        });
    final secretId = (secret['result'] as Map)['id'] as String;
    final mappedSecret = running.ids.encode('message', secretId);
    final ws = await _WsClient.connect(running.port, 12);
    addTearDown(ws.close);
    final count = fixture.aliceStore.allEnvelopes.length;
    for (final selfId in [owner, _anotherBot, _receiverBot]) {
      final result = await _http(
          running.port,
          12,
          'send_message',
          {
            'detail_type': 'group',
            'group_id': _room,
            'message': 'must not impersonate',
          },
          null,
          {'platform': 'zaizuo', 'user_id': selfId});
      expect(result['retcode'], 10102);
    }
    ws.send({
      'action': 'get_status',
      'params': {},
      'self': {'platform': 'zaizuo', 'user_id': owner},
      'echo': 'wrong-owner'
    });
    expect(
        (await ws.next((value) => value['echo'] == 'wrong-owner'))['retcode'],
        10102);
    final v11Self = await _http(running.port, 11, 'get_login_info', {
      'self_id': running.ids.encode('user', owner),
    });
    expect(v11Self['retcode'], 1403);
    final senderOverride = await _http(running.port, 12, 'send_message', {
      'detail_type': 'group',
      'group_id': _room,
      'message': 'blocked',
      'actor_id': owner,
    });
    expect(senderOverride['retcode'], 10004);
    final ownerRead =
        await _http(running.port, 11, 'get_msg', {'message_id': mappedSecret});
    expect(ownerRead['retcode'], 1403);
    // 先持久化解除owner好友；bot不能使用“共享群”绕过人类好友要求。
    await fixture.ownerCommand('friend.remove', {'target': other});
    final afterRemove = fixture.aliceStore.allEnvelopes.length;
    final deniedPrivate12 = await _http(running.port, 12, 'send_message', {
      'detail_type': 'private',
      'user_id': other,
      'message': 'private denied',
    });
    expect(deniedPrivate12['retcode'], 35001);
    final deniedPrivate11 = await _http(running.port, 11, 'send_private_msg', {
      'user_id': running.ids.encode('user', other),
      'message': 'private denied11',
    });
    expect(deniedPrivate11['retcode'], 1403);
    expect(fixture.aliceStore.allEnvelopes.length, afterRemove);
    expect(afterRemove, count + 1);
    expect(
        fixture.aliceReplica.service.state.messages.values
            .where((message) => message.senderId == _bot),
        isEmpty);
    expect(fixture.aliceReplica.rejected, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('真实加密sendHandler在append前及完成前不提前返回成功，关闭store导致失败而非伪持久化', () async {
    final fixture = await _Profiles.create();
    addTearDown(fixture.close);
    final entered = Completer<void>();
    final appendAllowed = Completer<void>();
    final appended = Completer<void>();
    final responseAllowed = Completer<void>();
    final running = await _Running.open(fixture.alice, fixture.aliceReplica,
        beforeSend: () async {
      entered.complete();
      await appendAllowed.future;
    }, afterSend: () async {
      appended.complete();
      await responseAllowed.future;
    });
    addTearDown(() async {
      if (!appendAllowed.isCompleted) appendAllowed.complete();
      if (!responseAllowed.isCompleted) responseAllowed.complete();
      await running.close();
    });
    final before = fixture.aliceStore.allEnvelopes.length;
    final pending = _http(running.port, 12, 'send_message', {
      'detail_type': 'group',
      'group_id': _room,
      'message': 'durability-gated',
    });
    var responded = false;
    unawaited(pending.then<void>((_) {
      responded = true;
    }));
    await entered.future.timeout(const Duration(seconds: 3));
    expect(responded, isFalse);
    expect(fixture.aliceStore.allEnvelopes.length, before);
    expect(fixture.aliceReplica.service.state.messages, isEmpty);
    appendAllowed.complete();
    await appended.future.timeout(const Duration(seconds: 3));
    expect(responded, isFalse);
    expect(fixture.aliceStore.allEnvelopes.length, before + 1);
    expect((await fixture.aliceStore.logFile.readAsString()).endsWith('\n'),
        isTrue);
    responseAllowed.complete();
    _ok(await pending);
    await running.close();
    // 仅关闭真实磁盘store；replica与OneBot不mock、不提前报成功。
    await fixture.aliceStore.close();
    final failing = await _Running.open(fixture.alice, fixture.aliceReplica);
    addTearDown(failing.close);
    final failed = await _http(failing.port, 12, 'send_message', {
      'detail_type': 'group',
      'group_id': _room,
      'message': 'cannot append closed log',
    });
    expect(failed['status'], 'failed');
    expect(failed['retcode'], isNot(0));
    expect(fixture.aliceStore.allEnvelopes.length, before + 1);
    expect(fixture.aliceReplica.service.state.messages, hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('接收端真实store.import先持久化，replica.refresh后才向messages/WS与独立轮询发布一次',
      () async {
    final fixture = await _Profiles.create();
    addTearDown(fixture.close);
    final receiver = await _Running.open(fixture.bob, fixture.bobReplica,
        botId: _receiverBot);
    addTearDown(receiver.close);
    final ws = await _WsClient.connect(receiver.port, 12);
    addTearDown(ws.close);
    await ws.next((value) => value['detail_type'] == 'connect');
    await ws.next((value) => value['detail_type'] == 'status_update');
    final received = <MessageRecord>[];
    final subscription = fixture.bobReplica.messages.listen(received.add);
    addTearDown(subscription.cancel);
    final sent = await fixture.aliceReplica.execute(
        actorId: _bot,
        operation: 'message.send',
        conversation: _room,
        params: {
          'conversation': _room,
          'parts': _text('sync-import-then-refresh'),
        });
    final messageId = (sent['result'] as Map)['id'] as String;
    final eventId = sent['event_id'] as String;
    final event = fixture.aliceStore.allEnvelopes
        .singleWhere((value) => value.id == eventId);
    expect(await fixture.bobStore.import(event), isTrue);
    expect(fixture.bobStore.allEnvelopes.any((value) => value.id == eventId),
        isTrue);
    expect(await fixture.bobStore.logFile.readAsString(), contains(eventId));
    expect(fixture.bobReplica.service.state.messages.containsKey(messageId),
        isFalse);
    expect(received, isEmpty);
    expect(ws.buffered.where((value) => value['message_id'] == messageId),
        isEmpty);
    final before = await _http(receiver.port, 12, 'get_latest_events');
    _ok(before);
    expect(before['data'], isEmpty);
    final incoming = ws.next((value) =>
        value['type'] == 'message' && value['message_id'] == messageId);
    await fixture.bobReplica.refresh();
    final delivered = await incoming;
    expect(delivered['self'], {'platform': 'zaizuo', 'user_id': _receiverBot});
    expect(delivered['user_id'], _bot);
    expect(delivered['message'].single['data']['text'],
        'sync-import-then-refresh');
    expect(received.map((message) => message.id), [messageId]);
    final actual = fixture.bobReplica.service.message(
        actor: fixture.bobReplica.service.actor(_receiverBot),
        messageId: messageId);
    expect(actual.toJson(), (sent['result'] as Map<String, dynamic>));
    final polled = await _http(receiver.port, 12, 'get_latest_events');
    _ok(polled);
    expect(polled['data'].single['message_id'], messageId);
    expect(polled['data'].single['id'], delivered['id']);
    expect(await fixture.bobStore.import(event), isFalse);
    await fixture.bobReplica.refresh();
    expect(received.map((message) => message.id), [messageId]);
    final noDuplicates = await _http(receiver.port, 12, 'get_latest_events');
    _ok(noDuplicates);
    expect(noDuplicates['data'], isEmpty);
    expect(fixture.bobReplica.rejected, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

List<Map<String, dynamic>> _text(String value) => [
      {
        'type': 'text',
        'data': {'text': value}
      },
    ];

class _Profiles {
  _Profiles(this.root, this.alice, this.bob, this.aliceStore, this.aliceReplica,
      this.bobStore, this.bobReplica, this.roomKey);
  final Directory root;
  final LocalProfile alice;
  final LocalProfile bob;
  final FileEventStore aliceStore;
  final EncryptedReplica aliceReplica;
  final FileEventStore bobStore;
  final EncryptedReplica bobReplica;
  final ConversationKey roomKey;
  bool _aliceClosed = false;
  bool _closed = false;

  static Future<_Profiles> create() async {
    final root =
        await Directory.systemTemp.createTemp('zaizuo-onebot-persistence-');
    final aRoot = Directory('${root.path}/alice');
    final bRoot = Directory('${root.path}/bob');
    await LocalProfile.initialize(aRoot,
        name: 'alice',
        displayName: 'Alice',
        password: _password,
        parameters: _tinyKdf);
    final alice = await LocalProfile.open(aRoot, _password);
    await LocalProfile.initialize(bRoot,
        name: 'bob',
        displayName: 'Bob',
        password: _password,
        community: alice.manifest,
        pinnedFingerprint: await alice.manifest.fingerprint(),
        parameters: _tinyKdf);
    final bob = await LocalProfile.open(bRoot, _password);
    final admitted = await alice.admit(await bob.joinRequest());
    await alice.acceptManifest(admitted);
    await bob.acceptManifest(admitted);
    final (aStore, aReplica) = await alice.replica();
    final (bStore, bReplica) = await bob.replica();
    final control = 'control:${alice.manifest.communityId}';
    final owner = alice.identity.public.accountId;
    Future<void> command(String operation, Map<String, dynamic> params) async {
      await aReplica.execute(
          actorId: owner,
          operation: operation,
          params: params,
          conversation: control);
    }

    await command('bot.register', {'id': _bot, 'display_name': 'Alice bot'});
    await command(
        'bot.register', {'id': _anotherBot, 'display_name': 'Other bot'});
    await command('space.create', {
      'id': 'integration-lobby',
      'title': 'Persistence lobby',
      'public_channel': true
    });
    await command('space.join', {'space': 'integration-lobby', 'bot_id': _bot});
    await command(
        'space.join', {'space': 'integration-lobby', 'bot_id': _anotherBot});
    for (final envelope in aStore.allEnvelopes) {
      await bStore.import(envelope);
    }
    await bReplica.refresh();
    await bReplica.execute(
        actorId: bob.identity.public.accountId,
        operation: 'bot.register',
        params: {'id': _receiverBot, 'display_name': 'Bob bot'},
        conversation: control);
    await bReplica.execute(
        actorId: bob.identity.public.accountId,
        operation: 'space.join',
        params: {'space': 'integration-lobby'},
        conversation: control);
    await bReplica.execute(
        actorId: bob.identity.public.accountId,
        operation: 'space.join',
        params: {'space': 'integration-lobby', 'bot_id': _receiverBot},
        conversation: control);
    for (final envelope in bStore.allEnvelopes) {
      await aStore.import(envelope);
    }
    await aReplica.refresh();
    // 当前合法成员产生新epoch公告和逐主体封装；receiver只经control密文导入学key。
    await aReplica.ensureConversationKey(_room);
    alice.keys
      ..clear()
      ..addAll(aReplica.keys);
    await alice.savePrivate(seed: alice.seed, keys: alice.keys);
    for (final envelope in aStore.allEnvelopes) {
      await bStore.import(envelope);
    }
    await bReplica.refresh();
    bob.keys
      ..clear()
      ..addAll(bReplica.keys);
    await bob.savePrivate(seed: bob.seed, keys: bob.keys);
    final roomKeys = aReplica.keys
        .where((key) => key.conversationId == _room)
        .toList()
      ..sort((a, b) => b.epoch.compareTo(a.epoch));
    final roomKey = roomKeys.first;
    final receivedKey = bReplica.keys.singleWhere(
        (key) => key.conversationId == _room && key.epoch == roomKey.epoch);
    expect(receivedKey.bytes, roomKey.bytes);
    expect(aReplica.rejected, isEmpty);
    expect(bReplica.rejected, isEmpty);
    return _Profiles(
        root, alice, bob, aStore, aReplica, bStore, bReplica, roomKey);
  }

  Future<Map<String, dynamic>> ownerCommand(
          String operation, Map<String, dynamic> params) =>
      aliceReplica.execute(
          actorId: alice.identity.public.accountId,
          operation: operation,
          params: params,
          conversation: 'control:${alice.manifest.communityId}');

  Future<void> closeAlice() async {
    if (_aliceClosed) return;
    _aliceClosed = true;
    await aliceReplica.close();
    await aliceStore.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await closeAlice();
    await bobReplica.close();
    await bobStore.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class _Running {
  _Running(this.backend, this.ids, this.projection, this.server);
  final DomainOneBotBackend backend;
  final OneBotIdMap ids;
  final OneBotProjection projection;
  final OneBotServer server;
  bool _closed = false;
  int get port => server.port;
  static Future<_Running> open(LocalProfile profile, EncryptedReplica replica,
      {String botId = _bot,
      Future<void> Function()? beforeSend,
      Future<void> Function()? afterSend}) async {
    final backend = DomainOneBotBackend(replica.service,
        botId: botId,
        serviceProvider: () => replica.service,
        messageStream: replica.messages,
        directResolver: (target) async {
          final result = await replica.execute(
              actorId: botId,
              operation: 'direct.create',
              params: {'target': target},
              conversation: 'control:${profile.manifest.communityId}');
          final id = (result['result'] as Map)['id'] as String;
          await replica.ensureConversationKey(id);
          profile.keys
            ..clear()
            ..addAll(replica.keys);
          await profile.savePrivate(seed: profile.seed, keys: profile.keys);
          return id;
        },
        sendHandler: (
            {required actor, required conversationId, required parts}) async {
          expect(actor.id, botId);
          expect(actor.isBot, isTrue);
          await beforeSend?.call();
          await replica.ensureConversationKey(conversationId);
          profile.keys
            ..clear()
            ..addAll(replica.keys);
          await profile.savePrivate(seed: profile.seed, keys: profile.keys);
          final result = await replica.execute(
              actorId: botId,
              operation: 'message.send',
              params: {'conversation': conversationId, 'parts': parts},
              conversation: conversationId);
          await afterSend?.call();
          return MessageRecord.fromJson(
              result['result'] as Map<String, dynamic>);
        });
    final file = profile.file('onebot-ids.json');
    void persist(Map<String, dynamic> state) {
      final temporary = File('${file.path}.tmp');
      temporary.writeAsStringSync(jsonEncode(state), flush: true);
      temporary.renameSync(file.path);
    }

    final ids = await file.exists()
        ? OneBotIdMap.loadState(await file.readAsString(), onChanged: persist)
        : OneBotIdMap(onChanged: persist);
    final projection = OneBotProjection(backend: backend, ids: ids);
    final server = OneBotServer(
        bindings: [OneBotBinding(token: _token, projection: projection)]);
    await server.start();
    return _Running(backend, ids, projection, server);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await server.close();
    await projection.close();
    await backend.close();
  }
}

Future<Map<String, dynamic>> _http(int port, int version, String action,
    [Map<String, dynamic> params = const {},
    Object? echo,
    Map<String, dynamic>? self]) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client
        .postUrl(Uri.parse('http://127.0.0.1:$port/onebot/v$version'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'action': action,
      'params': params,
      if (echo != null) 'echo': echo,
      if (self != null) 'self': self
    }));
    final response = await request.close().timeout(const Duration(seconds: 8));
    expect(response.statusCode, 200);
    return jsonObject(await utf8.decoder.bind(response).join());
  } finally {
    client.close(force: true);
  }
}

void _ok(Map<String, dynamic> result) {
  expect(result['status'], 'ok', reason: '$result');
  expect(result['retcode'], 0);
}

class _WsClient {
  _WsClient(this.socket) {
    _subscription = socket.listen((frame) {
      final value = jsonObject(frame as String);
      final index = _waiting.indexWhere((entry) => entry.$1(value));
      if (index < 0) {
        buffered.add(value);
      } else {
        _waiting.removeAt(index).$2.complete(value);
      }
    });
  }
  final WebSocket socket;
  late final StreamSubscription<dynamic> _subscription;
  final buffered = <Map<String, dynamic>>[];
  final _waiting = <(
    bool Function(Map<String, dynamic>),
    Completer<Map<String, dynamic>>
  )>[];
  bool _closed = false;
  static Future<_WsClient> connect(int port, int version) async =>
      _WsClient(await WebSocket.connect('ws://127.0.0.1:$port/onebot/v$version',
          headers: {'Authorization': 'Bearer $_token'},
          compression: CompressionOptions.compressionOff));
  void send(Map<String, dynamic> value) => socket.add(jsonEncode(value));
  Future<Map<String, dynamic>> next(
      bool Function(Map<String, dynamic>) predicate) {
    final index = buffered.indexWhere(predicate);
    if (index >= 0) return Future.value(buffered.removeAt(index));
    final result = Completer<Map<String, dynamic>>();
    _waiting.add((predicate, result));
    return result.future.timeout(const Duration(seconds: 8));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await socket.close();
    await _subscription.cancel();
  }
}
