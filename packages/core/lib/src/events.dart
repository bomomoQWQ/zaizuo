import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'codec.dart';
import 'crypto.dart';
import 'devices.dart';

class EncryptedEvent {
  final Map<String, dynamic> header;
  final String ciphertext;
  final String nonce;
  final String tag;
  final String signature;
  EncryptedEvent._(Map<String, dynamic> header, this.ciphertext, this.nonce,
      this.tag, this.signature)
      : header = immutableProtocolObject(header);
  String get id => header['id'] as String;
  String get origin => header['origin'] as String;
  int get sequence => header['sequence'] as int;
  int get clock => header['clock'] as int;
  String? get previous => header['previous'] as String?;
  String get conversation => header['conversation'] as String;
  int get epoch => header['epoch'] as int;
  String get author => header['author'] as String;
  Map<String, dynamic> get signedBody =>
      {'header': header, 'ciphertext': ciphertext, 'nonce': nonce, 'tag': tag};
  Map<String, dynamic> toJson() => {...signedBody, 'signature': signature};

  static Future<EncryptedEvent> create(
      {required String communityId,
      required DeviceCredentials device,
      required ConversationKey key,
      required int sequence,
      required int clock,
      required String? previous,
      required Map<String, dynamic> body,
      String? eventId,
      DateTime? now}) async {
    final certificate = device.certificate;
    if (certificate == null ||
        sequence < 1 ||
        clock < 1 ||
        (sequence == 1) != (previous == null))
      throw StateError('设备未授权或事件链参数无效');
    final id = eventId ?? randomId();
    if (!RegExp(r'^[a-f0-9]{48}$').hasMatch(id)) throw ArgumentError('无效事件编号');
    final header = <String, dynamic>{
      'version': 1,
      'community': communityId,
      'id': id,
      'origin': certificate.id,
      'author': certificate.accountId,
      'sequence': sequence,
      'clock': clock,
      'previous': previous,
      'conversation': key.conversationId,
      'epoch': key.epoch,
      'created_at': (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch
    };
    // 一条事件只在发件端加密一次；副本转存原始信封，禁止重新加密。
    final secretBox = await AesGcm.with256bits().encrypt(
        utf8.encode(canonicalJson(body)),
        secretKey: SecretKey(key.bytes),
        aad: utf8.encode(canonicalJson(header)));
    final unsigned = <String, dynamic>{
      'header': header,
      'ciphertext': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(secretBox.nonce),
      'tag': base64Encode(secretBox.mac.bytes)
    };
    return EncryptedEvent._(
        header,
        unsigned['ciphertext'] as String,
        unsigned['nonce'] as String,
        unsigned['tag'] as String,
        await device.sign(unsigned));
  }

  factory EncryptedEvent.fromJson(Map<String, dynamic> value) {
    final header = value['header'];
    if (header is! Map<String, dynamic> ||
        header['version'] != 1 ||
        header.length != 11) throw const FormatException('无效事件头');
    readString(header, 'community', max: 128);
    for (final key in ['id', 'origin', 'author']) {
      if (!RegExp(key == 'id' ? r'^[a-f0-9]{48}$' : r'^[a-f0-9]{64}$')
          .hasMatch(readString(header, key))) throw FormatException('无效 $key');
    }
    final sequence = readInt(header, 'sequence', min: 1);
    readInt(header, 'clock', min: 1);
    readInt(header, 'created_at');
    readInt(header, 'epoch', min: 1);
    readString(header, 'conversation', max: 256);
    if ((sequence == 1) != (header['previous'] == null) ||
        (header['previous'] != null &&
            !RegExp(r'^[a-f0-9]{48}$').hasMatch(header['previous'] as String)))
      throw const FormatException('无效前驱事件');
    readBase64(value, 'nonce', size: 12);
    readBase64(value, 'tag', size: 16);
    readBase64(value, 'signature', size: 64);
    readBase64(value, 'ciphertext', max: 1048576);
    return EncryptedEvent._(
        header,
        value['ciphertext'] as String,
        value['nonce'] as String,
        value['tag'] as String,
        value['signature'] as String);
  }
  Future<bool> verify(DeviceCertificate certificate) async =>
      origin == certificate.id &&
      author == certificate.accountId &&
      header['community'] == certificate.communityId &&
      await verifySignature(signedBody, signature, certificate.signingPublic);
  Future<Map<String, dynamic>> decrypt(ConversationKey key) async {
    if (key.conversationId != conversation || key.epoch != epoch)
      throw StateError('会话密钥不匹配');
    final body = await AesGcm.with256bits().decrypt(
        SecretBox(base64Decode(ciphertext),
            nonce: base64Decode(nonce), mac: Mac(base64Decode(tag))),
        secretKey: SecretKey(key.bytes),
        aad: utf8.encode(canonicalJson(header)));
    return jsonObject(utf8.decode(body));
  }
}

class TrustStore {
  final String communityId;
  final Map<String, IdentityPublic> _accounts = {};
  final Map<String, DeviceCertificate> _devices = {};
  Map<String, IdentityPublic> get accounts => Map.unmodifiable(_accounts);
  Map<String, DeviceCertificate> get devices => Map.unmodifiable(_devices);
  final Set<String> revokedDevices = {};
  TrustStore(this.communityId);

