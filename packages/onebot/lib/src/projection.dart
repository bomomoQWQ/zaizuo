import 'dart:async';
import 'dart:collection';

import 'package:crypto/crypto.dart';

import 'backend.dart';
import 'id_map.dart';
import 'message_codec.dart';
import 'media.dart';

const oneBotImplementation = 'zaizuo';
const oneBotImplementationVersion = '0.1.0';

class OneBotEvent {
  const OneBotEvent(this.v11, this.v12);
  final Map<String, dynamic> v11;
  final Map<String, dynamic> v12;
  Map<String, dynamic> forVersion(int version) => version == 11 ? v11 : v12;
}

/// 同一已授权 bot 的双版本投影，HTTP 轮询缓冲独立于 WS 推送。
class OneBotProjection {
  OneBotProjection(
      {required this.backend,
      OneBotIdMap? ids,
      this.eventBufferSize = 256,
      this.maxLongPollSeconds = 30,
      this.maxConcurrentActions = 32,
      this.maxConcurrentMediaActions = 2})
      : ids = ids ?? OneBotIdMap() {
    if (eventBufferSize < 1 ||
        maxLongPollSeconds < 0 ||
        maxConcurrentActions < 1 ||
        maxConcurrentMediaActions < 1) {
      throw ArgumentError('Invalid event limits');
    }
    codec = OneBotMessageCodec(this.ids, allowMedia: mediaEnabled);
    this.ids.encode('user', backend.botId);
    _subscription = backend.messages.listen(_receive, onError: (Object _) {
      // 后端流错误不回显内部数据；状态变为 degraded，不能宣称 good。
      _healthy = false;
    });
  }
  final OneBotBackend backend;
  final OneBotIdMap ids;
  late final OneBotMessageCodec codec;
  final int eventBufferSize;
  final int maxLongPollSeconds;
  final int maxConcurrentActions;
  int _activeActions = 0;
  final int maxConcurrentMediaActions;
  int _activeMediaActions = 0;
  bool get mediaEnabled =>
      backend is OneBotMediaBackend &&
      (backend as OneBotMediaBackend).mediaEnabled;
  final _events = StreamController<OneBotEvent>.broadcast(sync: true);
  final _buffer = Queue<BotMessage>();
  late final StreamSubscription<BotMessage> _subscription;
  Completer<void>? _waiter;
  bool _polling = false;
  bool _closed = false;
  bool _healthy = true;
  int droppedEvents = 0;
  Stream<OneBotEvent> get events => _events.stream;
  Map<String, dynamic> get self =>
      {'platform': 'zaizuo', 'user_id': backend.botId};

  static const actions11 = [
    'send_msg',
    'send_private_msg',
    'send_group_msg',
    'get_login_info',
    'get_friend_list',
    'get_group_list',
    'get_group_member_list',
    'get_msg',
    'get_status',
    'get_version_info',
  ];
  static const actions12 = [
    'send_message',
    'get_self_info',
    'get_user_info',
    'get_friend_list',
    'get_group_list',
    'get_group_info',
    'get_group_member_list',
    'get_supported_actions',
    'get_status',
    'get_version',
    'get_latest_events',
  ];

  static const channelActions12 = [
    'get_guild_list',
    'get_guild_info',
    'get_channel_list',
    'get_channel_info',
  ];
  static const socialActions = [
    'zaizuo.post_forum',
    'zaizuo.reply_forum',
    'zaizuo.get_posts',
    'zaizuo.post_feed',
    'zaizuo.get_feed',
    'zaizuo.comment_feed',
    'zaizuo.like_feed',
  ];
  static const mediaActions11 = ['zaizuo.upload_file', 'zaizuo.get_file'];
  static const mediaActions12 = ['upload_file', 'get_file'];
  List<String> get supportedActions11 => [
        ...actions11,
        if (backend is OneBotSocialBackend) ...socialActions,
        if (mediaEnabled) ...mediaActions11
      ];
  List<String> get supportedActions12 => [
        ...actions12,
        if (backend is OneBotChannelBackend) ...channelActions12,
        if (backend is OneBotSocialBackend) ...socialActions,
        if (mediaEnabled) ...mediaActions12
      ];

