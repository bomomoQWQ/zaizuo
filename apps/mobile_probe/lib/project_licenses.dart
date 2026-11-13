import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const projectSourceUrl = 'https://github.com/bomomoQWQ/zaizuo/tree/main';
const projectLicenseAsset = 'assets/licenses/AGPL-3.0-only.txt';
const projectNoticeAsset = 'assets/licenses/NOTICE.txt';

/// Offline legal notices only: never starts a browser, network or Git process.
class ProjectLicensePanel extends StatefulWidget {
  const ProjectLicensePanel({super.key});

  @override
  State<ProjectLicensePanel> createState() => _ProjectLicensePanelState();
}

class _ProjectLicensePanelState extends State<ProjectLicensePanel> {
  bool expanded = false;
  bool loading = false;
  String? documentTitle;
  String documentText = '';
  String feedback = '';

  Future<void> copySource() async {
    try {
      await Clipboard.setData(const ClipboardData(text: projectSourceUrl));
      if (mounted) setState(() => feedback = '对应源码地址已复制，请自行在浏览器访问。');
    } catch (_) {
      if (mounted) setState(() => feedback = '无法复制；请使用上方完整源码地址。');
    }
  }

  Future<void> showDocument(
    String title,
    Future<String> Function() read,
  ) async {
    setState(() {
      loading = true;
      documentTitle = title;
      documentText = '';
    });
    try {
      final text = await read();
      if (mounted) setState(() => documentText = text);
    } catch (_) {
      if (mounted) {
        setState(() => documentText = '许可资料读取失败；请从对应源码地址查看 LICENSE / NOTICE。');
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<String> thirdPartyNotices() async {
    final text = StringBuffer();
    // Flutter reads its generated NOTICES.Z, preserving each upstream notice.
    // Do not relabel third-party materials as AGPL project code.
    await for (final entry in LicenseRegistry.licenses) {
      text.writeln(entry.packages.join(', '));
      for (final paragraph in entry.paragraphs) {
        text.writeln(paragraph.text);
        text.writeln();
      }
      text.writeln('----------------------------------------');
    }
    return text.isEmpty ? '未读取到第三方许可；请从对应源码与依赖包查看原始许可。' : text.toString();
  }

  Widget control(String label, VoidCallback? onTap) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Semantics(
      button: true,
      enabled: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          color: const Color(0xffe4edf4),
          child: Text(label, style: const TextStyle(color: Color(0xff123456))),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      control(
        expanded ? '收起关于 / 许可与对应源码' : '关于 / 许可与对应源码',
        () => setState(() => expanded = !expanded),
      ),
      if (expanded) ...[
        const Text('在座 Android 验证壳 · 0.1.0+2 / v0.1.0-media-test3'),
        const Text('Copyright (C) 2026 bomomoQWQ and contributors'),
        const Text(
          '项目原创代码：AGPL-3.0-only（仅第 3 版）。本程序不提供任何保证；'
          '你可以在遵守许可的前提下复制、修改和再分发。下方可离线阅读完整 LICENSE 和 NOTICE。',
        ),
        const SizedBox(height: 8),
        const Text('本测试包对应源码与构建说明（复制后自行访问）：'),
        const Text(projectSourceUrl),
        control('复制对应源码地址（不联网）', () => unawaited(copySource())),
        if (feedback.isNotEmpty) Text(feedback),
        control(
          '查看项目 LICENSE（AGPL-3.0-only）',
          loading
              ? null
              : () => unawaited(
                  showDocument(
                    '项目 LICENSE',
                    () => rootBundle.loadString(projectLicenseAsset),
                  ),
                ),
        ),
        control(
          '查看项目 NOTICE',
          loading
              ? null
              : () => unawaited(
                  showDocument(
                    '项目 NOTICE',
                    () => rootBundle.loadString(projectNoticeAsset),
                  ),
                ),
        ),
        const Text('第三方组件与 Flutter 模板部分保留各自原始许可，不由项目 NOTICE 改为 AGPL。'),
        control(
          '查看第三方许可（Flutter 生成的原始 notices）',
          loading
              ? null
              : () => unawaited(showDocument('第三方许可', thirdPartyNotices)),
        ),
        control(
          '查看嵌入式 Git 原生依赖许可与来源',
          loading
              ? null
              : () => unawaited(
                  showDocument('原生 Git 依赖', () async {
                    final sections = <String>[];
                    for (final file in [
                      'SOURCES.md',
                      'licenses/git2dart-MIT.txt',
                      'licenses/git2dart_binaries-MIT.txt',
                      'licenses/libgit2-COPYING.txt',
                      'licenses/libssh2-COPYING.txt',
                      'licenses/OpenSSL-LICENSE.txt',
                      'licenses/MPL-2.0.txt',
                    ]) {
                      sections.add(
                        '$file\n${await rootBundle.loadString('assets/licenses/native_git/$file')}',
                      );
                    }
                    return sections.join('\n\n');
                  }),
                ),
        ),
        const Text('此开发构建尚未发布对应源码版本；main 地址不是固定发布证明。分发时需配套本地源码快照与原生依赖来源材料。'),
        if (documentTitle != null) ...[
          const SizedBox(height: 8),
          Text(
            documentTitle!,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          SizedBox(
            height: 260,
            child: ColoredBox(
              color: const Color(0xffffffff),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10),
                child: Text(
                  loading ? '正在读取 APK 内置许可…' : documentText,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ],
    ],
  );
}
