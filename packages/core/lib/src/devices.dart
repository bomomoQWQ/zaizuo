import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'codec.dart';
import 'crypto.dart';

class DeviceCertificate {
  final Map<String, dynamic> body;
  final String signature;
  DeviceCertificate(Map<String, dynamic> body, this.signature)
      : body = immutableProtocolObject(body);
  String get id => body['device'] as String;
  String get accountId => body['account'] as String;
  String get communityId => body['community'] as String;
  List<int> get signingPublic => readBase64(body, 'signing', size: 32);
  Map<String, dynamic> toJson() => {'body': body, 'signature': signature};
  factory DeviceCertificate.fromJson(Map<String, dynamic> value) =>
      DeviceCertificate(value['body'] as Map<String, dynamic>,
          readString(value, 'signature'));
  Future<bool> verify(IdentityPublic owner, String community,
      {DateTime? now}) async {
    try {
      if (body['version'] != 1 ||
          readString(body, 'account') != owner.accountId ||
          readString(body, 'community') != community) return false;
      final time = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
      if (readInt(body, 'created_at') > time + 300000) return false;
      readBase64(body, 'signing', size: 32);
      readBase64(body, 'exchange', size: 32);
      if (readString(body, 'device') !=
          await objectHash({
            'domain': 'zaizuo.device.v1',
            'signing': body['signing'],
            'exchange': body['exchange']
          })) return false;
      return await verifySignature(body, signature, owner.signingKey);
    } on FormatException {
      return false;
    }
  }
}

class DeviceCredentials {
  final SimpleKeyPair signing;
  final SimpleKeyPair exchange;
  DeviceCertificate? certificate;
  DeviceCredentials._(this.signing, this.exchange);
  static Future<DeviceCredentials> create() async => DeviceCredentials._(
      await Ed25519().newKeyPair(), await X25519().newKeyPair());
  Future<String> get id async => objectHash({
        'domain': 'zaizuo.device.v1',
        'signing': base64Encode((await signing.extractPublicKey()).bytes),
        'exchange': base64Encode((await exchange.extractPublicKey()).bytes)
      });
  Future<DeviceCertificate> authorize(Identity owner, String community,
      {DateTime? now}) async {
    final body = <String, dynamic>{
      'version': 1,
      'community': community,
      'account': owner.public.accountId,
      'device': await id,
      'signing': base64Encode((await signing.extractPublicKey()).bytes),
      'exchange': base64Encode((await exchange.extractPublicKey()).bytes),
      'created_at': (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch
    };
    return certificate = DeviceCertificate(body, await owner.sign(body));
  }

  Future<String> sign(Object? value) async => base64Encode((await Ed25519()
          .sign(utf8.encode(canonicalJson(value)), keyPair: signing))
      .bytes);
  Future<Map<String, dynamic>> exportPrivate() async => {
        'signing_seed': base64Encode(await signing.extractPrivateKeyBytes()),
        'exchange_seed': base64Encode(await exchange.extractPrivateKeyBytes()),
        'certificate': certificate?.toJson()
      };
  static Future<DeviceCredentials> importPrivate(
      Map<String, dynamic> value) async {
    final result = DeviceCredentials._(
        await Ed25519()
            .newKeyPairFromSeed(readBase64(value, 'signing_seed', size: 32)),
        await X25519()
            .newKeyPairFromSeed(readBase64(value, 'exchange_seed', size: 32)));
    if (value['certificate'] != null) {
      result.certificate = DeviceCertificate.fromJson(
          value['certificate'] as Map<String, dynamic>);
      if (result.certificate!.id != await result.id ||
          !equalBytes(result.certificate!.signingPublic,
              (await result.signing.extractPublicKey()).bytes) ||
          !equalBytes(
              readBase64(result.certificate!.body, 'exchange', size: 32),
              (await result.exchange.extractPublicKey()).bytes)) {
        throw const FormatException('设备证书与私钥不匹配');
      }
      // A matching id only binds local key material. The caller must still
      // authorize this certificate against its pinned community TrustStore.
    }
    return result;
  }
}

/// 扫码内容是请求的公钥、目标账号/社区、有效期和随机挑战；不包含私钥或 Git 令牌。
class PairingRequest {
  final Map<String, dynamic> body;
  PairingRequest._(Map<String, dynamic> body)
      : body = immutableProtocolObject(body);
  String get requestId => readString(body, 'request_id');
  String get accountId => readString(body, 'account');
  String get communityId => readString(body, 'community');
  String encode() =>
      'zaizuo://pair/v1/${base64UrlEncode(utf8.encode(canonicalJson(body)))}';
  static Future<PairingRequest> create(DeviceCredentials device,
          {required String accountId,
          required String communityId,
          DateTime? now,
          Duration lifetime = const Duration(minutes: 5)}) async =>
      PairingRequest._({
        'version': 1,
        'request_id': randomId(),
        'account': accountId,
        'community': communityId,
        'device': await device.id,
        'signing':
            base64Encode((await device.signing.extractPublicKey()).bytes),
        'exchange':
            base64Encode((await device.exchange.extractPublicKey()).bytes),
        'expires_at':
            (now ?? DateTime.now()).toUtc().add(lifetime).millisecondsSinceEpoch
      });
  static PairingRequest decode(String text) {
    const prefix = 'zaizuo://pair/v1/';
    if (!text.startsWith(prefix) || text.length > 8192)
      throw const FormatException('无效配对码');
    return PairingRequest._(jsonObject(
        utf8.decode(base64Url.decode(text.substring(prefix.length)))));
  }