  void _receive(BotMessage message) {
    if (_closed || ids.persistenceFailed) return;
    try {
      _publish(message);
    } catch (_) {
      // ID映射同步落盘失败/后端坏数据不可变成未捕获stream异常或伪成功。
      _healthy = false;
      droppedEvents++;
    }
  }

  void _publish(BotMessage message) {
    if (_buffer.length >= eventBufferSize) {
      _buffer.removeFirst();
      droppedEvents++;
    }
    _buffer.add(message);
    _waiter?.complete();
    _waiter = null;
    final outgoing = message.sender.id == backend.botId;
    final v11 = messageData(message, 11)
      ..addAll({
        'self_id': ids.encode('user', backend.botId),
        'post_type': outgoing ? 'notice' : 'message',
        if (outgoing) 'notice_type': 'zaizuo.message_sent',
        'sub_type': message.detailType == 'group' ? 'normal' : 'friend',
        'font': 0,
        if (message.detailType == 'group') 'anonymous': null,
        'raw_message': CqCodec.format(codec.encode(message.parts, 11)),
      });
    final v12 = <String, dynamic>{
      'id': 'zaizuo.message:${message.id}',
      'self': self,
      'time': message.createdAtMs / 1000,
      'type': outgoing ? 'notice' : 'message',
      'detail_type': outgoing
          ? 'zaizuo.message_sent'
          : message.guildId != null
              ? 'channel'
              : message.detailType,
      'sub_type': '',
      'message_id': message.id,
      'message': codec.encode(message.parts, 12),
      'alt_message': codec.alt(message.parts),
      'user_id': message.sender.id,
      if (message.groupId != null && message.guildId == null)
        'group_id': message.groupId,
      if (message.guildId != null) ...{
        'guild_id': message.guildId,
        'channel_id': message.channelId
      },
      if (outgoing) 'zaizuo.detail_type': message.detailType,
    };
    _events.add(OneBotEvent(v11, v12));
  }

  Map<String, dynamic> profile(BotProfile value, int version,
      {bool member = false, String? groupId}) {
    if (version == 12)
      return {
        'user_id': value.id,
        'user_name': value.name,
        'user_displayname': value.displayName,
        if (!member) 'user_remark': value.remark,
      };
    return {
      'user_id': ids.encode('user', value.id),
      'nickname': value.name,
      if (!member) 'remark': value.remark,
      if (member) ...{
        'group_id': ids.encode('group', groupId!),
        'card': value.displayName,
        'sex': 'unknown',
        'age': 0,
        'area': '',
        'join_time': 0,
        'last_sent_time': 0,
        'level': '',
        'role': value.role,
        'unfriendly': false,
        'title': '',
        'title_expire_time': 0,
        'card_changeable': false,
      },
    };
  }

  Map<String, dynamic> group(BotGroup value, int version) => {
        'group_id': version == 11 ? ids.encode('group', value.id) : value.id,
        'group_name': value.name,
        if (version == 11) ...{
          'member_count': value.memberCount,
          'max_member_count': value.maxMemberCount
        },
      };

  Map<String, dynamic> messageData(BotMessage value, int version) => {
        'time': version == 11
            ? value.createdAtMs ~/ 1000
            : value.createdAtMs / 1000,
        'message_type': value.detailType,
        'message_id':
            version == 11 ? ids.encode('message', value.id) : value.id,
        if (version == 11) 'real_id': ids.encode('message', value.id),
        'user_id': version == 11
            ? ids.encode('user', value.sender.id)
            : value.sender.id,
        if (value.groupId != null)
          'group_id': version == 11
              ? ids.encode('group', value.groupId!)
              : value.groupId,
        'sender': profile(value.sender, version),
        'message': codec.encode(value.parts, version),
      };

