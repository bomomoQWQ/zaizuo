import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';

import 'local_profile.dart';
import 'replica.dart';

/// 仅存在于签名加密消息里的描述，Git附件分支只含不透明密文对象。
class AttachmentRef {
  final String scope;
  final int epoch;
  final AttachmentDescriptor descriptor;
  const AttachmentRef(this.scope, this.epoch, this.descriptor);
  factory AttachmentRef.fromJson(Map<String, dynamic> value) {
    if (value.length != 3 ||
        !value.keys.every({'scope', 'epoch', 'descriptor'}.contains))
      throw const FormatException('附件引用字段不符');
    return AttachmentRef(
        readString(value, 'scope', max: 256),
        readInt(value, 'epoch', min: 1),
        AttachmentDescriptor.fromJson(
            value['descriptor'] as Map<String, dynamic>));
  }
  Map<String, dynamic> toJson() =>
      {'scope': scope, 'epoch': epoch, 'descriptor': descriptor.toJson()};
}

/// 应用媒体入口：上传暂存加密；发送时按目的会话重新加密；下载每次重查原记录权限。
/// file_id只对一个本机主体有效，不是可共享的全局 bearer URL。
class MediaRepository {
  final LocalProfile profile;
  final EncryptedReplica replica;
  final GitSync? git;
  final int maxMediaBytes;
  final int maxHandles;
  final int maxStagedBytes;
  final int maxCacheBytes;
  final PreferredImageEncoder imageEncoder;
  late final EncryptedAttachments objects;
  Map<String, dynamic> _state = {};
  Future<void> _tail = Future.value();
  bool _closed = false;
  Future<void>? _closing;
  final Set<String> _publishedThisSession = {};
  MediaRepository._(
      this.profile,
      this.replica,
      this.git,
      this.maxMediaBytes,
      this.maxHandles,
      this.maxStagedBytes,
      this.maxCacheBytes,
      this.imageEncoder) {
    objects = EncryptedAttachments(
        Directory(p.join(profile.root.path, 'attachments')),
        maxBytes: maxMediaBytes);
  }
  static Future<MediaRepository> open(
      {required LocalProfile profile,
      required EncryptedReplica replica,
      GitSync? git,
      int maxMediaBytes = 8 * 1024 * 1024,
      int maxHandles = 4096,
      int maxStagedBytes = 128 * 1024 * 1024,
      int maxCacheBytes = 256 * 1024 * 1024,
      PreferredImageEncoder? imageEncoder}) async {
    if (maxMediaBytes < 1 ||
        maxMediaBytes > 20 * 1024 * 1024 ||
        maxHandles < 1 ||
        maxStagedBytes < maxMediaBytes ||
        maxCacheBytes < maxMediaBytes) throw ArgumentError('媒体资源限制不符');
    final media = MediaRepository._(
        profile,
        replica,
        git,
        maxMediaBytes,
        maxHandles,
        maxStagedBytes,
        maxCacheBytes,
        imageEncoder ??
            PreferredImageEncoder(
                maxInputBytes: maxMediaBytes, maxOutputBytes: maxMediaBytes));
    media._state = await profile.readSecretState('media-state.enc') ??
        {
          'version': 1,
          'entries': <String, dynamic>{},
          'outbox': <String, dynamic>{}
        };
    if (media._state['version'] != 1 ||
        media._state['entries'] is! Map ||
        media._state['outbox'] is! Map ||
        media._entries.length > maxHandles) throw StateError('本机媒体状态不符');
    return media;
  }

