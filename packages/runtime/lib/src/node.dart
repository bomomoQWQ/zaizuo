import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_onebot/zaizuo_onebot.dart';

import 'local_profile.dart';
import 'media.dart';
import 'commands.dart';
import 'relay_client.dart';
import 'replica.dart';

/// Non-UI application lifecycle. All mutations, sync rounds and relay refreshes
/// use one queue; successful commands mean local flush, never remote delivery.
class ZaizuoNode {
  final LocalProfile profile;
  final FileEventStore store;
  final EncryptedReplica replica;
  final GitSync? git;
  late final MediaRepository media;
  final Duration syncInterval;
  final Uri? relayUrl;
  final String? _relayToken;
  final bool _ownsGit;
  final _errors = StreamController<String>.broadcast();
  Future<void> _tail = Future.value();
  Future<void> _relayTail = Future.value();
  Future<Map<String, dynamic>>? _syncing;
  Future<void>? _closing;
  Timer? _timer;
  RelayLink? _relay;
  StreamSubscription<EncryptedEvent>? _events;
  StreamSubscription<RelayLinkException>? _relayErrors;
  DomainOneBotBackend? _backend;
  OneBotProjection? _projection;
  OneBotServer? _server;
  OneBotIdMap? _ids;
  bool _closed = false;
  bool _background = false;
  String? lastSyncError;
  String? lastRelayError;
  int completedSyncs = 0;

  ZaizuoNode._(this.profile, this.store, this.replica, this.git,
      this.syncInterval, this.relayUrl, this._relayToken, this._ownsGit);

  static Future<ZaizuoNode> open({
    required LocalProfile profile,
    GitSync? git,
    bool ownsGit = false,
    Duration syncInterval = const Duration(seconds: 30),
    Uri? relayUrl,
    String? relayToken,
  }) async {
    if (syncInterval < const Duration(seconds: 1)) {
      throw ArgumentError('同步间隔至少1秒');
    }
    if ((relayUrl == null) != (relayToken == null)) {
      throw ArgumentError('中继URL和令牌必须同时配置');
    }
    if (relayUrl != null) _validateRelay(relayUrl, relayToken!);
    final (store, replica) = await profile.replica();
    final node = ZaizuoNode._(profile, store, replica, git, syncInterval,
        relayUrl, relayToken, ownsGit);
    try {
      node.media = await MediaRepository.open(
          profile: profile, replica: replica, git: git);
    } catch (_) {
      await replica.close();
      await store.close();
      rethrow;
    }
    node._events = store.events.listen((event) {
      if (!node._closed && event.origin == profile.device.certificate!.id) {
        node._relayTail = node._relayTail.then((_) async {
          // execute may have just learned a new scope. Its subscription update
          // must finish before publishing that already-flushed envelope.
          await node._tail;
          await node._publish(event);
        });
      }
    });
    return node;
  }

  Stream<String> get errors => _errors.stream;
  int? get port => _server?.port;
  OneBotIdMap? get ids => _ids;
  bool get relayConnected => _relay?.isConnected ?? false;
  bool get isClosed => _closed;

  Map<String, dynamic> status() => {
        'project': '在座',
        'community': profile.manifest.communityId,
        'revision': profile.manifest.revision,
        'account': profile.identity.public.name,
        'device': profile.device.certificate!.id,
        'admitted':
            profile.trust.devices.containsKey(profile.device.certificate!.id),
        'events': store.allEnvelopes.length,
        'accounts': replica.service.state.accounts.length,
        'bots': replica.service.state.bots.length,
        'spaces': replica.service.state.spaces.length,
        'rejected_commands': replica.rejected.length,
        'git_configured': git != null,
        'completed_syncs': completedSyncs,
        'last_sync_error': lastSyncError,
        'relay_connected': relayConnected,
        'last_relay_error': lastRelayError,
      };

