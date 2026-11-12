import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:cryptography/cryptography.dart';

import 'codec.dart';

final _signer = Ed25519();
final _exchange = X25519();
final _cipher = AesGcm.with256bits();

/// Snapshot and recursively freeze signed JSON. A shallow Map.unmodifiable is
/// insufficient: nested lists/maps must not change after signature verification.
Map<String, dynamic> immutableProtocolObject(Map<String, dynamic> value) {
  Object? freeze(Object? item) {
    if (item is Map<String, dynamic>) {
      return Map<String, dynamic>.unmodifiable(
          item.map((key, nested) => MapEntry(key, freeze(nested))));
    }
    if (item is List) return List<Object?>.unmodifiable(item.map(freeze));
    return item;
  }

  return freeze(jsonObject(canonicalJson(value))) as Map<String, dynamic>;
}

class IdentityPublic {
  final String accountId;
  final String name;
  final List<int> signingKey;
  final List<int> exchangeKey;
  IdentityPublic(
      {required this.accountId,
      required this.name,
      required List<int> signingKey,
      required List<int> exchangeKey})
      : signingKey = List.unmodifiable(signingKey),
        exchangeKey = List.unmodifiable(exchangeKey) {
    if (name != normalizeAccountName(name) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(accountId) ||
        signingKey.length != 32 ||
        exchangeKey.length != 32 ||
        [...signingKey, ...exchangeKey].any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('无效公开身份');
    }
  }
  Map<String, dynamic> toJson() => {
        'id': accountId,
        'name': name,
        'signing': base64Encode(signingKey),
        'exchange': base64Encode(exchangeKey)
      };
  factory IdentityPublic.fromJson(Map<String, dynamic> json) => IdentityPublic(
      accountId: readString(json, 'id', max: 128),
      name: normalizeAccountName(readString(json, 'name')),
      signingKey: readBase64(json, 'signing', size: 32),
      exchangeKey: readBase64(json, 'exchange', size: 32));
}

String normalizeAccountName(String name) {
  final normalized = name.toLowerCase();
  if (!RegExp(r'^[a-z0-9_]{1,14}$').hasMatch(normalized)) {
    throw const FormatException('账号名必须为1～14个英文字母、数字或下划线');
  }
  return normalized;
}

void validateDisplayName(String name) {
  if (name.characters.isEmpty || name.characters.length >= 15) {
    throw const FormatException('昵称必须为1～14个显示字符');
  }
}

void validatePassword(String name, String password) {
  final lower = password.toLowerCase();
  if (password.length < 12 ||
      password.length > 1024 ||
      !RegExp('[a-z]').hasMatch(password) ||
      !RegExp('[A-Z]').hasMatch(password) ||
      lower.contains(normalizeAccountName(name))) {
    throw const FormatException('密码需12～1024位、含大小写字母，且不能包含账号名');
  }
  const denied = [
    'password',
    'qwerty',
    'abcdefgh',
    '123456',
    'letmein',
    'welcome',
    'iloveyou',
    'adminadmin'
  ];
  if (denied.any(lower.contains) || password.runes.toSet().length < 5) {
    throw const FormatException('密码包含常见弱模式，请使用密码管理器生成随机密码');
  }
}

class Identity {
  final IdentityPublic public;
  final SimpleKeyPair signing;
  final SimpleKeyPair exchange;
  Identity._(this.public, this.signing, this.exchange);
  static Future<Identity> create(String accountName) async {
    final name = normalizeAccountName(accountName);
    // 完整摘要作为内部编号，短显示码不能作为授权或唯一键。
    final id = await objectHash({'domain': 'zaizuo.account.v1', 'name': name});
    final signing = await _signer.newKeyPair();
    final exchange = await _exchange.newKeyPair();
    return Identity._(
        IdentityPublic(
            accountId: id,
            name: name,
            signingKey: (await signing.extractPublicKey()).bytes,
            exchangeKey: (await exchange.extractPublicKey()).bytes),
        signing,
        exchange);
  }

  Future<Map<String, dynamic>> exportPrivate() async => {
        'public': public.toJson(),
        'signing_seed': base64Encode(await signing.extractPrivateKeyBytes()),
        'exchange_seed': base64Encode(await exchange.extractPrivateKeyBytes())
      };
  static Future<Identity> importPrivate(Map<String, dynamic> json) async {
    final public =
        IdentityPublic.fromJson(json['public'] as Map<String, dynamic>);
    final expected =
        await objectHash({'domain': 'zaizuo.account.v1', 'name': public.name});
    final signing = await _signer
        .newKeyPairFromSeed(readBase64(json, 'signing_seed', size: 32));
    final exchange = await _exchange
        .newKeyPairFromSeed(readBase64(json, 'exchange_seed', size: 32));
    if (expected != public.accountId ||
        !equalBytes(
            (await signing.extractPublicKey()).bytes, public.signingKey) ||
        !equalBytes(
            (await exchange.extractPublicKey()).bytes, public.exchangeKey)) {
      throw const FormatException('身份公私钥不匹配');
    }
    return Identity._(public, signing, exchange);
  }

