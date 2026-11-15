import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';

import 'replica.dart';

/// 本机原型资料目录。只有public/vault可复制仓库，unlock.factor/private-device留本机。
class LocalProfile {
  final Directory root;
  final Identity identity;
  final DeviceCredentials device;
  final TrustStore trust;
  final List<ConversationKey> keys;
  ChatState seed;
  CommunityManifest manifest;
  final List<int> _storageKey;
  final List<CommunityManifest> _manifestHistory;
  final Map<String, BotRecord> localDrafts = {};
  String displayName;
  List<CommunityManifest> get manifestHistory =>
      List.unmodifiable(_manifestHistory);
  LocalProfile._(
      this.root,
      this.identity,
      this.device,
      this.trust,
      this.keys,
      this.seed,
      this.manifest,
      this._storageKey,
      this._manifestHistory,
      this.displayName);
  File file(String name) => File(p.join(root.path, name));

  static Future<void> initialize(Directory root,
      {required String name,
      required String displayName,
      required String password,
      CommunityManifest? community,
      String? pinnedFingerprint,
      KdfParameters parameters = const KdfParameters()}) async {
    validateDisplayName(displayName);
    // Fail before creating directories or writing public bootstrap files. A
    // rejected password must not strand a non-empty, unusable profile.
    final normalizedName = normalizeAccountName(name);
    validatePassword(normalizedName, password);
    if (await root.exists() && !await root.list().isEmpty)
      throw StateError('目标资料目录不是空目录');
    await root.create(recursive: true);
    final identity = await Identity.create(name);
    final device = await DeviceCredentials.create();
    final factor = secureBytes(32);
    var manifest = community ??
        await CommunityManifest.create(identity, settings: {
          'profiles': {identity.public.accountId: displayName}
        });
    if (community != null) {
      if (pinnedFingerprint == null) throw StateError('加入社区必须先扫码确认仓库外指纹');
      await community.verify(pinnedFingerprint);
    }
    await device.authorize(identity, manifest.communityId);
    if (community == null)
      manifest = await CommunityManifest.create(identity,
          communityId: manifest.communityId,
          settings: {
            'profiles': {identity.public.accountId: displayName},
            'devices': [device.certificate!.toJson()]
          });
    final storageKey = secureBytes(32);
    final seed = await _seedForManifest(manifest);
    final initialKeys = community == null
        ? [ConversationKey.generate('control:${manifest.communityId}', 1)]
        : <ConversationKey>[];
    final private = <String, dynamic>{
      'local_drafts': <String, dynamic>{},
      'display_name': displayName,
      'device': await device.exportPrivate(),
      'storage_key': base64Encode(storageKey),
      'keys': initialKeys
          .map((key) => {
                'conversation': key.conversationId,
                'epoch': key.epoch,
                'bytes': base64Encode(key.bytes)
              })
          .toList(),
      'seed': seed.toJson(),
      'manifest_history': [manifest.toJson()],
      'manifest_checkpoint': {
        'revision': manifest.revision,
        'hash': await objectHash(manifest.toJson())
      }
    };
    final signedPrivate = {
      'body': private,
      'signature': await identity.sign(private)
    };
    final sealed = await wrapSecret(
        utf8.encode(canonicalJson(signedPrivate)), identity.public.exchangeKey,
        context: 'zaizuo.local-profile.v1:${identity.public.accountId}');
    await File(p.join(root.path, 'community.json'))
        .writeAsString(canonicalJson(manifest.toJson()), flush: true);
    await File(p.join(root.path, 'trust.fingerprint'))
        .writeAsString(await manifest.fingerprint(), flush: true);
    await File(p.join(root.path, 'account.keybox')).writeAsString(
        canonicalJson(await PasswordVault.seal(identity, password,
            secondFactor: factor, parameters: parameters)),
        flush: true);
    await File(p.join(root.path, 'local-private.json'))
        .writeAsString(canonicalJson(sealed), flush: true);
    // 桌面原型文件并非Android Keystore/Windows DPAPI；不能备份到Git或共享目录。
    await File(p.join(root.path, 'unlock.factor'))
        .writeAsBytes(factor, flush: true);
    await File(p.join(root.path, 'recovery.txt')).writeAsString(
        '在座恢复材料（离线保存后删除本机副本）\n账号：${identity.public.name}\n第二因素：${base64Encode(factor)}\n密码仍需另行记住。此原型恢复材料不是已审计的账户恢复协议。\n',
        flush: true);
    await File(p.join(root.path, 'README-勿上传私密文件.txt')).writeAsString(
        'unlock.factor、local-private.json、recovery.txt、events/与state.enc仅本机；不要git add此整个目录。正式系统应接系统安全存储。仓库只能包含加密钥匙箱、签名公开配置及加密事件。\n',
        flush: true);
  }