  Future<T> _serial<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('节点已关闭'));
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  /// Route is derived from the authenticated actor/operation, never a OneBot
  /// request-provided identity. Explicit route is only for local CLI diagnostics.
  Future<Map<String, dynamic>> execute({
    String? actorId,
    required String operation,
    required Map<String, dynamic> params,
    String? conversation,
  }) =>
      _serial(() async {
        final actor = actorId ?? profile.identity.public.accountId;
        if (operation == 'bot.draft') return _createLocalDraft(actor, params);
        var sharedOperation = operation;
        var sharedParams = params;
        BotRecord? admittingDraft;
        if (operation == 'bot.admit') {
          _draftFields(params, {'bot_id'});
          final id = _draftString(params, 'bot_id');
          admittingDraft = profile.localDrafts[id];
          if (admittingDraft != null) {
            if (actor != profile.identity.public.accountId ||
                admittingDraft.ownerId != actor) {
              throw const DomainException('forbidden', '不能入驻其他账号的本机草案');
            }
            sharedOperation = 'bot.register';
            sharedParams = {
              'id': id,
              'display_name': admittingDraft.displayName
            };
          }
        }
        final route = conversation ??
            replica.routeFor(actor, sharedOperation, sharedParams);
        final rawParts = sharedParams['parts'];
        if (rawParts is List &&
            rawParts.any((part) =>
                part is Map && {'image', 'file'}.contains(part['type']))) {
          final candidate =
              ChatService(ChatState.fromJson(replica.service.state.toJson()));
          try {
            applyCommand(candidate, actor, sharedOperation, sharedParams);
          } finally {
            await candidate.close();
          }
          sharedParams = {
            ...sharedParams,
            'parts': await media.resolve(
                actorId: actor,
                conversationId: route,
                parts: List<Map<String, dynamic>>.from(rawParts))
          };
        }
        final result = await replica.execute(
            actorId: actor,
            operation: sharedOperation,
            params: sharedParams,
            conversation: route);
        if (admittingDraft != null) {
          profile.localDrafts.remove(admittingDraft.id);
          await _persistKeys();
        }
        await _ensureKeys();
        await _maintainRelay();
        return result;
      });

  void _draftFields(Map<String, dynamic> params, Set<String> fields) {
    if (params.keys.any((key) => !fields.contains(key))) {
      throw const DomainException('bad_request', '本机草案命令包含未知参数');
    }
  }

  String _draftString(Map<String, dynamic> params, String key) {
    final value = params[key];
    if (value is! String || value.trim().isEmpty || value.length > 512) {
      throw const DomainException('bad_request', '本机草案参数必须是非空字符串');
    }
    return value;
  }

  Future<Map<String, dynamic>> _createLocalDraft(
      String actorId, Map<String, dynamic> params) async {
    _draftFields(params, {'id', 'display_name'});
    final id = _draftString(params, 'id');
    final name = _draftString(params, 'display_name');
    if (actorId != profile.identity.public.accountId) {
      throw const DomainException('forbidden', '只能创建本机主账户的草案');
    }
    final temporary =
        ChatService(ChatState.fromJson(replica.service.state.toJson()));
    late BotRecord draft;
    try {
      final actor = temporary.actor(actorId);
      // Domain checks active principals and every other persisted local draft,
      // but createBotDraft intentionally does not consume admission quotas.
      for (final existing in profile.localDrafts.values) {
        if (!existing.draft || existing.active || existing.ownerId != actorId) {
          throw StateError('本机草案状态/owner无效');
        }
        temporary.createBotDraft(
            actor: actor, id: existing.id, displayName: existing.displayName);
      }
      draft = temporary.createBotDraft(actor: actor, id: id, displayName: name);
    } finally {
      await temporary.close();
    }
    profile.localDrafts[draft.id] = draft;
    try {
      await _persistKeys();
    } catch (_) {
      profile.localDrafts.remove(draft.id);
      rethrow;
    }
    return {'result': draft.toJson(), 'local_only': true};
  }

  Future<CommunityManifest> admit(Map<String, dynamic> request) =>
      _serial(() async {
        final next = await profile.admit(request);
        await profile.acceptManifest(next);
        for (final key in profile.keys) {
          replica.addKey(key);
        }
        await replica.replaceSeed(profile.seed,
            manifestRevision: profile.manifest.revision,
            manifestAccounts: {
              for (final manifest in profile.manifestHistory)
                manifest.revision:
                    manifest.accounts.map((a) => a.accountId).toSet()
            });
        await _persistKeys();
        return next;
      });

  /// Concurrent requests share one round. Commands queue behind it, so a slow
  /// Git process cannot overlap another timer round or private-profile write.
  Future<Map<String, dynamic>> syncOnce() {
    if (_closed) return Future.error(StateError('节点已关闭'));
    final running = _syncing;
    if (running != null) return running;
    final future = _serial(_sync);
    _syncing = future;
    unawaited(future.then<void>((_) {
      if (identical(_syncing, future)) _syncing = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_syncing, future)) _syncing = null;
    }));
    return future;
  }

  Future<Map<String, dynamic>> _sync() async {
    var pushed = 0;
    var pulled = 0;
    final repository = git;
    try {
      if (repository != null) {
        final main = CommunityGit(
            repository: repository,
            pinnedFingerprint: await profile.manifest.fingerprint());
        final history = await main.readHistory();
        final current = profile.manifest;
        if (history.length >= current.revision &&
            await objectHash(history[current.revision - 1].toJson()) !=
                await objectHash(current.toJson())) {
          throw StateError('仓库与本机已验收配置分叉');
        }
        if (history.length >= current.revision) {
          await profile.rememberManifestHistory(history);
          await replica.replaceSeed(profile.seed,
              manifestRevision: profile.manifest.revision,
              manifestAccounts: {
                for (final manifest in profile.manifestHistory)
                  manifest.revision:
                      manifest.accounts.map((a) => a.accountId).toSet()
              });
        }
        final owner =
            profile.identity.public.accountId == current.owner.accountId;
        if (history.length < current.revision) {
          if (!owner) throw StateError('远端配置落后于本机检查点');
          final local = profile.manifestHistory.toList()
            ..sort((a, b) => a.revision.compareTo(b.revision));
          for (final manifest
              in local.where((m) => m.revision <= history.length)) {
            if (canonicalJson(history[manifest.revision - 1].toJson()) !=
                canonicalJson(manifest.toJson())) throw StateError('本机配置历史分叉');
          }
          var revision = history.length;
          for (final manifest in local.where((m) => m.revision > revision)) {
            if (manifest.revision != revision + 1) throw StateError('本机缺少配置历史');
            await main.publish(manifest);
            revision = manifest.revision;
          }
          if (revision != current.revision) throw StateError('本机配置历史不完整');
        }
        for (final manifest
            in history.where((m) => m.revision > profile.manifest.revision)) {
          await profile
              .acceptManifest(manifest); // explicit verified revisions only
          for (final key in profile.keys) {
            replica.addKey(key);
          }
          await replica.replaceSeed(profile.seed,
              manifestRevision: profile.manifest.revision,
              manifestAccounts: {
                for (final manifest in profile.manifestHistory)
                  manifest.revision:
                      manifest.accounts.map((a) => a.accountId).toSet()
              });
        }
        // Trust is the SAME object used by FileEventStore, not a stale copy.
        pulled = await repository.pull(store);
        await replica.refresh();
        await _ensureKeys();
        if (profile.trust.devices.containsKey(profile.device.certificate!.id)) {
          await media.flushUploads();
          pushed = await repository.push(store);
        }
      } else {
        await replica.refresh();
        await _ensureKeys();
      }
      await _persistKeys();
      await media.flushUploads();
      await _maintainRelay();
      completedSyncs++;
      lastSyncError = null;
      return {
        'pushed': pushed,
        'pulled': pulled,
        'revision': profile.manifest.revision,
        'rejected_commands': replica.rejected.length
      };
    } catch (error) {
      lastSyncError = _code(error);
      _report(lastSyncError!);
      rethrow;
    }
  }

  Future<void> _persistKeys() async {
    final keys = replica.keys;
    profile.keys
      ..clear()
      ..addAll(keys);
    await profile.savePrivate(seed: profile.seed, keys: keys);
  }

  Future<void> _ensureKeys() async {
    if (!profile.trust.devices.containsKey(profile.device.certificate!.id))
      return;
    final owner = profile.identity.public.accountId;
    final actors = <String>{
      owner,
      ...replica.service.state.bots.values
          .where((b) => b.ownerId == owner)
          .map((b) => b.id)
    };
    final scopes = <String>{...replica.keys.map((key) => key.conversationId)};
    scopes.remove('control:${profile.manifest.communityId}');
    for (final id in actors) {
      try {
        final actor = replica.service.actor(id);
        scopes.addAll(
            replica.service.conversations(actor: actor).map((c) => c.id));
        for (final space in replica.service.state.spaces.values) {
          try {
            scopes.addAll(replica.service
                .rooms(actor: actor, spaceId: space.id)
                .where((r) => r.kind == 'forum')
                .map((r) => r.id));
          } on DomainException catch (error) {
            if (!{'forbidden', 'not_found'}.contains(error.code)) rethrow;
          }
        }
      } on DomainException catch (error) {
        if (!{'forbidden', 'not_found'}.contains(error.code)) rethrow;
      }
    }
    for (final scope in scopes) {
      try {
        await replica.ensureConversationKey(scope);
      } on DomainException catch (error) {
        if (!{'forbidden', 'not_found'}.contains(error.code)) rethrow;
      }
    }
    await _persistKeys();
  }

  /// Starts only numeric loopback OneBot. It never starts an external platform
  /// client or relay server, and never accepts a caller-provided self override.
  Future<void> start(
      {required String botId, required String token, int port = 6700}) async {
    if (_closed || _server != null) throw StateError('节点已关闭或已启动');
    final actor = replica.service.actor(botId);
    if (!actor.isBot || actor.ownerId != profile.identity.public.accountId) {
      throw StateError('只能绑定自己的已授权机器人');
    }
    final mappingFile = profile.file('onebot-ids.json');
    void persistIds(Map<String, dynamic> value) {
      final temporary = File('${mappingFile.path}.tmp');
      temporary.writeAsStringSync(jsonEncode(value), flush: true);
      temporary.renameSync(mappingFile.path);
    }

    _ids = await mappingFile.exists()
        ? OneBotIdMap.loadState(await mappingFile.readAsString(),
            onChanged: persistIds)
        : OneBotIdMap(onChanged: persistIds);
    _backend = DomainOneBotBackend(replica.service,
        botId: botId,
        serviceProvider: () => replica.service,
        messageStream: replica.messages,
        directResolver: (target) async {
          final result = await execute(
              actorId: botId,
              operation: 'direct.create',
              params: {'target': target});
          return (result['result'] as Map)['id'] as String;
        },
        sendHandler: (
            {required actor, required conversationId, required parts}) async {
          if (actor.id != botId) throw StateError('固定机器人绑定不匹配');
          final result = await execute(
              actorId: botId,
              operation: 'message.send',
              params: {'conversation': conversationId, 'parts': parts});
          return MessageRecord.fromJson(
              result['result'] as Map<String, dynamic>);
        },
        mediaUploadHandler: (
                {required actor,
                required name,
                required bytes,
                required mime,
                required purpose}) =>
            _serial(() => media.upload(
                actorId: actor.id,
                name: name,
                bytes: bytes,
                mime: mime,
                purpose: purpose)),
        mediaGetHandler: ({required actor, required fileId}) =>
            _serial(() => media.get(actorId: actor.id, fileId: fileId)),
        resolveMediaParts: (
                {required actor, required conversationId, required parts}) =>
            parts,
        projectMediaParts: ({required actor, required message}) =>
            media.project(actorId: actor.id, message: message),
        mediaScope: ({required actor, required operation, required params}) =>
            replica.routeFor(actor.id, operation, params),
        commandHandler: (operation, params) async {
          final result = await execute(
              actorId: botId, operation: operation, params: params);
          return result['result'] as Map<String, dynamic>? ??
              <String, dynamic>{};
        });
    _projection = OneBotProjection(backend: _backend!, ids: _ids!);
    _server = OneBotServer(
        limits: OneBotLimits.media(maxMediaBytes: media.maxMediaBytes),
        bindings: [OneBotBinding(token: token, projection: _projection!)]);
    try {
      await _server!.start(address: InternetAddress.loopbackIPv4, port: port);
      _background = true;
      _schedule(immediate: true);
    } catch (_) {
      await _server!.close();
      await _projection!.close();
      await _backend!.close();
      _server = null;
      _projection = null;
      _backend = null;
      rethrow;
    }
  }

  void _schedule({bool immediate = false}) {
    if (_closed || !_background || _timer != null) return;
    _timer = Timer(immediate ? Duration.zero : syncInterval, () {
      _timer = null;
      unawaited(_backgroundRound());
    });
  }

  Future<void> _backgroundRound() async {
    try {
      await syncOnce();
    } catch (_) {/* stable code already reported */} finally {
      _schedule();
    }
  }

  Set<String> _knownScopes() => {
        'control:${profile.manifest.communityId}',
        ...profile.keys.map((key) => key.conversationId),
        ...replica.keys.map((key) => key.conversationId),
        ...store.allEnvelopes.map((event) => event.conversation),
      };

  Future<void> _maintainRelay() async {
    if (_closed || relayUrl == null) return;
    final scopes = _knownScopes();
    if (scopes.length > 64) {
      await _dropRelay();
      lastRelayError = 'too_many_topics';
      _report('relay_too_many_topics');
      return; // never truncate subscriptions silently; Git remains authoritative
    }
    final topics = <String>{};
    for (final scope in scopes) {
      topics.add(await relayTopic(
          communityId: profile.manifest.communityId, conversationId: scope));
    }
    final link = _relay;
    if (link != null &&
        link.topics.length == topics.length &&
        topics.every(link.topics.contains)) return;
    await _dropRelay();
    try {
      final connected = await RelayLink.connect(
          url: relayUrl,
          token: _relayToken!,
          store: store,
          topics: topics,
          onImported: (_) async {
            if (_closed) return;
            // Do not wait for this queue from inside RelayLink.close().
            unawaited(_serial(() async {
              await replica.refresh();
              await _ensureKeys();
            }).then<void>((_) {}, onError: (Object error, StackTrace _) {
              lastRelayError = _code(error);
              _report('relay_import_refresh_failed');
            }));
          });
      if (_closed) {
        await connected.close();
        return;
      }
      _relay = connected;
      _relayErrors = connected.errors.listen((error) {
        lastRelayError = error.code;
        _report('relay_${error.code}');
      });
      lastRelayError = null;
    } on RelayLinkException catch (error) {
      lastRelayError = error.code;
      _report('relay_${error.code}');
    }
  }

  Future<void> _publish(EncryptedEvent event) async {
    if (_closed || _relay == null) return;
    try {
      await _relay!.publish(event);
    } on RelayLinkException catch (error) {
      lastRelayError = error.code;
      _report('relay_${error.code}');
    } catch (_) {
      lastRelayError = 'publish_failed';
      _report('relay_publish_failed');
    }
  }

  Future<void> _dropRelay() async {
    final link = _relay;
    _relay = null;
    await _relayErrors?.cancel();
    _relayErrors = null;
    await link?.close();
  }

  void _report(String code) {
    if (!_errors.isClosed) _errors.add(code);
  }

  String _code(Object error) => error is GitSyncException
      ? error.code
      : error is DomainException
          ? error.code
          : error is RelayLinkException
              ? error.code
              : 'operation_failed';

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _background = false;
    _timer?.cancel();
    _timer = null;
    Object? firstError;
    StackTrace? firstStack;
    Future<void> finish(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    await finish(() async {
      await _server?.close();
    });
    await finish(() async {
      await _events?.cancel();
    });
    await finish(_dropRelay);
    await finish(() => _tail); // started commands/sync/private writes finish
    await finish(() => _relayTail);
    await finish(_persistKeys);
    await finish(() async {
      await _projection?.close();
    });
    await finish(() async {
      await _backend?.close();
    });
    await finish(media.close);
    await finish(replica.close);
    await finish(store.close);
    if (_ownsGit)
      await finish(() async {
        await git?.close();
      });
    await finish(_errors.close);
    if (firstError != null) Error.throwWithStackTrace(firstError!, firstStack!);
  }

  static void _validateRelay(Uri endpoint, String token) {
    final address = InternetAddress.tryParse(endpoint.host);
    if (endpoint.scheme != 'ws' ||
        address == null ||
        !address.isLoopback ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.path != '/v1/ws' ||
        endpoint.port < 1 ||
        endpoint.port > 65535 ||
        token.length < 32 ||
        token.length > 256 ||
        token.codeUnits.any((b) => b < 0x21 || b > 0x7e)) {
      throw const RelayLinkException('invalid_config');
    }
  }
}