  Future<String> sign(Object? body) async => base64Encode(
      (await _signer.sign(utf8.encode(canonicalJson(body)), keyPair: signing))
          .bytes);
}

Future<bool> verifySignature(
    Object? body, String signature, List<int> publicKey) async {
  try {
    final bytes = base64Decode(signature);
    if (bytes.length != 64 ||
        base64Encode(bytes) != signature ||
        publicKey.length != 32) return false;
    return await _signer.verify(utf8.encode(canonicalJson(body)),
        signature: Signature(bytes,
            publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
  } on FormatException {
    return false;
  }
}

class KdfParameters {
  final int memoryKiB;
  final int iterations;
  final int parallelism;
  const KdfParameters(
      {this.memoryKiB = 65536, this.iterations = 3, this.parallelism = 1});
  void validate() {
    // 不信任仓库的参数，防止恶意文件让客户端分配无限内存。
    if (memoryKiB < 8 ||
        memoryKiB > 262144 ||
        iterations < 1 ||
        iterations > 10 ||
        parallelism < 1 ||
        parallelism > 4 ||
        memoryKiB < 8 * parallelism) {
      throw const FormatException('不支持的口令派生参数');
    }
  }

  Map<String, dynamic> toJson() => {
        'algorithm': 'argon2id',
        'memory_kib': memoryKiB,
        'iterations': iterations,
        'parallelism': parallelism
      };
  factory KdfParameters.fromJson(Map<String, dynamic> json) {
    if (json['algorithm'] != 'argon2id') throw const FormatException('未知派生算法');
    final p = KdfParameters(
        memoryKiB: readInt(json, 'memory_kib'),
        iterations: readInt(json, 'iterations'),
        parallelism: readInt(json, 'parallelism'));
    p.validate();
    return p;
  }
}

class PasswordVault {
  /// secondFactor 为仓库外保存的32字节随机材料；不把它和vault放一起。
  static Future<Map<String, dynamic>> seal(Identity identity, String password,
      {List<int>? secondFactor,
      KdfParameters parameters = const KdfParameters()}) async {
    validatePassword(identity.public.name, password);
    parameters.validate();
    if (secondFactor != null && secondFactor.length != 32)
      throw ArgumentError('第二因素需32字节');
    final factorSnapshot =
        secondFactor == null ? null : List<int>.of(secondFactor);
    final salt = secureBytes(16);
    final header = <String, dynamic>{
      'version': 1,
      'public': identity.public.toJson(),
      'kdf': parameters.toJson(),
      'salt': base64Encode(salt),
      'second_factor': secondFactor != null
    };
    final key = await _vaultKey(password, salt, parameters, factorSnapshot);
    final box = await _cipher.encrypt(
        utf8.encode(canonicalJson(await identity.exportPrivate())),
        secretKey: key,
        aad: utf8.encode(canonicalJson(header)));
    return {
      ...header,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes)
    };
  }

  static Future<Identity> open(Map<String, dynamic> vault, String password,
      {List<int>? secondFactor}) async {
    vault = immutableProtocolObject(vault);
    final factorSnapshot =
        secondFactor == null ? null : List<int>.of(secondFactor);
    if (vault['version'] != 1 || vault['second_factor'] is! bool)
      throw const FormatException('未知钥匙箱版本');
    final needsFactor = vault['second_factor'] == true;
    if (needsFactor && secondFactor?.length != 32)
      throw StateError('需要已授权设备或恢复材料，密码不足以解锁');
    final parameters =
        KdfParameters.fromJson(vault['kdf'] as Map<String, dynamic>);
    final public =
        IdentityPublic.fromJson(vault['public'] as Map<String, dynamic>);
    final salt = readBase64(vault, 'salt', size: 16);
    final header = <String, dynamic>{
      'version': 1,
      'public': public.toJson(),
      'kdf': parameters.toJson(),
      'salt': vault['salt'],
      'second_factor': needsFactor
    };
    final key = await _vaultKey(
        password, salt, parameters, needsFactor ? factorSnapshot : null);
    final clear = await _cipher.decrypt(
        SecretBox(readBase64(vault, 'ciphertext', max: 16384),
            nonce: readBase64(vault, 'nonce', size: 12),
            mac: Mac(readBase64(vault, 'tag', size: 16))),
        secretKey: key,
        aad: utf8.encode(canonicalJson(header)));
    final identity =
        await Identity.importPrivate(jsonObject(utf8.decode(clear)));
    if (canonicalJson(identity.public.toJson()) !=
        canonicalJson(public.toJson())) throw const FormatException('钥匙箱身份不匹配');
    return identity;
  }

  static Future<SecretKey> _vaultKey(String password, List<int> salt,
      KdfParameters p, List<int>? secondFactor) async {
    final passwordKey = await Argon2id(
            parallelism: p.parallelism,
            memory: p.memoryKiB,
            iterations: p.iterations,
            hashLength: 32)
        .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    // 不能把公开一次性验证码当密钥。额外因素是高熵的独立秘密。
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey:
            SecretKey([...await passwordKey.extractBytes(), ...?secondFactor]),
        nonce: salt,
        info: utf8.encode('zaizuo.vault.v1'));
  }
}