  Map<String, dynamic> get _entries =>
      _state['entries'] as Map<String, dynamic>;
  Map<String, dynamic> get _outbox => _state['outbox'] as Map<String, dynamic>;
  Future<T> _serial<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('媒体仓库已关闭'));
    final c = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        c.complete(await action());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<void> _save() => profile.writeSecretState('media-state.enc', _state);
  Future<void> _checkCacheSpace(int incoming) async {
    var used = 0;
    if (await objects.root.exists()) {
      await for (final entity in objects.root.list(followLinks: false)) {
        if (entity is File && p.basename(entity.path).endsWith('.bin'))
          used += (await entity.stat()).size;
        if (used + incoming > maxCacheBytes)
          throw const DomainException('quota_exceeded', '本机密文附件缓存已满，不自动清理历史文件');
      }
    }
    if (used + incoming > maxCacheBytes)
      throw const DomainException('quota_exceeded', '本机密文附件缓存已满');
  }

  Actor _actor(String actorId) {
    final actor = replica.service.actor(actorId);
    if (actor.ownerId != profile.identity.public.accountId)
      throw const DomainException('forbidden', '不能访问其他主体的本机媒体');
    return actor;
  }

  void _capacity() {
    if (_entries.length >= maxHandles)
      throw const DomainException('quota_exceeded', '本机媒体引用数量已达上限');
  }

  Future<Map<String, dynamic>> upload(
      {required String actorId,
      required String name,
      required List<int> bytes,
      String mime = 'application/octet-stream',
      String purpose = 'file'}) {
    if (bytes.isEmpty || bytes.length > maxMediaBytes)
      throw const DomainException('bad_request', '文件为空或超过上限');
    final snapshot = List<int>.from(bytes);
    return _serial(() async {
      _actor(actorId);
      if (!{'image', 'file'}.contains(purpose) ||
          snapshot.isEmpty ||
          snapshot.length > maxMediaBytes)
        throw const DomainException('bad_request', '文件类型或大小不符');
      _capacity();
      var content = snapshot;
      if (purpose == 'image') {
        content = await imageEncoder.encodeBytes(snapshot);
        mime = 'image/webp';
        name = _webpName(name);
      }
      if (content.length > maxMediaBytes)
        throw const DomainException('quota_exceeded', '编码后图片超过上限');
      var staged = 0;
      for (final raw in _entries.values) {
        final e = raw as Map<String, dynamic>;
        if (e['kind'] == 'staged') staged += readInt(e, 'size', min: 1);
      }
      if (staged + content.length > maxStagedBytes)
        throw const DomainException('quota_exceeded', '本机加密暂存配额已满');
      await _checkCacheSpace(content.length);
      final key = ConversationKey.generate(
          'stage:${profile.identity.public.accountId}:${randomId()}', 1);
      final descriptor =
          await objects.put(content, key, name: name, mime: mime);
      final id = randomId();
      _entries[id] = {
        'kind': 'staged',
        'actor': actorId,
        'purpose': purpose,
        'size': content.length,
        'key': base64Encode(key.bytes),
        'ref': AttachmentRef(key.conversationId, key.epoch, descriptor).toJson()
      };
      try {
        await _save();
      } catch (_) {
        _entries.remove(id);
        rethrow;
      }
      return {
        'file_id': id,
        'name': descriptor.name,
        'mime': descriptor.mime,
        'size': descriptor.size
      };
    });
  }

  String _webpName(String name) {
    // 名称是元数据，不允许用它选择本机路径。
    if (name.isEmpty ||
        name.length > 256 ||
        name.contains('/') ||
        name.contains('\\') ||
        name.codeUnits.any((c) => c < 32 || c == 127))
      throw const DomainException('bad_request', '无效文件名');
    final base = p.basenameWithoutExtension(name);
    return '${base.isEmpty ? 'image' : base.substring(0, base.length > 240 ? 240 : base.length)}.webp';
  }

  Future<Map<String, dynamic>> get(
          {required String actorId, required String fileId}) =>
      _serial(() async {
        final actor = _actor(actorId);
        final data = await _load(actor, fileId);
        return {
          'name': data.$2.name,
          'mime': data.$2.mime,
          'size': data.$1.length,
          'data': base64Encode(data.$1)
        };
      });
  Future<(List<int>, AttachmentDescriptor)> _load(
      Actor actor, String fileId) async {
    final raw = _entries[fileId];
    if (raw is! Map<String, dynamic> || raw['actor'] != actor.id)
      throw const DomainException('forbidden', '文件引用不存在或不属于当前主体');
    late AttachmentRef ref;
    late ConversationKey key;
    if (raw['kind'] == 'staged') {
      ref = AttachmentRef.fromJson(raw['ref'] as Map<String, dynamic>);
      key = ConversationKey(
          conversationId: ref.scope,
          epoch: ref.epoch,
          bytes: readBase64(raw, 'key', size: 32));
    } else {
      final record = _authorizedRecord(actor, readString(raw, 'record'));
      final index = readInt(raw, 'part', max: record.parts.length - 1);
      ref = _reference(record.parts[index]);
      if (ref.scope != _contentScope(record))
        throw const DomainException('forbidden', '附件引用与原记录范围不符');
      key = _key(ref);
      if (!await File(
              p.join(objects.root.path, '${ref.descriptor.objectId}.bin'))
          .exists()) {
        final transport = git;
        if (transport == null) throw StateError('附件未在本机且没有配置Git');
        await _checkCacheSpace(ref.descriptor.size);
        final ciphertext = await transport
            .fetchAttachment(ref.descriptor.objectId, maxBytes: maxMediaBytes);
        await objects.importCiphertext(ref.descriptor, ciphertext);
      }
    }
    final bytes = await objects.get(ref.descriptor, key);
    return (bytes, ref.descriptor);
  }

  ConversationKey _key(AttachmentRef ref) => replica.keys.firstWhere(
      (k) => k.conversationId == ref.scope && k.epoch == ref.epoch,
      orElse: () => throw StateError('没有原附件期次密钥'));
  AttachmentRef _reference(Map<String, dynamic> part) {
    if (!{'image', 'file'}.contains(part['type']))
      throw const DomainException('bad_request', '该消息段不是附件');
    final data = part['data'] as Map<String, dynamic>;
    return AttachmentRef.fromJson(data['attachment'] as Map<String, dynamic>);
  }

  MessageRecord _authorizedRecord(Actor actor, String id) {
    final service = replica.service;
    if (service.state.messages.containsKey(id))
      return service.message(actor: actor, messageId: id);
    if (service.state.feedPosts.containsKey(id)) {
      final post = service.feedPost(actor: actor, postId: id);
      return MessageRecord(
          id: post.id,
          conversationId: 'feed:${post.authorId}:${post.visibility}',
          senderId: post.authorId,
          parts: post.parts,
          createdAtMs: post.createdAtMs);
    }
    final comment = service.state.feedComments[id];
    if (comment != null) {
      final post = service.feedPost(actor: actor, postId: comment.postId);
      final visible = service
          .feedComments(actor: actor, postId: post.id)
          .where((c) => c.id == id);
      if (visible.isEmpty) throw const DomainException('forbidden', '评论不可见');
      return MessageRecord(
          id: comment.id,
          conversationId: 'feed:${post.authorId}:${post.visibility}',
          senderId: comment.authorId,
          parts: comment.parts,
          createdAtMs: comment.createdAtMs);
    }
    throw const DomainException('not_found', '原附件记录不存在或不可见');
  }

  Future<List<Map<String, dynamic>>> resolve(
      {required String actorId,
      required String conversationId,
      required List<Map<String, dynamic>> parts}) {
    final snapshot =
        jsonObject(canonicalJson({'parts': parts}))['parts'] as List;
    return _serial(() async {
      final actor = _actor(actorId);
      if (!snapshot.any((p) => {'image', 'file'}.contains((p as Map)['type'])))
        return snapshot.map((p) => p as Map<String, dynamic>).toList();
      // bot读权限不能被收文件借走；写权限由Node/adapter候选业务检查，仍不跳过最终execute。
      await replica.ensureConversationKey(conversationId);
      final key = replica.keys
          .where((k) => k.conversationId == conversationId)
          .reduce((a, b) => a.epoch > b.epoch ? a : b);
      final result = <Map<String, dynamic>>[];
      for (final raw in snapshot) {
        final part = raw as Map<String, dynamic>;
        if (!{'image', 'file'}.contains(part['type'])) {
          result.add(part);
          continue;
        }
        final data = part['data'] as Map<String, dynamic>;
        if (data.keys.any((k) => !{'file_id', 'name', 'mime'}.contains(k)))
          throw const DomainException('bad_request', '发送附件只接受受控file_id');
        final fileId = readString(data, 'file_id');
        final entry = _entries[fileId];
        if (entry is! Map ||
            entry['actor'] != actor.id ||
            (part['type'] == 'image' && entry['purpose'] != 'image'))
          throw const DomainException('forbidden', '附件类型或主体不符');
        if (_outbox.length >= maxHandles)
          throw const DomainException('quota_exceeded', '附件归档索引已满');
        final (clear, source) = await _load(actor, fileId);
        await _checkCacheSpace(clear.length);
        final descriptor =
            await objects.put(clear, key, name: source.name, mime: source.mime);
        final ref = AttachmentRef(key.conversationId, key.epoch, descriptor);
        _outbox[descriptor.objectId] = descriptor.toJson();
        await _save();
        // 若配置远端，先把对象可靠发布，再让消息引用它；失败不伪报发送成功。
        if (git != null) await _publish(descriptor);
        result.add({
          'type': part['type'],
          'data': {'attachment': ref.toJson()}
        });
      }
      return result;
    });
  }

  Future<List<Map<String, dynamic>>> project(
          {required String actorId, required MessageRecord message}) =>
      _serial(() async {
        final actor = _actor(actorId);
        final record = _authorizedRecord(actor, message.id);
        if (canonicalJson(record.toJson()) != canonicalJson(message.toJson()))
          throw const DomainException('forbidden', '投影原记录不符');
        final parts = <Map<String, dynamic>>[];
        var changed = false;
        for (var index = 0; index < record.parts.length; index++) {
          final part = record.parts[index];
          if (!{'image', 'file'}.contains(part['type'])) {
            parts.add(part);
            continue;
          }
          final ref = _reference(part);
          if (ref.scope != _contentScope(record))
            throw const DomainException('forbidden', '附件不属于该内容范围');
          final existing = _entries.entries.where((e) =>
              e.value is Map &&
              e.value['kind'] == 'record' &&
              e.value['actor'] == actorId &&
              e.value['record'] == record.id &&
              e.value['part'] == index);
          late String id;
          if (existing.isNotEmpty) {
            id = existing.first.key;
          } else {
            _capacity();
            id = randomId();
            changed = true;
            _entries[id] = {
              'kind': 'record',
              'actor': actorId,
              'record': record.id,
              'part': index,
              'purpose': part['type']
            };
          }
          parts.add({
            'type': part['type'],
            'data': {
              'file_id': id,
              'name': ref.descriptor.name,
              'mime': ref.descriptor.mime
            }
          });
        }
        if (changed) await _save();
        return parts;
      });
  String _contentScope(MessageRecord record) {
    final conversation =
        replica.service.state.conversations[record.conversationId];
    if (conversation?.kind == 'forumThread')
      return replica.service.state.forumPosts[conversation!.postId]!.roomId;
    return record.conversationId;
  }

  Future<void> _publish(AttachmentDescriptor descriptor) async {
    if (git == null || _publishedThisSession.contains(descriptor.objectId))
      return;
    await git!.publishAttachment(
        objectId: descriptor.objectId,
        ciphertext:
            File(p.join(objects.root.path, '${descriptor.objectId}.bin')));
    _publishedThisSession.add(descriptor.objectId);
  }

  Future<void> flushUploads() => _serial(() async {
        if (git == null) return;
        for (final raw in _outbox.values)
          await _publish(
              AttachmentDescriptor.fromJson(raw as Map<String, dynamic>));
        // 不删除outbox，后续同步仍检查附件存在；不会悄悄清理历史图片。
      });
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    return _closing = () async {
      await _tail;
    }();
  }
}