  static Future<LocalProfile> open(Directory root, String password) async {
    final manifest = CommunityManifest.fromJson(jsonObject(
        await File(p.join(root.path, 'community.json')).readAsString()));
    final pin =
        (await File(p.join(root.path, 'trust.fingerprint')).readAsString())
            .trim();
    await manifest.verify(pin);
    final factor = await File(p.join(root.path, 'unlock.factor')).readAsBytes();
    final identity = await PasswordVault.open(
        jsonObject(
            await File(p.join(root.path, 'account.keybox')).readAsString()),
        password,
        secondFactor: factor);
    final secret = await unwrapSecret(
        jsonObject(
            await File(p.join(root.path, 'local-private.json')).readAsString()),
        identity.exchange,
        context: 'zaizuo.local-profile.v1:${identity.public.accountId}');
    final privateEnvelope = jsonObject(utf8.decode(secret));
    final data = privateEnvelope['body'] as Map<String, dynamic>;
    if (!await verifySignature(data, readString(privateEnvelope, 'signature'),
        identity.public.signingKey)) throw StateError('本机密钥资料签名不符');
    final checkpoint = data['manifest_checkpoint'] as Map<String, dynamic>;
    if (checkpoint['revision'] != manifest.revision ||
        checkpoint['hash'] != await objectHash(manifest.toJson()))
      throw StateError('社区配置与本机已确认检查点不同，必须显式验证配置升级');
    final device = await DeviceCredentials.importPrivate(
        data['device'] as Map<String, dynamic>);
    final trust = await _trustForManifest(manifest);
    // 未入驻本机可以生成加入请求，但不能发布社区消息。
    if (trust.accounts.containsKey(identity.public.accountId))
      await trust.authorizeDevice(device.certificate!);
    final keys = (data['keys'] as List).map((raw) {
      final v = raw as Map<String, dynamic>;
      return ConversationKey(
          conversationId: readString(v, 'conversation'),
          epoch: readInt(v, 'epoch', min: 1),
          bytes: readBase64(v, 'bytes', size: 32));
    }).toList();
    final seed = ChatState.fromJson(data['seed'] as Map<String, dynamic>);
    final storageKey = readBase64(data, 'storage_key', size: 32);
    final history = (data['manifest_history'] as List)
        .map((v) => CommunityManifest.fromJson(v as Map<String, dynamic>))
        .toList();
    if (history.isEmpty ||
        canonicalJson(history.last.toJson()) !=
            canonicalJson(manifest.toJson())) throw StateError('本机配置历史检查点不符');
    for (var i = 0; i < history.length; i++)
      await history[i].verify(pin, previous: i == 0 ? null : history[i - 1]);
    final profile = LocalProfile._(
        root,
        identity,
        device,
        trust,
        keys,
        seed,
        manifest,
        storageKey,
        history,
        data['display_name'] as String? ?? identity.public.name);
    for (final raw in (data['local_drafts'] as Map? ?? {}).values) {
      final draft = BotRecord.fromJson(raw as Map<String, dynamic>);
      if (!draft.draft || draft.ownerId != identity.public.accountId)
        throw StateError('本机草案主体不符');
      profile.localDrafts[draft.id] = draft;
    }
    return profile;
  }

  Future<void> saveState(ChatState state) async {
    final box = await AesGcm.with256bits().encrypt(
        utf8.encode(canonicalJson(state.toJson())),
        secretKey: SecretKey(_storageKey),
        aad: utf8.encode('zaizuo.local-state.v1'));
    await file('state.enc').writeAsString(
        canonicalJson({
          'ciphertext': base64Encode(box.cipherText),
          'nonce': base64Encode(box.nonce),
          'tag': base64Encode(box.mac.bytes)
        }),
        flush: true);
  }