  /// 这里只接受上层按社区信任根验证过的成员身份，不是开放注册入口。
  void trustAccount(IdentityPublic identity) {
    final previous = _accounts[identity.accountId];
    if (previous != null &&
        canonicalJson(previous.toJson()) != canonicalJson(identity.toJson()))
      throw StateError('身份密钥变更需要显式恢复/轮换证明');
    _accounts[identity.accountId] = identity;
  }

  Future<void> authorizeDevice(DeviceCertificate certificate) async {
    final owner = _accounts[certificate.accountId];
    if (owner == null || !await certificate.verify(owner, communityId))
      throw StateError('设备授权链不受信任');
    final previous = _devices[certificate.id];
    if (previous != null && previous.accountId != certificate.accountId) {
      throw StateError('同设备密钥不能静默更换所属账号');
    }
    _devices[certificate.id] = certificate;
  }

  Future<void> verifyEvent(EncryptedEvent event) async {
    final certificate = _devices[event.origin];
    if (certificate == null ||
        revokedDevices.contains(event.origin) ||
        !await event.verify(certificate)) throw StateError('事件签名/设备授权无效');
  }
}

/// 已验签事件按设备链补齐后才接纳；不能用“最高clock”跳过乱序缺口。
class EventIndex {
  // _byId covers accepted, pending and quarantined envelopes. Reusing a
  // pending id must not overwrite its signed content before a gap is filled.
  final Map<String, EncryptedEvent> _byId = {};
  final Map<String, String> _quarantined = {};
  Map<String, String> get quarantined => Map.unmodifiable(_quarantined);
  final Map<String, Map<int, EncryptedEvent>> _chains = {};
  final Map<String, Map<int, EncryptedEvent>> _pending = {};
  final List<EncryptedEvent> _ingested = [];
  int maxClock = 0;
  List<EncryptedEvent> get ingestionOrder => List.unmodifiable(_ingested);
  int headSequence(String origin) => _chains[origin]?.length ?? 0;
  String? headId(String origin) => _chains[origin]?[headSequence(origin)]?.id;
  int get pendingCount => _pending.values.fold(0, (n, v) => n + v.length);
  bool contains(String id) => _byId.containsKey(id);
  List<EncryptedEvent> sorted() => _ingested.toList()
    ..sort((a, b) {
      final byClock = a.clock.compareTo(b.clock);
      if (byClock != 0) return byClock;
      final byOrigin = a.origin.compareTo(b.origin);
      return byOrigin != 0 ? byOrigin : a.id.compareTo(b.id);
    });

  /// 调用方必须已完成授权和验签；返回本次真正接纳的事件（可能补齐多条）。
  List<EncryptedEvent> acceptVerified(EncryptedEvent event) {
    final existing = _byId[event.id];
    if (existing != null) {
      if (canonicalJson(existing.toJson()) != canonicalJson(event.toJson()))
        throw StateError('同一事件编号内容冲突');
      return [];
    }
    final chain = _chains.putIfAbsent(event.origin, () => {});
    final pending = _pending.putIfAbsent(event.origin, () => {});
    final conflicting = chain[event.sequence] ?? pending[event.sequence];
    if (conflicting != null && conflicting.id != event.id)
      throw StateError('设备事件链分叉');
    if (event.sequence > chain.length + 10000) throw StateError('设备序号缺口过大');
    if (pending.length >= 10000 && !pending.containsKey(event.sequence))
      throw StateError('待补事件过多');
    // Reject a directly supplied invalid next link without mutating the index.
    // A future link cannot be checked until the missing predecessor arrives.
    if (event.sequence == chain.length + 1) {
      final prev = chain[chain.length];
      if (event.previous != prev?.id ||
          (prev != null && event.clock <= prev.clock)) {
        throw StateError('事件链前驱/逻辑时钟不匹配');
      }
    }
    pending[event.sequence] = event;
    _byId[event.id] = event;
    final accepted = <EncryptedEvent>[];
    while (pending.containsKey(chain.length + 1)) {
      final next = pending[chain.length + 1]!;
      final prev = chain[chain.length];
      if (next.previous != prev?.id ||
          (prev != null && next.clock <= prev.clock)) {
        pending.remove(chain.length + 1);
        // The invalid future event may already be durable. Isolate it while
        // accepting the valid predecessor; do not poison every later import.
        _quarantined[next.id] = 'invalid_chain_link';
        break;
      }
      pending.remove(chain.length + 1);
      chain[next.sequence] = next;
      _byId[next.id] = next;
      _ingested.add(next);
      maxClock = maxClock > next.clock ? maxClock : next.clock;
      accepted.add(next);
    }
    return accepted;
  }

  /// 本地消费游标是“接纳顺序下标”，与消息显示排序无关；乱序旧消息不会被跳过。
  Map<String, dynamic> sync(
      {required String storeId, String? cursor, int limit = 100}) {
    if (limit < 1 || limit > 1000) throw ArgumentError('limit需1～1000');
    var after = 0;
    if (cursor != null) {
      final data = jsonObject(utf8.decode(base64Url.decode(cursor)));
      if (data['store'] != storeId) throw StateError('游标属于另一个本地日志，需重新同步');
      after = readInt(data, 'offset', max: _ingested.length);
    }
    final events = _ingested.skip(after).take(limit).toList();
    return {
      'events': events.map((e) => e.toJson()).toList(),
      'next_cursor': base64UrlEncode(utf8.encode(
          canonicalJson({'store': storeId, 'offset': after + events.length}))),
      'has_more': after + events.length < _ingested.length
    };
  }
}