  Future<Map<String, dynamic>> handle(int version, Object? request) async {
    if (version != 11 && version != 12) throw ArgumentError.value(version);
    final echoPresent = request is Map && request.containsKey('echo');
    final echo = request is Map ? request['echo'] : null;
    if (_activeActions >= maxConcurrentActions) {
      return failure(version,
          const OneBotFailure('rate_limited', 'Too many pending actions'),
          echoPresent: echoPresent, echo: echo);
    }
    _activeActions++;
    try {
      if (_closed || ids.persistenceFailed) {
        throw const OneBotFailure(
            'unavailable', 'OneBot is closed or mapping persistence failed');
      }
      if (request is! Map ||
          request['action'] is! String ||
          (request['action'] as String).isEmpty ||
          (version == 12 && request['params'] is! Map) ||
          (request.containsKey('params') && request['params'] is! Map) ||
          (version == 12 && echoPresent && echo is! String)) {
        throw const OneBotFailure('bad_request', 'Invalid action request');
      }
      final params = Map<String, dynamic>.from(request['params'] as Map? ?? {});
      _checkSelf(request, params, version);
      final action = request['action'] as String;
      if ((socialActions.contains(action) ||
              mediaActions11.contains(action) ||
              mediaActions12.contains(action)) &&
          request.keys.any((key) =>
              !{'action', 'params', 'echo', 'self', 'self_id'}.contains(key))) {
        throw const OneBotFailure(
            'unsupported_param', 'Unknown social action envelope field');
      }
      if (!(version == 11 ? supportedActions11 : supportedActions12)
          .contains(action)) {
        throw const OneBotFailure(
            'unsupported_action', 'Action is not implemented');
      }
      final data = await _action(version, action, params);
      if (ids.persistenceFailed) {
        throw const OneBotFailure('unavailable',
            'Mapping persistence failed; action outcome may be unknown');
      }
      return {
        'status': 'ok',
        'retcode': 0,
        'data': data,
        if (version == 12) 'message': '',
        if (echoPresent && (version == 11 || echo is String)) 'echo': echo,
      };
    } on OneBotFailure catch (error) {
      return failure(version, error, echoPresent: echoPresent, echo: echo);
    } catch (_) {
      return failure(
          version, const OneBotFailure('internal', 'Internal handler error'),
          echoPresent: echoPresent, echo: echo);
    } finally {
      _activeActions--;
    }
  }

  Map<String, dynamic> failure(int version, OneBotFailure error,
          {bool echoPresent = false, Object? echo}) =>
      {
        'status': 'failed',
        'retcode': _retcode(version, error.code),
        'data': null,
        'message': error.message,
        'zaizuo.code': error.code,
        if (echoPresent && (version == 11 || echo is String)) 'echo': echo,
      };

  void _checkSelf(Map request, Map params, int version) {
    for (final container in [request, params]) {
      if (container.containsKey('self')) {
        final value = container['self'];
        if (value is! Map ||
            value['platform'] != 'zaizuo' ||
            value['user_id'] != backend.botId) {
          throw const OneBotFailure(
              'unknown_self', 'Self does not match bound bot');
        }
      }
      if (container.containsKey('self_id')) {
        if (version == 12 ||
            ids.decode('user', container['self_id']) != backend.botId) {
          throw const OneBotFailure(
              'unknown_self', 'Self does not match bound bot');
        }
      }
    }
  }

  String _id(
      Map<String, dynamic> params, String key, int version, String space) {
    final value = params[key];
    if (version == 12) {
      if (value is! String || value.isEmpty) {
        throw const OneBotFailure('bad_param', 'Expected nonempty string ID');
      }
      return value;
    }
    if (value is! int && value is! String) {
      throw const OneBotFailure('bad_param', 'Expected integer ID');
    }
    final native = ids.decode(space, value);
    if (native == null)
      throw const OneBotFailure('not_found', 'Unknown mapped ID');
    return native;
  }

