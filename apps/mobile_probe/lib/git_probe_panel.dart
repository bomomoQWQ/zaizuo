import 'dart:async';
import 'dart:io';

import 'package:zaizuo_core/zaizuo_core.dart';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'git_credential_panel.dart';
import 'git_credentials.dart';
import 'git_probe_service.dart';

class GitProbePanel extends StatefulWidget {
  const GitProbePanel({super.key, required this.root});
  final Directory root;
  @override
  State<GitProbePanel> createState() => _GitProbePanelState();
}

class _GitProbePanelState extends State<GitProbePanel> {
  late final service = GitProbeService(widget.root);
  GitCredentialScope? scope;
  bool busy = false;
  String status = '未配置 Git；只有点击操作才访问指定仓库。';
  final community = TextEditingController();
  final pin = TextEditingController();
  final communityFocus = FocusNode();
  final pinFocus = FocusNode();
  @override
  void dispose() {
    unawaited(service.close());
    community.dispose();
    pin.dispose();
    communityFocus.dispose();
    pinFocus.dispose();
    super.dispose();
  }

  Future<void> action(Future<void> Function() work, String success) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
      if (mounted) setState(() => status = '$success\n${service.status}');
    } on GitCredentialException catch (error) {
      if (mounted) setState(() => status = '操作未完成：${error.code}');
    } on GitSyncException catch (error) {
      final code = RegExp(r'^[a-z_]{1,64}$').hasMatch(error.code)
          ? error.code
          : 'git_failure';
      if (mounted) setState(() => status = 'Git 操作未完成：$code（未确认同步成功）');
    } catch (_) {
      if (mounted)
        setState(
          () =>
              status = '操作未完成：git_probe_failed；请检查初始化、名册接纳、权限、TLS 或网络。未确认同步成功。',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget button(String text, Future<void> Function() work, String success) =>
      Semantics(
        button: true,
        enabled: !busy,
        child: GestureDetector(
          onTap: busy ? null : () => action(work, success),
          child: Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.symmetric(vertical: 5),
            color: const Color(0xffd6eaff),
            child: Text(text),
          ),
        ),
      );
  Widget input(
    String title,
    TextEditingController controller,
    FocusNode focus,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title),
      Container(
        padding: const EdgeInsets.all(8),
        color: const Color(0xffeeeeee),
        child: EditableText(
          controller: controller,
          focusNode: focus,
          style: const TextStyle(color: Color(0xff222222), fontSize: 14),
          cursorColor: const Color(0xff123456),
          backgroundCursorColor: const Color(0xffeeeeee),
          maxLines: 3,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [LengthLimitingTextInputFormatter(1024 * 1024)],
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '前台手动 Git 开发验证（非完整 IM）',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const Text(
        '新建丢弃式测试社区，或首次初始化时粘贴公开 community JSON 与仓库外确认的指纹。已有资料不覆盖；不上传整个 profile。测试口令与因素同目录，未完成账号独立 2FA。',
      ),
      input('可选：公开 community JSON（留空新建）', community, communityFocus),
      input('导入时必填：仓库外确认的指纹', pin, pinFocus),
      button(
        'A. 初始化/打开 Git 专用测试资料',
        () => service.initialize(
          communityJson: community.text,
          fingerprint: pin.text,
        ),
        '测试资料已打开；尚未连接远端。',
      ),
      button('复制公开社区 JSON', () async {
        await Clipboard.setData(
          ClipboardData(text: await service.exportCommunity()),
        );
      }, '公开社区 JSON 已复制；不含 PAT/私钥。'),
      button('复制社区指纹（通过仓库外渠道核对）', () async {
        await Clipboard.setData(
          ClipboardData(text: await service.exportFingerprint()),
        );
      }, '社区指纹已复制；请通过仓库外渠道核对。'),
      button('复制本机公开加入请求', () async {
        await Clipboard.setData(
          ClipboardData(text: await service.exportJoinRequest()),
        );
      }, '签名加入请求已复制；交给社区根账号接纳后再手动同步。'),
      const Text('根账号接纳：将收到的公开加入请求粘贴到上方 JSON 输入框，打开 Git 节点后点击下面按钮。'),
      button(
        '根账号：接纳 JSON 输入框的加入请求',
        () => service.admit(community.text),
        '加入请求已验证并接纳；请手动同步发布名册。',
      ),
      GitCredentialPanel(
        onConfigured: (value) {
          scope = value;
          // A rotated/deleted PAT must never leave a live backend using the old value.
          unawaited(service.close());
        },
      ),
      button('B. 使用刚保存的仓库凭据打开真实 Git 节点', () async {
        if (scope == null) throw StateError('credential_missing');
        await service.open(scope!);
      }, '已注入嵌入式 libgit2 GitSync；尚未声明同步成功。'),
      button('C. 手动同步一轮（拉取/校验/推送/回读）', service.sync, '手动同步轮次完成；不表示收件人已读。'),
      button(
        'D. 写入固定测试消息（本地持久化）',
        service.sendTestMessage,
        '测试消息已本地持久化；需手动同步，不代表已送达。',
      ),
      button('E. 写入内置图片附件测试消息', () async {
        final asset = await rootBundle.load('assets/probe.png');
        await service.sendTestAttachment(
          asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        );
      }, '附件测试消息已写入；附件上传发生在此显式操作中，消息仍需手动同步。'),
      button(
        'F. 读取本地消息计数',
        () async {},
        '本地消息计数：${service.messageCount}（不自动联网）',
      ),
      button('关闭 Git 节点', service.close, 'Git 节点已关闭。'),
      Text(status),
      const Text('无后台常驻、定时同步、通知或公网服务。不能把成功保存 PAT 当作 Git/TLS/跨机测试已通过。'),
    ],
  );
}