  void validate(DateTime now) {
    readString(body, 'account', max: 128);
    readString(body, 'community', max: 128);
    readString(body, 'device', max: 128);
    if (body['version'] != 1 ||
        !RegExp(r'^[a-f0-9]{48}$').hasMatch(requestId) ||
        readInt(body, 'expires_at') <= now.toUtc().millisecondsSinceEpoch ||
        readInt(body, 'expires_at') >
            now.toUtc().add(const Duration(minutes: 10)).millisecondsSinceEpoch)
      throw const FormatException('配对请求已过期或格式无效');
    readBase64(body, 'signing', size: 32);
    readBase64(body, 'exchange', size: 32);
  }
}

class PairingApprover {
  final Set<String> _used = {};
  final Set<String> _inFlight = {};

  /// 必须在已解锁的可信设备上由用户明确确认；本类不自动批准陌生二维码。
  /// 一次性去重只限此实例；跨进程/重启去重需上层持久化审批检查点。
  Future<Map<String, dynamic>> approve(
      PairingRequest request, Identity owner, List<int> factor,
      {required String communityId, DateTime? now}) async {
    final time = now ?? DateTime.now();
    request.validate(time);
    if (request.accountId != owner.public.accountId ||
        request.communityId != communityId ||
        factor.length != 32 ||
        _used.contains(request.requestId) ||
        !_inFlight.add(request.requestId)) throw StateError('配对账号/社区不符或请求已使用');
    // Reserve before the first await; a concurrent approval cannot pass twice.
    final factorSnapshot = List<int>.of(factor);
    try {
      final deviceId = await objectHash({
        'domain': 'zaizuo.device.v1',
        'signing': request.body['signing'],
        'exchange': request.body['exchange']
      });
      if (request.body['device'] != deviceId)
        throw const FormatException('设备编号不符');
      final certificateBody = <String, dynamic>{
        'version': 1,
        'community': communityId,
        'account': owner.public.accountId,
        'device': deviceId,
        'signing': request.body['signing'],
        'exchange': request.body['exchange'],
        'created_at': time.toUtc().millisecondsSinceEpoch
      };
      final certificate =
          DeviceCertificate(certificateBody, await owner.sign(certificateBody));
      final body = <String, dynamic>{
        'request_id': request.requestId,
        'request_hash': await objectHash(request.body),
        'certificate': certificate.toJson(),
        'factor': await wrapSecret(
            factorSnapshot, readBase64(request.body, 'exchange', size: 32),
            context: 'zaizuo.pair.v1:${request.requestId}')
      };
      final response = {'body': body, 'signature': await owner.sign(body)};
      _used.add(request.requestId);
      return response;
    } finally {
      _inFlight.remove(request.requestId);
    }
  }
}

class PairingReceiver {
  bool _used = false;
  bool _inFlight = false;
  Future<List<int>> accept(Map<String, dynamic> response,
      PairingRequest request, DeviceCredentials device, IdentityPublic owner,
      {DateTime? now}) async {
    if (_used || _inFlight) throw StateError('配对响应已处理');
    request.validate(now ?? DateTime.now());
    if (request.accountId != owner.accountId) {
      throw StateError('配对目标账号不匹配');
    }
    _inFlight = true;
    try {
      final body =
          immutableProtocolObject(response['body'] as Map<String, dynamic>);
      final responseSignature = readString(response, 'signature');
      if (request.body['device'] != await device.id) {
        throw StateError('配对请求不是本机设备');
      }
      if (body['request_id'] != request.requestId ||
          body['request_hash'] != await objectHash(request.body) ||
          !await verifySignature(body, responseSignature, owner.signingKey))
        throw StateError('配对响应不匹配或验签失败');
      final certificate = DeviceCertificate.fromJson(
          body['certificate'] as Map<String, dynamic>);
      if (certificate.id != await device.id ||
          !await certificate.verify(owner, request.communityId, now: now))
        throw StateError('设备授权无效');
      final factor = await unwrapSecret(
          body['factor'] as Map<String, dynamic>, device.exchange,
          context: 'zaizuo.pair.v1:${request.requestId}');
      if (factor.length != 32) throw const FormatException('配对材料无效');
      device.certificate = certificate;
      _used = true;
      return factor;
    } finally {
      _inFlight = false;
    }
  }
}
