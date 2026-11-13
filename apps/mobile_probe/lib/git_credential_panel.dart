import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'git_credentials.dart';

/// Explicit opt-in credential entry; no prefilled host identity or PAT.
class GitCredentialPanel extends StatefulWidget {
  const GitCredentialPanel({super.key, this.onConfigured});
  final ValueChanged<GitCredentialScope?>? onConfigured;
  @override
  State<GitCredentialPanel> createState() => _GitCredentialPanelState();
}

class _GitCredentialPanelState extends State<GitCredentialPanel> {
  final repo = TextEditingController();
  final username = TextEditingController();
  final token = TextEditingController();
  final focuses = List.generate(3, (_) => FocusNode());
  final store = const AndroidGitCredentialStore();
  String status = '未配置 Git 凭据；仅使用你显式输入的测试 HTTPS 仓库与用户名/PAT。';
  bool busy = false;

  @override
  void dispose() {
    repo.dispose();
    username.dispose();
    token.clear();
    token.dispose();
    for (final focus in focuses) {
      focus.dispose();
    }
    super.dispose();
  }

  Future<void> change(bool remove) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final scope = GitCredentialScope(repo.text, username.text);
      if (remove) {
        await store.delete(scope);
        widget.onConfigured?.call(null);
      } else {
        await store.save(scope, token.text);
        widget.onConfigured?.call(scope);
      }
      if (mounted)
        setState(
          () => status = remove
              ? '此仓库/用户名的凭据已删除（其他范围不变）。'
              : 'PAT 已由 AndroidKeyStore AES-GCM 保护保存；不代表 Git 同步已通过。',
        );
    } on GitCredentialException catch (error) {
      if (mounted) setState(() => status = '凭据操作未完成：${error.code}');
    } catch (_) {
      if (mounted) setState(() => status = '凭据操作未完成：credential_unavailable');
    } finally {
      token.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    String label,
    TextEditingController controller,
    int index, {
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Container(
          padding: const EdgeInsets.all(10),
          color: const Color(0xffeeeeee),
          child: EditableText(
            controller: controller,
            focusNode: focuses[index],
            style: const TextStyle(color: Color(0xff222222), fontSize: 15),
            cursorColor: const Color(0xff123456),
            backgroundCursorColor: const Color(0xffeeeeee),
            obscureText: secret,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            readOnly: busy,
            keyboardType: secret
                ? TextInputType.visiblePassword
                : TextInputType.url,
            inputFormatters: [
              LengthLimitingTextInputFormatter(
                secret
                    ? 16384
                    : index == 0
                    ? 4096
                    : 256,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget control(String title, bool remove) => Semantics(
    button: true,
    enabled: !busy,
    child: GestureDetector(
      onTap: busy ? null : () => change(remove),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(12),
        color: const Color(0xffd6eaff),
        child: Text(title),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Git 测试凭据（HTTPS / 仓库隔离）',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const Text(
        '拒绝 URL 内账号、query、fragment、HTTP/SSH。不读取电脑 Git helper、SSH 或环境账号。PAT 不写入 profile/Git config；不证明本机测试 profile 已有独立 2FA。',
      ),
      field('完整 HTTPS 仓库 URL', repo, 0),
      field('此仓库用户名', username, 1),
      field('测试 PAT（隐藏输入，保存后清空）', token, 2, secret: true),
      control('保存此仓库测试凭据', false),
      control('删除此仓库/用户名凭据', true),
      Text(status),
    ],
  );
}