/// 用临时 X25519 密钥与收件人密钥协商，HKDF 派生后 AES-GCM 封装。
/// 这只是保密原语，不认证发送者；协议层必须另行验证签名和授权。
/// 不是经生产审计的密码协议实现。
Future<Map<String, dynamic>> wrapSecret(
    List<int> secret, List<int> recipientPublic,
    {required String context}) async {
  if (recipientPublic.length != 32 ||
      secret.isEmpty ||
      context.isEmpty ||
      context.length > 4096) throw ArgumentError('无效密钥或封装上下文');
  secret = List<int>.of(secret);
  recipientPublic = List<int>.of(recipientPublic);
  final ephemeral = await _exchange.newKeyPair();
  final shared = await _exchange.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey:
          SimplePublicKey(recipientPublic, type: KeyPairType.x25519));
  final salt = secureBytes(32);
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
      .deriveKey(secretKey: shared, nonce: salt, info: utf8.encode(context));
  final public = (await ephemeral.extractPublicKey()).bytes;
  final aad = utf8.encode(canonicalJson({
    'context': context,
    'ephemeral': base64Encode(public),
    'recipient': base64Encode(recipientPublic)
  }));
  final box = await _cipher.encrypt(secret, secretKey: key, aad: aad);
  return {
    'version': 1,
    'ephemeral': base64Encode(public),
    'salt': base64Encode(salt),
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode(box.cipherText),
    'tag': base64Encode(box.mac.bytes)
  };
}

Future<List<int>> unwrapSecret(
    Map<String, dynamic> wrapped, SimpleKeyPair recipient,
    {required String context}) async {
  wrapped = immutableProtocolObject(wrapped);
  if (context.isEmpty || context.length > 4096) {
    throw ArgumentError('无效封装上下文');
  }
  if (wrapped['version'] != 1) throw const FormatException('未知密钥封装版本');
  final public = readBase64(wrapped, 'ephemeral', size: 32);
  final shared = await _exchange.sharedSecretKey(
      keyPair: recipient,
      remotePublicKey: SimplePublicKey(public, type: KeyPairType.x25519));
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: readBase64(wrapped, 'salt', size: 32),
      info: utf8.encode(context));
  final aad = utf8.encode(canonicalJson({
    'context': context,
    'ephemeral': base64Encode(public),
    'recipient': base64Encode((await recipient.extractPublicKey()).bytes)
  }));
  return _cipher.decrypt(
      SecretBox(readBase64(wrapped, 'ciphertext'),
          nonce: readBase64(wrapped, 'nonce', size: 12),
          mac: Mac(readBase64(wrapped, 'tag', size: 16))),
      secretKey: key,
      aad: aad);
}

class ConversationKey {
  final String conversationId;
  final int epoch;
  final List<int> bytes;
  ConversationKey(
      {required this.conversationId,
      required this.epoch,
      required List<int> bytes})
      : bytes = List.unmodifiable(bytes) {
    if (conversationId.isEmpty ||
        conversationId.length > 256 ||
        epoch < 1 ||
        epoch > 0x1fffffffffffff ||
        bytes.length != 32 ||
        bytes.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('无效会话密钥');
    }
  }
  factory ConversationKey.generate(String id, int epoch) =>
      ConversationKey(conversationId: id, epoch: epoch, bytes: secureBytes(32));
  String get context => 'zaizuo.conversation.v1:$conversationId:$epoch';
  Future<Map<String, dynamic>> wrapFor(IdentityPublic recipient,
      {required Identity sender, required String communityId}) async {
    final scope = '$context:$communityId';
    final body = <String, dynamic>{
      'version': 1,
      'community': communityId,
      'conversation': conversationId,
      'epoch': epoch,
      'sender': sender.public.accountId,
      'recipient': recipient.accountId,
      'wrapped': await wrapSecret(bytes, recipient.exchangeKey, context: scope)
    };
    return {'body': body, 'signature': await sender.sign(body)};
  }

  /// authorizedSender必须由上层当前会话成员/密钥管理权限判定后传入，不能信任信封自报公钥。
  static Future<ConversationKey> unwrap(
      Map<String, dynamic> envelope, Identity recipient,
      {required IdentityPublic authorizedSender,
      required String communityId}) async {
    final body =
        immutableProtocolObject(envelope['body'] as Map<String, dynamic>);
    if (body['version'] != 1 ||
        body['community'] != communityId ||
        body['sender'] != authorizedSender.accountId ||
        body['recipient'] != recipient.public.accountId ||
        !await verifySignature(body, readString(envelope, 'signature'),
            authorizedSender.signingKey)) throw StateError('密钥分发签名/社区/授权发送者不符');
    final id = readString(body, 'conversation');
    final epoch = readInt(body, 'epoch', min: 1);
    return ConversationKey(
        conversationId: id,
        epoch: epoch,
        bytes: await unwrapSecret(
            body['wrapped'] as Map<String, dynamic>, recipient.exchange,
            context: 'zaizuo.conversation.v1:$id:$epoch:$communityId'));
  }
}
