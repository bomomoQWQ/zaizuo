import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Flutter 3.50 SDK compatibility export; external Material migration is separate.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';

import 'client_controller.dart';
import 'project_licenses.dart';

/// The client owns its controller unless one is explicitly supplied by a test.
/// No startup networking, sample conversations or delivery receipts are invented.
class ClientApp extends StatefulWidget {
  const ClientApp({
    super.key,
    required this.root,
    this.controller,
    this.gitFactory,
    this.configureGit,
    this.onDeveloperTools,
    this.navigatorKey,
  });

  final Directory root;
  final ClientController? controller;
  final GitFactory? gitFactory;
  final Future<void> Function(
    ClientController client,
    String remote,
    String username,
    String? token,
    bool remember,
    bool useSaved,
    bool forget,
  )?
  configureGit;
  final VoidCallback? onDeveloperTools;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<ClientApp> createState() => _ClientAppState();
}

class _ClientAppState extends State<ClientApp> {
  static const _native = MethodChannel('zaizuo.mobile_probe/native');
  static const _maxImageBytes = 8 * 1024 * 1024;
  late final GlobalKey<NavigatorState> _navigator;
  final _name = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _community = TextEditingController();
  final _fingerprint = TextEditingController();
  final _draft = TextEditingController();
  late final ClientController _client;
  bool _create = true;
  bool _checkingProfile = true;
  bool _mobileChat = false;
  bool _picking = false;
  String? _localError;

  BuildContext get _dialogContext => _navigator.currentContext!;
  bool get _busy => _client.busy || _picking;

  @override
  void initState() {
    super.initState();
    _navigator = widget.navigatorKey ?? GlobalKey<NavigatorState>();
    _client =
        widget.controller ??
        ClientController(widget.root, gitFactory: widget.gitFactory);
    _client.addListener(_changed);
    unawaited(_checkProfile());
  }