  /// 本机应用状态加密存储；调用者串行化同名写入，不接受网络提供的文件路径。
  Future<Map<String, dynamic>?> readSecretState(String name) async {
    if (name != 'media-state.enc') throw ArgumentError('未注册的本机状态名');
    final source = file(name);
    if (!await source.exists()) return null;
    if (await source.length() > 9 * 1024 * 1024) throw StateError('本机状态文件过大');
    final envelope = jsonObject(await source.readAsString());
    final aad = utf8
        .encode('zaizuo.local-secret.v1:${identity.public.accountId}:$name');
    final clear = await AesGcm.with256bits().decrypt(
        SecretBox(readBase64(envelope, 'ciphertext', max: 6 * 1024 * 1024),
            nonce: readBase64(envelope, 'nonce', size: 12),
            mac: Mac(readBase64(envelope, 'tag', size: 16))),
        secretKey: SecretKey(_storageKey),
        aad: aad);
    return jsonObject(utf8.decode(clear));
  }

  Future<void> writeSecretState(String name, Map<String, dynamic> state) async {
    if (name != 'media-state.enc') throw ArgumentError('未注册的本机状态名');
    final clear = utf8.encode(canonicalJson(state));
    if (clear.length > 6 * 1024 * 1024) throw StateError('本机状态数据过大');
    final box = await AesGcm.with256bits().encrypt(clear,
        secretKey: SecretKey(_storageKey),
        aad: utf8.encode(
            'zaizuo.local-secret.v1:${identity.public.accountId}:$name'));
    final temporary = file('$name.new');
    await temporary.writeAsString(
        canonicalJson({
          'ciphertext': base64Encode(box.cipherText),
          'nonce': base64Encode(box.nonce),
          'tag': base64Encode(box.mac.bytes)
        }),
        flush: true);
    await temporary.rename(file(name).path);
  }

  Future<void> savePrivate(
      {required ChatState seed,
      required Iterable<ConversationKey> keys}) async {
    final data = {
      'local_drafts': {
        for (final entry in localDrafts.entries) entry.key: entry.value.toJson()
      },
      'display_name': displayName,
      'device': await device.exportPrivate(),
      'storage_key': base64Encode(_storageKey),
      'keys': keys
          .map((key) => {
                'conversation': key.conversationId,
                'epoch': key.epoch,
                'bytes': base64Encode(key.bytes)
              })
          .toList(),
      'seed': seed.toJson(),
      'manifest_history': _manifestHistory.map((m) => m.toJson()).toList(),
      'manifest_checkpoint': {
        'revision': manifest.revision,
        'hash': await objectHash(manifest.toJson())
      }
    };
    final signedPrivate = {
      'body': data,
      'signature': await identity.sign(data)
    };
    final wrapped = await wrapSecret(
        utf8.encode(canonicalJson(signedPrivate)), identity.public.exchangeKey,
        context: 'zaizuo.local-profile.v1:${identity.public.accountId}');
    final temporary = file('local-private.json.new');
    await temporary.writeAsString(canonicalJson(wrapped), flush: true);
    await temporary.rename(file('local-private.json').path);
  }

  Future<Map<String, dynamic>> joinRequest() async {
    final body = <String, dynamic>{
      'version': 1,
      'community': manifest.communityId,
      'account': identity.public.toJson(),
      'display_name': displayName,
      'device': device.certificate!.toJson()
    };
    return {'body': body, 'signature': await identity.sign(body)};
  }