  Future<Object?> _action(
      int version, String action, Map<String, dynamic> p) async {
    if (socialActions.contains(action))
      return _socialAction(version, action, p);
    if (mediaActions11.contains(action) || mediaActions12.contains(action)) {
      return _mediaAction(version, action, p);
    }
    switch (action) {
      case 'send_message':
      case 'send_msg':
      case 'send_private_msg':
      case 'send_group_msg':
        final String type;
        if (version == 12) {
          type = p['detail_type'] is String ? p['detail_type'] as String : '';
        } else if (action == 'send_private_msg') {
          type = 'private';
        } else if (action == 'send_group_msg') {
          type = 'group';
        } else {
          type = p['message_type'] as String? ??
              (p.containsKey('group_id')
                  ? 'group'
                  : p.containsKey('user_id')
                      ? 'private'
                      : '');
        }
        if (type != 'private' &&
            type != 'group' &&
            !(version == 12 &&
                type == 'channel' &&
                backend is OneBotChannelBackend)) {
          throw const OneBotFailure(
              'unsupported_param', 'Unsupported detail_type');
        }
        final allowed = version == 11
            ? {
                'message_type',
                'user_id',
                'group_id',
                'message',
                'auto_escape',
                'self',
                'self_id'
              }
            : {
                'detail_type',
                'user_id',
                'group_id',
                'guild_id',
                'channel_id',
                'message',
                'self'
              };
        if (p.keys.any((key) => !allowed.contains(key))) {
          throw const OneBotFailure(
              'unsupported_param', 'Unsupported send parameter');
        }
        var autoEscape = false;
        if (p.containsKey('auto_escape')) {
          final raw = p['auto_escape'];
          if (raw != true &&
              raw != false &&
              raw != 'true' &&
              raw != 'false' &&
              raw != '1' &&
              raw != '0') {
            throw const OneBotFailure('bad_param', 'Invalid auto_escape');
          }
          autoEscape = raw == true || raw == 'true' || raw == '1';
        }
        final target = _id(
            p,
            type == 'private'
                ? 'user_id'
                : type == 'channel'
                    ? 'channel_id'
                    : 'group_id',
            version,
            type == 'private' ? 'user' : 'group');
        final parts =
            codec.decode(p['message'], version, autoEscape: autoEscape);
        final sent = type == 'channel'
            ? await (backend as OneBotChannelBackend).sendChannel(
                guildId: _id(p, 'guild_id', version, 'group'),
                channelId: target,
                parts: parts)
            : await backend.send(
                detailType: type, targetId: target, parts: parts);
        // 12 原生编号和 11 映射在此同时登记，跨协议查询稳定。
        final mapped = ids.encode('message', sent.id);
        return {
          'message_id': version == 11 ? mapped : sent.id,
          if (version == 12) 'time': sent.createdAtMs / 1000
        };
      case 'get_login_info':
        final value = await backend.getSelf();
        return {
          'user_id': ids.encode('user', value.id),
          'nickname': value.name
        };
      case 'get_self_info':
        final value = await backend.getSelf();
        return {
          'user_id': value.id,
          'user_name': value.name,
          'user_displayname': value.displayName
        };
      case 'get_user_info':
        return profile(
            await backend.getUser(_id(p, 'user_id', version, 'user')), version);
      case 'get_friend_list':
        return (await backend.getFriends())
            .map((value) => profile(value, version))
            .toList();
      case 'get_group_list':
        return (await backend.getGroups())
            .map((value) => group(value, version))
            .toList();
      case 'get_group_info':
        return group(
            await backend.getGroup(_id(p, 'group_id', version, 'group')),
            version);
      case 'get_group_member_list':
        final id = _id(p, 'group_id', version, 'group');
        return (await backend.getGroupMembers(id))
            .map((value) => profile(value, version, member: true, groupId: id))
            .toList();
      case 'get_msg':
        return messageData(
            await backend.getMessage(_id(p, 'message_id', version, 'message')),
            version);
      case 'get_status':
        final online = await backend.isOnline();
        return version == 11
            ? {
                'online': online,
                'good': online && _healthy,
                'zaizuo.dropped_events': droppedEvents
              }
            : {
                'good': online && _healthy,
                'bots': [
                  {'self': self, 'online': online}
                ],
                'zaizuo.dropped_events': droppedEvents,
              };
      case 'get_version_info':
        return {
          'app_name': 'zaizuo',
          'app_version': oneBotImplementationVersion,
          'protocol_version': 'v11',
          'zaizuo.supported_actions': supportedActions11,
          'zaizuo.compatibility': 'subset'
        };
      case 'get_version':
        return {
          'impl': oneBotImplementation,
          'version': oneBotImplementationVersion,
          'onebot_version': '12',
          'zaizuo.compatibility': 'subset'
        };
      case 'get_guild_list':
        final values = await (backend as OneBotChannelBackend).getGuilds();
        return values
            .map((value) => {'guild_id': value.id, 'guild_name': value.name})
            .toList();
      case 'get_guild_info':
        final value = await (backend as OneBotChannelBackend)
            .getGuild(_id(p, 'guild_id', version, 'group'));
        return {'guild_id': value.id, 'guild_name': value.name};
      case 'get_channel_list':
        if (p.containsKey('joined_only') && p['joined_only'] is! bool) {
          throw const OneBotFailure('bad_param', 'joined_only must be bool');
        }
        // 域内没有独立频道加入状态：可见频道即已有空间/房间读权限的频道。
        final values = await (backend as OneBotChannelBackend)
            .getChannels(_id(p, 'guild_id', version, 'group'));
        return values
            .map(
                (value) => {'channel_id': value.id, 'channel_name': value.name})
            .toList();
      case 'get_channel_info':
        final value = await (backend as OneBotChannelBackend).getChannel(
            _id(p, 'guild_id', version, 'group'),
            _id(p, 'channel_id', version, 'group'));
        return {'channel_id': value.id, 'channel_name': value.name};
      case 'get_supported_actions':
        return supportedActions12;
      case 'get_latest_events':
        return _latestEvents(p);
    }
    throw const OneBotFailure(
        'unsupported_action', 'Action is not implemented');
  }