  Future<void> _checkProfile() async {
    try {
      final exists = await File(
        '${widget.root.path}${Platform.pathSeparator}profile'
        '${Platform.pathSeparator}account.keybox',
      ).exists();
      if (mounted) setState(() => _create = !exists);
    } catch (_) {
      if (mounted) setState(() => _localError = '无法检查本机资料，请确认应用目录可用。');
    } finally {
      if (mounted) setState(() => _checkingProfile = false);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _client.removeListener(_changed);
    if (widget.controller == null) _client.dispose();
    for (final field in [
      _name,
      _displayName,
      _password,
      _confirmation,
      _community,
      _fingerprint,
      _draft,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _authenticate() async {
    setState(() => _localError = null);
    if (_create) {
      if (_password.text != _confirmation.text) {
        setState(() => _localError = '两次密码不一致。');
        return;
      }
      await _client.create(
        name: _name.text.trim(),
        displayName: _displayName.text.trim(),
        password: _password.text,
        communityJson: _community.text.trim().isEmpty
            ? null
            : _community.text.trim(),
        fingerprint: _fingerprint.text.trim().isEmpty
            ? null
            : _fingerprint.text.trim(),
      );
    } else {
      await _client.unlock(_password.text);
    }
    if (!mounted) return;
    if (_client.error == null && _client.isOpen) {
      _password.clear();
      _confirmation.clear();
      _community.clear();
      _fingerprint.clear();
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigator,
    title: '在座',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
      fontFamilyFallback: const [
        'Microsoft YaHei',
        'Noto Sans CJK SC',
        'sans-serif',
      ],
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff287f7a),
        brightness: Brightness.light,
        surface: const Color(0xfffaf9f5),
      ),
      scaffoldBackgroundColor: const Color(0xfff3f2ed),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
        fillColor: Color(0xfffdfcf9),
      ),
      visualDensity: VisualDensity.standard,
    ),
    home: Builder(
      builder: (context) =>
          _client.isOpen ? _workspace(context) : _welcome(context),
    ),
  );

  Widget _badge() => const Chip(
    visualDensity: VisualDensity.compact,
    avatar: Icon(Icons.science_outlined, size: 16),
    label: Text('测试版'),
  );

  Widget _feedback() {
    final error = _localError ?? _client.error;
    final notice = _client.notice;
    if (error == null && notice.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Semantics(
        liveRegion: true,
        child: Text(
          error != null ? '操作未完成：$error' : '$notice',
          style: TextStyle(
            color: error != null
                ? const Color(0xffa33d35)
                : const Color(0xff286760),
          ),
        ),
      ),
    );
  }

  Widget _welcome(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('在座'),
      actions: [
        _badge(),
        IconButton(
          onPressed: _about,
          tooltip: '关于在座',
          icon: const Icon(Icons.info_outline),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.forum_outlined,
                    size: 48,
                    color: Color(0xff287f7a),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '留个位置，慢慢聊。',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text('本机账号 · 空间与私聊\n测试软件，请妥善保管密码与资料备份。'),
                  const SizedBox(height: 24),
                  if (_checkingProfile)
                    const LinearProgressIndicator()
                  else
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('创建账号')),
                        ButtonSegment(value: false, label: Text('解锁资料')),
                      ],
                      selected: {_create},
                      onSelectionChanged: _busy
                          ? null
                          : (value) => setState(() {
                              _create = value.single;
                              _localError = null;
                            }),
                    ),
                  const SizedBox(height: 20),
                  if (_create) ...[
                    TextField(
                      controller: _name,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: '账户名',
                        helperText: '小写字母、数字或下划线，1–14 位',
                      ),
                      autocorrect: false,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _displayName,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: '显示名称',
                        helperText: '少于 15 个显示字符',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: '密码',
                      helperText: _create ? '12位以上，含大小写字母，不含账户名或常见弱密码模式' : null,
                      helperMaxLines: 2,
                    ),
                  ),
                  if (_create) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirmation,
                      enabled: !_busy,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: '确认密码'),
                    ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('加入已有社区（可选）'),
                      subtitle: const Text('仅使用你自行核验的公开清单与指纹'),
                      children: [
                        TextField(
                          controller: _community,
                          enabled: !_busy,
                          minLines: 3,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            labelText: '社区公开清单 JSON',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _fingerprint,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: '可信渠道取得的指纹',
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ],
                  _feedback(),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy || _checkingProfile ? null : _authenticate,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _create
                                ? Icons.person_add_outlined
                                : Icons.lock_open_outlined,
                          ),
                    label: Text(_create ? '创建并进入' : '解锁'),
                  ),
                  if (widget.onDeveloperTools != null)
                    TextButton(
                      onPressed: widget.onDeveloperTools,
                      child: const Text('开发者工具'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _workspace(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 820;
      return Scaffold(
        appBar: AppBar(
          leading: !wide && _mobileChat
              ? IconButton(
                  tooltip: '返回会话',
                  onPressed: () => setState(() => _mobileChat = false),
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          title: const Text('在座'),
          actions: [
            _badge(),
            IconButton(
              tooltip: '社交与社区',
              onPressed: _busy ? null : _social,
              icon: const Icon(Icons.people_outline),
            ),
            IconButton(
              tooltip: '设置与同步',
              onPressed: _settings,
              icon: const Icon(Icons.tune),
            ),
            IconButton(
              tooltip: '关于在座',
              onPressed: _about,
              icon: const Icon(Icons.info_outline),
            ),
          ],
        ),
        drawer: wide
            ? null
            : Drawer(child: SafeArea(child: _sidebar(context, drawer: true))),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            _feedback(),
            if (!_client.admitted)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('此设备尚未获社区接纳。可在“社交与社区”复制加入请求，交给社区管理者。'),
              ),
            Expanded(
              child: wide
                  ? Row(
                      children: [
                        SizedBox(width: 280, child: _sidebar(context)),
                        const VerticalDivider(width: 1),
                        Expanded(child: _chat(context)),
                      ],
                    )
                  : (_mobileChat ? _chat(context) : _sidebar(context)),
            ),
          ],
        ),
      );
    },
  );

  String _kind(String kind) => switch (kind) {
    'direct' => '私聊',
    'chat' => '聊天室',
    'shadow' => '茶会',
    'forumThread' => '论坛讨论',
    _ => '会话',
  };

  String _conversationTitle(ConversationRecord conversation) {
    if (conversation.kind != 'direct') return conversation.title;
    final other = conversation.participantIds.where(
      (id) => id != _client.ownerId,
    );
    return other.isEmpty ? conversation.title : _sender(other.first);
  }

  // Only used for records returned by the controller's authorized queries.
  String _sender(String id) {
    final state = _client.node?.replica.service.state;
    return state?.accounts[id]?.displayName ??
        state?.bots[id]?.displayName ??
        id;
  }

  Widget _sidebar(BuildContext context, {bool drawer = false}) {
    final conversations = _client.conversations;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _client.displayName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              const Text('会话', style: TextStyle(color: Color(0xff61716c))),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _busy || !_client.admitted ? null : _newSpace,
                  icon: const Icon(Icons.add),
                  label: const Text('新建空间'),
                ),
              ),
              IconButton(
                tooltip: '加入空间',
                onPressed: _busy || !_client.admitted ? null : _joinSpace,
                icon: const Icon(Icons.login),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: conversations.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '还没有会话\n创建空间，或添加好友后开始私聊。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: conversations.length,
                  itemBuilder: (context, index) {
                    final conversation = conversations[index];
                    return ListTile(
                      selected:
                          _client.selectedConversationId == conversation.id,
                      selectedTileColor: const Color(0xffdcece5),
                      leading: Icon(
                        conversation.kind == 'direct'
                            ? Icons.person_outline
                            : conversation.kind == 'shadow'
                            ? Icons.local_cafe_outlined
                            : Icons.tag,
                      ),
                      title: Text(
                        _conversationTitle(conversation),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_kind(conversation.kind)),
                      onTap: _busy
                          ? null
                          : () {
                              _draft.clear();
                              _client.selectConversation(conversation.id);
                              setState(() => _mobileChat = true);
                              if (drawer) Navigator.of(context).pop();
                            },
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextButton.icon(
            onPressed: _settings,
            icon: const Icon(Icons.sync),
            label: Text(
              _client.node?.git == null ? '离线 · 未配置 Git' : 'Git 已配置 · 查看同步',
            ),
          ),
        ),
      ],
    );
  }

  bool get _readOnly {
    final conversation = _client.selectedConversation;
    if (conversation == null) return true;
    if (conversation.kind == 'shadow' || conversation.kind == 'forumThread')
      return true;
    if (conversation.kind == 'direct' &&
        !conversation.participantIds.contains(_client.ownerId))
      return true;
    return _client
            .node
            ?.replica
            .service
            .state
            .rooms[conversation.roomId]
            ?.config
            .readOnly ??
        false;
  }

  Widget _chat(BuildContext context) {
    final conversation = _client.selectedConversation;
    if (conversation == null)
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.chair_alt_outlined,
                size: 64,
                color: Color(0xff64847b),
              ),
              const SizedBox(height: 16),
              Text('这里有你的位置', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text('选择一个会话，或从新空间开始。'),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy || !_client.admitted ? null : _newSpace,
                icon: const Icon(Icons.add),
                label: const Text('新建空间'),
              ),
            ],
          ),
        ),
      );
    final messages = _client.messages;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: const Color(0xfffaf9f5),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _conversationTitle(conversation),
                  style: Theme.of(context).textTheme.titleLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Chip(label: Text(_kind(conversation.kind))),
              if (_readOnly)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Chip(label: Text('只读')),
                ),
            ],
          ),
        ),
        Expanded(
          child: messages.isEmpty
              ? const Center(child: Text('还没有消息。说点什么吧。'))
              : ListView.builder(
                  padding: const EdgeInsets.all(20),
                  itemCount: messages.length,
                  itemBuilder: (context, index) =>
                      _message(context, messages[index]),
                ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '添加图片（最多 8 MiB）',
                  onPressed: _busy || _readOnly || !_client.admitted
                      ? null
                      : _pickImage,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                ),
                Expanded(
                  child: TextField(
                    controller: _draft,
                    enabled: !_busy && !_readOnly && _client.admitted,
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      hintText: _readOnly ? '此会话只读' : '写一条消息…',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: '发送',
                  onPressed: _busy || _readOnly || !_client.admitted
                      ? null
                      : _sendText,
                  icon: const Icon(Icons.send_outlined),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _message(BuildContext context, MessageRecord message) {
    final mine = message.senderId == _client.ownerId;
    final time = DateTime.fromMillisecondsSinceEpoch(message.createdAtMs)
        .toLocal();
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: mine ? const Color(0xffdcece5) : const Color(0xfffdfcf9),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _sender(message.senderId),
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              for (var index = 0; index < message.parts.length; index++)
                _part(message, index),
              const SizedBox(height: 6),
              Text(
                '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _part(MessageRecord message, int index) {
    final part = message.parts[index];
    final data = part['data'];
    if (part['type'] == 'text') {
      return SelectableText(
        data is Map && data['text'] is String
            ? data['text'] as String
            : '文本格式不可用',
      );
    }
    if (part['type'] == 'image' || part['type'] == 'file') {
      final attachment = data is Map ? data['attachment'] : null;
      final descriptor = attachment is Map ? attachment['descriptor'] : null;
      final name = descriptor is Map ? descriptor['name'] : null;
      final size = descriptor is Map ? descriptor['size'] : null;
      return TextButton.icon(
        onPressed: _busy ? null : () => _openMedia(message, index),
        icon: Icon(
          part['type'] == 'image'
              ? Icons.image_outlined
              : Icons.insert_drive_file_outlined,
        ),
        label: Text(
          '${_safeName(name)}${size is int ? ' · $size B' : ''}\n点击查看${part['type'] == 'image' ? '图片' : '附件信息'}',
        ),
      );
    }
    return const Text('暂不支持的消息段');
  }

  String _safeName(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 256 ||
        value.contains('/') ||
        value.contains('\\') ||
        value.codeUnits.any((c) => c < 32 || c == 127))
      return '附件';
    return value;
  }

  Future<void> _sendText() async {
    final text = _draft.text;
    if (text.trim().isEmpty) return;
    setState(() => _localError = null);
    await _client.sendText(text);
    if (mounted && _client.error == null && _draft.text == text) _draft.clear();
  }

  Future<void> _newSpace() =>
      _inputDialog('新建空间', '空间名称', '创建', _client.createSpace);
  Future<void> _joinSpace() =>
      _inputDialog('加入空间', '空间 ID', '加入', _client.joinSpace);

  Future<void> _inputDialog(
    String title,
    String label,
    String action,
    Future<void> Function(String) work, {
    bool multiline = false,
  }) async {
    final field = TextEditingController();
    await showDialog<void>(
      context: _dialogContext,
      builder: (context) => AnimatedBuilder(
        animation: _client,
        builder: (context, _) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: field,
                  autofocus: true,
                  enabled: !_client.busy,
                  minLines: multiline ? 4 : 1,
                  maxLines: multiline ? 8 : 1,
                  decoration: InputDecoration(labelText: label),
                ),
                if (_client.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('操作未完成：${_client.error}'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _client.busy ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _client.busy
                  ? null
                  : () async {
                      if (field.text.trim().isEmpty) return;
                      await work(field.text.trim());
                      if (context.mounted && _client.error == null)
                        Navigator.pop(context);
                    },
              child: Text(action),
            ),
          ],
        ),
      ),
    );
    // Dialog routes retain their child while the closing animation runs.
  }

  Future<void> _social() async {
    await showDialog<void>(
      context: _dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('社交与社区'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('账户 ID（可复制给好友）'),
                SelectableText(_client.ownerId),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _copy(_client.ownerId),
                  icon: const Icon(Icons.copy),
                  label: const Text('复制账户 ID'),
                ),
                FilledButton.tonal(
                  onPressed: () {
                    Navigator.pop(context);
                    unawaited(
                      _inputDialog('添加好友', '对方账户 ID', '添加好友并私聊', (id) async {
                        await _client.addFriend(id);
                        if (_client.error == null)
                          await _client.startDirect(id);
                      }),
                    );
                  },
                  child: const Text('添加好友并私聊'),
                ),
                const Divider(),
                TextButton(
                  onPressed: () =>
                      _export('社区公开清单', () async => _client.exportCommunity()),
                  child: const Text('查看公开清单'),
                ),
                TextButton(
                  onPressed: () => _export('社区指纹', _client.exportFingerprint),
                  child: const Text('查看社区指纹'),
                ),
                TextButton(
                  onPressed: () => _export('设备加入请求', _client.exportJoinRequest),
                  child: const Text('查看 / 复制加入请求'),
                ),
                const Text('加入前请通过另一个可信渠道核验指纹。加入请求由社区管理者处理，不等于自动获准。'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () {
                          Navigator.pop(context);
                          unawaited(
                            _inputDialog(
                              '管理者接纳设备',
                              '粘贴加入请求 JSON',
                              '接纳',
                              _client.admit,
                              multiline: true,
                            ),
                          );
                        },
                  child: const Text('管理者：接纳加入请求'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _export(String title, Future<String> Function() get) async {
    try {
      final text = await get();
      if (!mounted || !_client.isOpen) return;
      await showDialog<void>(
        context: _dialogContext,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(child: SelectableText(text)),
          ),
          actions: [
            TextButton(onPressed: () => _copy(text), child: const Text('复制')),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _localError = '无法导出，请检查账号与社区状态。');
    }
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted)
        ScaffoldMessenger.of(_dialogContext)
            .showSnackBar(const SnackBar(content: Text('已复制')));
    } catch (_) {
      if (mounted) setState(() => _localError = '复制失败，请手动选择文本。');
    }
  }

  Future<void> _settings() async {
    final remote = TextEditingController(text: _client.gitRemote ?? '');
    final username = TextEditingController(text: 'x-access-token');
    final token = TextEditingController();
    bool remember = false;
    bool useSaved = false;
    String? credentialStatus;
    await showModalBottomSheet<void>(
      context: _dialogContext,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => AnimatedBuilder(
          animation: _client,
          builder: (context, _) {
            final node = _client.node;
            final status = node?.status();
            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  8,
                  24,
                  24 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '设置与同步',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      node?.git == null
                          ? '离线 · Git 未配置'
                          : 'Git 已配置（不代表收件人在线或已收到）',
                    ),
                    Text(
                      '最近同步：${node?.lastSyncAt?.toLocal().toString() ?? '尚无成功记录'}',
                    ),
                    Text('最近同步错误：${_fixedCode(node?.lastSyncError)}'),
                    Text('被拒绝的命令：${status?['rejected_commands'] ?? 0}'),
                    const SizedBox(height: 16),
                    TextField(
                      controller: remote,
                      enabled: !_client.busy,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Git 远端',
                        hintText: 'SSH 或不含凭据的 HTTPS 地址',
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '令牌可选：填写后仅用于此 HTTPS 仓库，不写入 URL 或 Git 配置；未填且不选已保存令牌时，桌面使用系统凭据助手/匿名访问。配置不会立即同步。',
                    ),
                    const SizedBox(height: 12),
                    if (widget.configureGit != null) ...[
                      TextField(
                        controller: username,
                        enabled: !_client.busy,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'HTTPS 用户名',
                          helperText: 'GitHub 通常可用你的用户名或 x-access-token',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: token,
                        enabled: !_client.busy,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        decoration: const InputDecoration(
                          labelText: '访问令牌 PAT（可选）',
                          helperText: '需有测试仓库读写权限；不会显示或回填已保存令牌',
                        ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('加密保存在本机'),
                        subtitle: const Text(
                          'Windows DPAPI / Android Keystore，仅此仓库与用户名',
                        ),
                        value: remember,
                        onChanged: _client.busy
                            ? null
                            : (v) => setSheetState(() => remember = v!),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('使用此仓库已保存的令牌'),
                        value: useSaved,
                        onChanged: _client.busy
                            ? null
                            : (v) => setSheetState(() => useSaved = v!),
                      ),
                      TextButton(
                        onPressed: _client.busy
                            ? null
                            : () async {
                                try {
                                  await widget.configureGit!(
                                    _client,
                                    remote.text.trim(),
                                    username.text.trim(),
                                    null,
                                    false,
                                    false,
                                    true,
                                  );
                                  if (context.mounted)
                                    setSheetState(
                                      () => credentialStatus =
                                          '已清除此范围的本机令牌，并关闭当前Git连接。',
                                    );
                                } catch (_) {
                                  if (context.mounted)
                                    setSheetState(
                                      () => credentialStatus =
                                          '清除失败，请检查仓库地址与本机安全存储。',
                                    );
                                }
                              },
                        child: const Text('清除已保存令牌并断开Git'),
                      ),
                    ],
                    if (credentialStatus != null) Text(credentialStatus!),
                    if (_client.error != null) Text('操作未完成：${_client.error}'),
                    FilledButton.tonal(
                      onPressed: _client.busy
                          ? null
                          : () async {
                              try {
                                if (widget.configureGit != null) {
                                  await widget.configureGit!(
                                    _client,
                                    remote.text.trim(),
                                    username.text.trim(),
                                    token.text.isEmpty ? null : token.text,
                                    remember,
                                    useSaved,
                                    false,
                                  );
                                } else {
                                  await _client.configureGit(
                                    remote.text.trim(),
                                  );
                                }
                                if (context.mounted)
                                  setSheetState(
                                    () =>
                                        credentialStatus = _client.error == null
                                        ? 'Git配置完成，请手动同步验证权限。'
                                        : 'Git配置未完成。',
                                  );
                              } catch (_) {
                                if (context.mounted)
                                  setSheetState(
                                    () => credentialStatus =
                                        '凭据配置失败：请检查HTTPS地址、用户名与安全存储状态。',
                                  );
                              } finally {
                                token.clear();
                              }
                            },
                      child: const Text('配置 Git'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _client.busy || node?.git == null
                          ? null
                          : _client.sync,
                      icon: const Icon(Icons.sync),
                      label: const Text('手动同步'),
                    ),
                    const Divider(),
                    if (widget.onDeveloperTools != null)
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onDeveloperTools!();
                        },
                        icon: const Icon(Icons.developer_mode),
                        label: const Text('开发者工具'),
                      ),
                    TextButton.icon(
                      onPressed: _client.busy
                          ? null
                          : () async {
                              Navigator.pop(context);
                              _draft.clear();
                              await _client.lock();
                              if (mounted)
                                setState(() {
                                  _create = false;
                                  _mobileChat = false;
                                });
                            },
                      icon: const Icon(Icons.lock_outline),
                      label: const Text('锁定本机资料'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    token.clear();
  }

  String _fixedCode(String? value) => value == null
      ? '无'
      : RegExp(r'^[a-zA-Z0-9_.-]{1,80}$').hasMatch(value)
      ? value
      : '同步未完成，请检查远端与本机配置';

  Future<void> _pickImage() async {
    setState(() => _localError = null);
    try {
      Uint8List? bytes;
      var name = 'image';
      if (Platform.isAndroid) {
        setState(() => _picking = true);
        bytes = await _native.invokeMethod<Uint8List>('pickImage');
      } else {
        final path = TextEditingController();
        final selected = await showDialog<String>(
          context: _dialogContext,
          builder: (context) => AlertDialog(
            title: const Text('从本机选择图片'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '暂未集成桌面文件选择器。请明确输入要发送的静态 PNG / JPEG / WebP 路径，最多 8 MiB。仅在你点击“读取”后读取该文件。',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: path,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: '图片路径'),
                    autocorrect: false,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, path.text.trim()),
                child: const Text('读取'),
              ),
            ],
          ),
        );
        if (selected == null || selected.isEmpty) return;
        setState(() => _picking = true);
        final file = File(selected).absolute;
        // Reject symlinks in every path component, not just the final file.
        var cursor = file.path;
        while (true) {
          if (await FileSystemEntity.type(cursor, followLinks: false) ==
              FileSystemEntityType.link)
            throw const FormatException('link');
          final parent = File(cursor).parent.path;
          if (parent == cursor) break;
          cursor = parent;
        }
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file)
          throw const FormatException('not_file');
        final handle = await file.open(mode: FileMode.read);
        try {
          final length = await handle.length();
          if (length < 1 || length > _maxImageBytes)
            throw const FormatException('size');
          bytes = await handle.read(_maxImageBytes + 1);
          if (bytes.isEmpty || bytes.length > _maxImageBytes)
            throw const FormatException('size');
        } finally {
          await handle.close();
        }
        name = file.uri.pathSegments.last;
      }
      if (bytes == null) return;
      if (bytes.isEmpty || bytes.length > _maxImageBytes)
        throw const FormatException('size');
      await _client.sendImage(bytes, _safeName(name));
    } catch (_) {
      if (mounted)
        setState(
          () => _localError = '未能发送图片：请选择非链接的有效静态图片（最多 8 MiB），并确认平台选择器可用。',
        );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _openMedia(MessageRecord message, int index) async {
    final owner = _client.ownerId;
    final conversation = _client.selectedConversationId;
    try {
      final parts = await _client.projectMessage(message);
      final data = parts[index]['data'];
      if (data is! Map || data['file_id'] is! String)
        throw const FormatException('media');
      final media = await _client.loadMedia(data['file_id'] as String);
      final encoded = media['data'];
      if (encoded is! String ||
          encoded.length > ((_maxImageBytes + 2) ~/ 3) * 4)
        throw const FormatException('size');
      final bytes = base64Decode(encoded);
      if (bytes.length > _maxImageBytes) throw const FormatException('size');
      if (!mounted || !_client.isOpen) return;
      if (_client.ownerId != owner ||
          _client.selectedConversationId != conversation)
        return;
      final image = parts[index]['type'] == 'image';
      await showDialog<void>(
        context: _dialogContext,
        builder: (context) => AlertDialog(
          title: Text(_safeName(media['name'])),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (image)
                    Image.memory(
                      bytes,
                      cacheWidth: 1200,
                      errorBuilder: (_, _, _) => const Text('图片无法解码。'),
                    ),
                  Text('${bytes.length} B · 已在本机读取'),
                  if (!image) const Text('此版本仅查看附件信息，暂不提供保存到文件。'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _localError = '附件无法读取：可能尚未同步、资料损坏或当前账号无权访问。');
    }
  }

  Future<void> _about() => showDialog<void>(
    context: _dialogContext,
    builder: (context) => AlertDialog(
      title: const Text('关于在座 · 测试版'),
      content: const SizedBox(
        width: 560,
        child: SingleChildScrollView(child: ProjectLicensePanel()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