  /// 这是社区成员入驻，不是频道准入；仅社区根账户可签发成员名册。
  Future<CommunityManifest> admit(Map<String, dynamic> request) async {
    if (identity.public.accountId != manifest.owner.accountId)
      throw StateError('仅社区创建者可接纳社区账号');
    final body = request['body'] as Map<String, dynamic>;
    final account =
        IdentityPublic.fromJson(body['account'] as Map<String, dynamic>);
    final certificate =
        DeviceCertificate.fromJson(body['device'] as Map<String, dynamic>);
    if (body['version'] != 1 ||
        body['community'] != manifest.communityId ||
        !await verifySignature(
            body, readString(request, 'signature'), account.signingKey) ||
        !await certificate.verify(account, manifest.communityId))
      throw StateError('加入请求签名或设备证书不符');
    final existing =
        manifest.accounts.where((a) => a.accountId == account.accountId);
    if (existing.isNotEmpty &&
        canonicalJson(existing.first.toJson()) !=
            canonicalJson(account.toJson())) throw StateError('同账号编号已被其他密钥认领');
    final settings = Map<String, dynamic>.from(
        manifest.body['settings'] as Map<String, dynamic>);
    final devices = List<Map<String, dynamic>>.from(
        (settings['devices'] as List? ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map)));
    if (!devices.any((d) => DeviceCertificate.fromJson(d).id == certificate.id))
      devices.add(certificate.toJson());
    settings['devices'] = devices;
    final profiles =
        Map<String, dynamic>.from(settings['profiles'] as Map? ?? {});
    profiles[account.accountId] =
        body['display_name'] as String? ?? account.name;
    settings['profiles'] = profiles;
    final grants = List<Map<String, dynamic>>.from(
        (settings['keys'] as List? ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map)));
    // 只分发社区控制通道，不把创建者所有私聊key给新成员。
    final control = keys
        .where((k) => k.conversationId == 'control:${manifest.communityId}')
        .toList()
      ..sort((a, b) => b.epoch.compareTo(a.epoch));
    if (control.isNotEmpty)
      grants.add(await control.first.wrapFor(account,
          sender: identity, communityId: manifest.communityId));
    settings['keys'] = grants;
    return CommunityManifest.create(identity,
        communityId: manifest.communityId,
        title: manifest.body['title'] as String,
        revision: manifest.revision + 1,
        previousHash: await objectHash(manifest.toJson()),
        accounts: [...manifest.accounts, if (existing.isEmpty) account],
        settings: settings);
  }

  /// 只补全经过Git逐修订验证的旧上下文，不改变当前配置水位。
  Future<void> rememberManifestHistory(List<CommunityManifest> history) async {
    if (history.isEmpty) return;
    final pin = await manifest.fingerprint();
    if (history.first.revision != 1) throw StateError('补历史必须从修订1开始');
    for (var i = 0; i < history.length; i++)
      await history[i].verify(pin, previous: i == 0 ? null : history[i - 1]);
    if (history.length < manifest.revision ||
        canonicalJson(history[manifest.revision - 1].toJson()) !=
            canonicalJson(manifest.toJson()))
      throw StateError('补全的配置历史不包含本机已见检查点');
    for (final old in _manifestHistory) {
      if (old.revision > history.length ||
          canonicalJson(old.toJson()) !=
              canonicalJson(history[old.revision - 1].toJson()))
        throw StateError('配置历史改写');
    }
    _manifestHistory
      ..clear()
      ..addAll(history.where((m) => m.revision <= manifest.revision));
    await savePrivate(seed: seed, keys: keys);
  }

  Future<void> acceptManifest(CommunityManifest next) async {
    await next.verify(await manifest.fingerprint(), previous: manifest);
    final previousAccounts = manifest.accounts;
    if (next.accounts.length < previousAccounts.length)
      throw StateError('当前原型仅支持增量入驻，不支持删除账号或换根');
    for (var i = 0; i < previousAccounts.length; i++) {
      if (canonicalJson(previousAccounts[i].toJson()) !=
          canonicalJson(next.accounts[i].toJson()))
        throw StateError('已有账号顺序/公钥不能被名册更新改写');
    }
    final nextTrust = await _trustForManifest(next);
    final grants =
        (next.body['settings'] as Map<String, dynamic>)['keys'] as List? ??
            const [];
    for (final raw in grants) {
      final envelope = raw as Map<String, dynamic>;
      final body = envelope['body'] as Map<String, dynamic>;
      if (body['conversation'] != 'control:${next.communityId}' ||
          body['sender'] != next.owner.accountId)
        throw StateError('main仅分发根签名社区控制密钥，会话密钥必须走当期授权公告');
      if (body['recipient'] != identity.public.accountId) continue;
      // main只承载控制密钥；所有会话密钥必须由当期授权公告验证。
      final key = await ConversationKey.unwrap(envelope, identity,
          authorizedSender: next.owner, communityId: next.communityId);
      if (!keys.any((k) =>
          k.conversationId == key.conversationId && k.epoch == key.epoch))
        keys.add(key);
    }
    manifest = next;
    _manifestHistory.add(next);
    seed = await _seedForManifest(next);
    for (final account in nextTrust.accounts.values)
      trust.trustAccount(account);
    for (final cert in nextTrust.devices.values)
      await trust.authorizeDevice(cert);
    // 先保存带已见hash的本机签名检查点；跨文件崩溃会fail closed，不自动退回旧配置。
    await savePrivate(seed: seed, keys: keys);
    final temporary = file('community.json.new');
    await temporary.writeAsString(canonicalJson(next.toJson()), flush: true);
    await temporary.rename(file('community.json').path);
  }

  Future<CommunityManifest> withGrants(
      Iterable<Map<String, dynamic>> grants) async {
    if (identity.public.accountId != manifest.owner.accountId)
      throw StateError('只有社区根账户能更新此原型的main名册');
    final settings = Map<String, dynamic>.from(
        manifest.body['settings'] as Map<String, dynamic>);
    final additions = grants.toList();
    for (final envelope in additions) {
      final body = envelope['body'] as Map<String, dynamic>;
      if (body['conversation'] != 'control:${manifest.communityId}' ||
          body['sender'] != identity.public.accountId ||
          !await verifySignature(body, readString(envelope, 'signature'),
              identity.public.signingKey))
        throw StateError('main不接受会话密钥或未授权控制密钥');
    }
    settings['keys'] = [
      ...(settings['keys'] as List? ?? const []),
      ...additions
    ];
    return CommunityManifest.create(identity,
        communityId: manifest.communityId,
        title: manifest.body['title'] as String,
        revision: manifest.revision + 1,
        previousHash: await objectHash(manifest.toJson()),
        accounts: manifest.accounts,
        settings: settings);
  }

  Future<Map<String, dynamic>> grantKey(
      {required ConversationKey key,
      required IdentityPublic recipient,
      required ChatState state}) async {
    // 历史读权限不等于当前epoch受领资格；不再保留旧会话发钥路径。
    if (identity.public.accountId != manifest.owner.accountId ||
        key.conversationId != 'control:${manifest.communityId}')
      throw StateError('此接口只用于社区根分发控制密钥，会话须使用ConversationKeyManager');
    final account = manifest.accounts
        .where((a) => a.accountId == recipient.accountId)
        .firstOrNull;
    if (account == null ||
        canonicalJson(account.toJson()) != canonicalJson(recipient.toJson()))
      throw StateError('接收者公钥未钉住');
    return key.wrapFor(recipient,
        sender: identity, communityId: manifest.communityId);
  }

  static Future<ChatState> _seedForManifest(CommunityManifest manifest) async {
    final seed = ChatState(communityOwnerId: manifest.owner.accountId);
    var activeAccount = '';
    final service = ChatService(seed,
        now: () => DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        idGenerator: (prefix) => '$prefix:bootstrap:$activeAccount');
    final profiles = (manifest.body['settings']
            as Map<String, dynamic>)['profiles'] as Map? ??
        {};
    for (final account in manifest.accounts) {
      activeAccount = account.accountId;
      service.registerAccount(
          id: account.accountId,
          name: account.name,
          displayName: profiles[account.accountId] as String? ?? account.name);
    }
    await service.close();
    return seed;
  }

  static Future<TrustStore> _trustForManifest(
      CommunityManifest manifest) async {
    final trust = TrustStore(manifest.communityId);
    for (final account in manifest.accounts) trust.trustAccount(account);
    for (final raw in ((manifest.body['settings']
            as Map<String, dynamic>)['devices'] as List? ??
        const [])) {
      await trust.authorizeDevice(
          DeviceCertificate.fromJson(raw as Map<String, dynamic>));
    }
    return trust;
  }

  Future<(FileEventStore, EncryptedReplica)> replica() async {
    // state.enc是命令行本地管理状态缓存；不能与已重放历史重复作为seed。
    final store = await FileEventStore.open(
        Directory(p.join(root.path, 'events')), trust);
    try {
      return (
        store,
        await EncryptedReplica.open(
            store: store,
            device: device,
            seed: seed,
            identity: identity,
            manifestRevision: manifest.revision,
            manifestAccounts: {
              for (final m in _manifestHistory)
                m.revision: m.accounts.map((a) => a.accountId).toSet()
            },
            keys: keys)
      );
    } catch (_) {
      await store.close();
      rethrow;
    }
  }
}