  Future<Object?> _mediaAction(
      int version, String action, Map<String, dynamic> p) async {
    if (!mediaEnabled)
      throw const OneBotFailure(
          'unsupported_action', 'Media is not configured');
    if (_activeMediaActions >= maxConcurrentMediaActions) {
      throw const OneBotFailure('rate_limited', 'Too many media actions');
    }
    _activeMediaActions++;
    try {
      final media = backend as OneBotMediaBackend;
      final upload = action.endsWith('upload_file');
      final allowed = upload
          ? {'type', 'name', 'data', 'sha256', 'zaizuo.mime', 'zaizuo.purpose'}
          : {'type', 'file_id'};
      if (p.keys.any((key) =>
          !allowed.contains(key) && key != 'self' && key != 'self_id')) {
        throw const OneBotFailure(
            'unsupported_param', 'Unknown media parameter');
      }
      if (p['type'] != 'data') {
        throw const OneBotFailure('unsupported_param',
            'Only type=data is supported; URL/path are forbidden');
      }
      if (upload) {
        final name = sanitizeMediaName(p['name']);
        final mime =
            validateMediaMime(p['zaizuo.mime'] ?? 'application/octet-stream');
        final purpose = validateMediaPurpose(p['zaizuo.purpose'] ?? 'file');
        if (purpose == 'image' && !mime.startsWith('image/')) {
          throw const OneBotFailure(
              'bad_param', 'Image purpose requires an image MIME type');
        }
        final bytes = decodeMediaBase64(p['data'], media.maxMediaBytes);
        if (p.containsKey('sha256')) {
          final digest = p['sha256'];
          if (digest is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
              sha256.convert(bytes).toString() != digest) {
            throw const OneBotFailure('bad_param', 'File checksum mismatch');
          }
        }
        final result = await media.uploadFile(
            name: name, bytes: bytes, mime: mime, purpose: purpose);
        return {'file_id': validateOpaqueFileId(result['file_id'])};
      }
      final result = await media.getFile(validateOpaqueFileId(p['file_id']));
      final bytes = decodeMediaBase64(result['data'], media.maxMediaBytes);
      if (result.containsKey('size') && result['size'] != bytes.length) {
        throw const OneBotFailure('internal', 'Media backend size mismatch');
      }
      return {
        'name': sanitizeMediaName(result['name']),
        'data': result['data'],
        'zaizuo.mime':
            validateMediaMime(result['mime'] ?? 'application/octet-stream'),
        'zaizuo.size': bytes.length
      };
    } finally {
      _activeMediaActions--;
    }
  }

