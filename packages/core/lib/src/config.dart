import 'dart:convert';

import 'codec.dart';
import 'crypto.dart';

/// 社区根文件由根身份签名，根公钥的指纹必须从仓库外核对并钉住。
class CommunityManifest {
  final Map<String, dynamic> body;
  final String signature;
  CommunityManifest._(Map<String, dynamic> body, this.signature)
      : body = immutableProtocolObject(body);
  String get communityId => readString(body, 'community_id');
  int get revision => readInt(body, 'revision', min: 1);
  IdentityPublic get owner =>
      IdentityPublic.fromJson(body['owner'] as Map<String, dynamic>);
  List<IdentityPublic> get accounts => (body['accounts'] as List)
      .map((e) => IdentityPublic.fromJson(e as Map<String, dynamic>))
      .toList(growable: false);
  Map<String, dynamic> toJson() => {'body': body, 'signature': signature};
  Future<String> fingerprint() => objectHash({
        'domain': 'zaizuo.trust.v1',
        'community': communityId,
        'root_key': base64Encode(owner.signingKey)
      });
  static Future<CommunityManifest> create(Identity owner,
      {String? communityId,
      String title = '在座社区',
      int revision = 1,
      List<IdentityPublic> accounts = const [],
      String? previousHash,
      Map<String, dynamic> settings = const {}}) async {
    final all = {
      owner.public.accountId: owner.public,
      for (final a in accounts) a.accountId: a
    };
    final body = immutableProtocolObject(<String, dynamic>{
      'version': 1,
      'community_id': communityId ?? randomId(),
      'title': title,
      'revision': revision,
      'previous_hash': previousHash,
      'owner': owner.public.toJson(),
      'accounts': all.values.map((e) => e.toJson()).toList(),
      'settings': settings
    });
    return CommunityManifest._(body, await owner.sign(body));
  }

  factory CommunityManifest.fromJson(Map<String, dynamic> value) {
    final body = value['body'] as Map<String, dynamic>;
    if (body['version'] != 1) throw const FormatException('未知社区格式');
    return CommunityManifest._(body, readString(value, 'signature'));
  }
  Future<void> verify(String pinnedFingerprint,
      {CommunityManifest? previous}) async {
    // Validate the initial revision too; omitting `previous` is not permission
    // for malformed/negative revision or chain metadata.
    revision;
    readString(body, 'community_id', max: 128);
    readString(body, 'title', max: 4096);
    final previousHash = body['previous_hash'];
    if ((revision == 1 && previousHash != null) ||
        (revision > 1 &&
            (previousHash is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(previousHash)))) {
      throw const FormatException('无效社区配置版本链');
    }
    if (await fingerprint() != pinnedFingerprint ||
        !await verifySignature(body, signature, owner.signingKey))
      throw StateError('社区指纹或根签名不符');
    if (accounts.map((a) => a.accountId).toSet().length != accounts.length ||
        accounts.map((a) => a.name).toSet().length != accounts.length)
      throw const FormatException('社区成员编号或账号名重复');
    if (!accounts.any((account) =>
        canonicalJson(account.toJson()) == canonicalJson(owner.toJson()))) {
      throw const FormatException('社区根身份必须在成员列表内且密钥一致');
    }
    for (final a in accounts) {
      if (a.accountId !=
          await objectHash({'domain': 'zaizuo.account.v1', 'name': a.name}))
        throw const FormatException('账户编号不匹配');
    }
    if (previous != null &&
        (communityId != previous.communityId ||
            revision != previous.revision + 1 ||
            body['previous_hash'] != await objectHash(previous.toJson())))
      throw StateError('社区配置回退/断链；需要人工核对');
  }

  String invitation({required String repository}) =>
      'zaizuo://community/v1/${base64UrlEncode(utf8.encode(canonicalJson({
            'repository': repository,
            'community': communityId,
            'root_key': base64Encode(owner.signingKey)
          })))}';
}

class PowerPolicy {
  final String mode;
  final Duration foregroundPoll;
  final Duration backgroundPoll;
  const PowerPolicy._(this.mode, this.foregroundPoll, this.backgroundPoll);
  static const balanced =
      PowerPolicy._('balanced', Duration(seconds: 30), Duration(minutes: 15));
  static const saver =
      PowerPolicy._('saver', Duration(minutes: 1), Duration(minutes: 30));
  static const manual = PowerPolicy._('manual', Duration.zero, Duration.zero);

  /// 调度计划不是 Android 后台准时执行保证；系统允许时才运行。
  Duration nextDelay({required bool foreground, required int failures}) {
    final base = foreground ? foregroundPoll : backgroundPoll;
    if (base == Duration.zero) return base;
    final capped = failures.clamp(0, 6);
    return Duration(milliseconds: base.inMilliseconds * (1 << capped));
  }
}