  Future<Object?> _socialAction(
      int version, String action, Map<String, dynamic> p) async {
    if (backend is! OneBotSocialBackend) {
      throw const OneBotFailure(
          'unsupported_action', 'Social backend is not installed');
    }
    final social = backend as OneBotSocialBackend;
    final allowed = switch (action) {
      'zaizuo.post_forum' => {'room_id', 'title', 'message', 'idempotency_key'},
      'zaizuo.reply_forum' => {'post_id', 'message', 'idempotency_key'},
      'zaizuo.get_posts' => {'room_id', 'limit', 'before_id'},
      'zaizuo.post_feed' => {'message', 'visibility', 'idempotency_key'},
      'zaizuo.get_feed' => {'author_id', 'post_id', 'limit', 'before_id'},
      'zaizuo.comment_feed' => {'post_id', 'message', 'idempotency_key'},
      'zaizuo.like_feed' => {'post_id', 'liked', 'idempotency_key'},
      _ => <String>{},
    };
    if (p.keys.any(
        (key) => !allowed.contains(key) && key != 'self' && key != 'self_id')) {
      throw const OneBotFailure(
          'unsupported_param', 'Unknown social extension parameter');
    }
    String? string(String key, {bool required = false}) {
      if (!p.containsKey(key) && !required) return null;
      final value = p[key];
      if (value is! String || value.isEmpty) {
        throw OneBotFailure('bad_param', 'Expected nonempty $key string');
      }
      return value;
    }

    final idempotency = string('idempotency_key');
    final limit = p['limit'] ?? 50;
    if (limit is! int || limit < 1 || limit > 100) {
      throw const OneBotFailure('bad_param', 'Extension limit must be 1..100');
    }
    // 扩展返回始终为原生字符串ID与v12式消息段；11输入CQ仍按11解析。
    List<Map<String, dynamic>> message() => codec.decode(p['message'], version);
    switch (action) {
      case 'zaizuo.post_forum':
        return social.postForum(
            roomId: string('room_id', required: true)!,
            title: string('title', required: true)!,
            parts: message(),
            idempotencyKey: idempotency);
      case 'zaizuo.reply_forum':
        return social.replyForum(
            postId: string('post_id', required: true)!,
            parts: message(),
            idempotencyKey: idempotency);
      case 'zaizuo.get_posts':
        return social.getPosts(
            roomId: string('room_id', required: true)!,
            limit: limit,
            beforeId: string('before_id'));
      case 'zaizuo.post_feed':
        final visibility = string('visibility') ?? 'friends';
        if (!{'public', 'friends', 'private'}.contains(visibility)) {
          throw const OneBotFailure('bad_param', 'Unknown feed visibility');
        }
        return social.postFeed(
            parts: message(),
            visibility: visibility,
            idempotencyKey: idempotency);
      case 'zaizuo.get_feed':
        final postId = string('post_id');
        if (postId != null &&
            (p.containsKey('author_id') ||
                p.containsKey('before_id') ||
                p.containsKey('limit'))) {
          throw const OneBotFailure(
              'bad_param', 'post_id cannot be combined with list filters');
        }
        return social.getFeed(
            authorId: string('author_id'),
            postId: postId,
            limit: limit,
            beforeId: string('before_id'));
      case 'zaizuo.comment_feed':
        return social.commentFeed(
            postId: string('post_id', required: true)!,
            parts: message(),
            idempotencyKey: idempotency);
      case 'zaizuo.like_feed':
        final liked = p['liked'] ?? true;
        if (liked is! bool)
          throw const OneBotFailure('bad_param', 'liked must be bool');
        return social.likeFeed(
            postId: string('post_id', required: true)!,
            liked: liked,
            idempotencyKey: idempotency);
    }
    throw const OneBotFailure('unsupported_action', 'Unknown social action');
  }

  Future<List<Map<String, dynamic>>> _latestEvents(
      Map<String, dynamic> p) async {
    final limit = p['limit'] ?? 0;
    final timeout = p['timeout'] ?? 0;
    if (limit is! int ||
        limit < 0 ||
        timeout is! int ||
        timeout < 0 ||
        timeout > maxLongPollSeconds) {
      throw const OneBotFailure('bad_param', 'Invalid event polling limits');
    }
    if (_polling)
      throw const OneBotFailure('rate_limited', 'Another poll is in progress');
    _polling = true;
    try {
      if (_buffer.isEmpty && timeout > 0) {
        final waiter = Completer<void>();
        _waiter = waiter;
        try {
          await waiter.future.timeout(Duration(seconds: timeout));
        } on TimeoutException {
          // 合法长轮询超时，返回空列表。
        } finally {
          if (identical(_waiter, waiter)) _waiter = null;
        }
      }
      final result = <Map<String, dynamic>>[];
      final take = limit == 0 ? _buffer.length : limit;
      while (_buffer.isNotEmpty && result.length < take) {
        final original = _buffer.removeFirst();
        try {
          final value = await backend.getMessage(original.id);
          final outgoing = value.sender.id == backend.botId;
          result.add({
            'id': 'zaizuo.message:${value.id}',
            'self': self,
            'time': value.createdAtMs / 1000,
            'type': outgoing ? 'notice' : 'message',
            'detail_type': outgoing
                ? 'zaizuo.message_sent'
                : value.guildId != null
                    ? 'channel'
                    : value.detailType,
            'sub_type': '',
            'message_id': value.id,
            'message': codec.encode(value.parts, 12),
            'alt_message': codec.alt(value.parts),
            'user_id': value.sender.id,
            if (value.groupId != null && value.guildId == null)
              'group_id': value.groupId,
            if (value.guildId != null) ...{
              'guild_id': value.guildId,
              'channel_id': value.channelId
            },
            if (outgoing) 'zaizuo.detail_type': value.detailType,
          });
        } on OneBotFailure catch (error) {
          if (error.code != 'forbidden' && error.code != 'not_found') rethrow;
          // 撤销权限之后不再交付尚未轮询的历史事件。
        }
      }
      return result;
    } finally {
      _polling = false;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _waiter?.complete();
    _waiter = null;
    await _subscription.cancel();
    await _events.close();
    _buffer.clear();
  }

  static int _retcode(int version, String code) {
    if (version == 11)
      return switch (code) {
        'bad_request' ||
        'bad_request_domain' ||
        'bad_param' ||
        'bad_segment' =>
          1400,
        'forbidden' || 'unknown_self' => 1403,
        'not_found' || 'unsupported_action' => 1404,
        'rate_limited' || 'quota_exceeded' => 1429,
        'unsupported_param' ||
        'unsupported_segment' ||
        'unsupported_segment_data' =>
          1400,
        _ => 1500,
      };
    return switch (code) {
      'bad_request' => 10001,
      'unsupported_action' => 10002,
      'bad_request_domain' || 'bad_param' => 10003,
      'unsupported_param' => 10004,
      'unsupported_segment' => 10005,
      'bad_segment' => 10006,
      'unsupported_segment_data' => 10007,
      'unknown_self' => 10102,
      'forbidden' => 35001,
      'not_found' => 35002,
      'quota_exceeded' => 35003,
      'rate_limited' => 35004,
      'unavailable' => 36001,
      _ => 20002,
    };
  }
}
