import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'probe_service.dart';
import 'git_probe_panel.dart';
import 'project_licenses.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MobileProbe());
}

class MobileProbe extends StatefulWidget {
  const MobileProbe({super.key});
  @override
  State<MobileProbe> createState() => _MobileProbeState();
}

class _MobileProbeState extends State<MobileProbe> {
  static const channel = MethodChannel('zaizuo.mobile_probe/native');
  ProbeService? service;
  ProbeResult? result;
  String status = '准备读取 Android 应用私密目录…';
  String environment = '';
  bool busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(prepare());
  }

  Future<void> prepare() async {
    try {
      final native = await channel.invokeMapMethod<String, dynamic>(
        'environment',
      );
      final root = native?['privateRoot'];
      if (root is! String || root.isEmpty)
        throw StateError('missing_private_root');
      final probe = ProbeService(Directory(root));
      if (!mounted) return;
      setState(() {
        service = probe;
        busy = false;
        status = '仅本机验证。先初始化测试资料，再运行内置图片或选择静态 PNG/JPEG/WebP。';
        environment =
            'Android API ${native?['sdk']} / ${native?['abi']}\n'
            'Dart ${Platform.version.split(' ').first}\n'
            '应用私密目录，不申请相册/存储权限。\n${probe.gitStatus}';
      });
    } catch (_) {
      if (mounted)
        setState(() {
          busy = false;
          status = '环境读取失败；此壳仅支持 Android Native。';
        });
    }
  }

  Future<void> action(Future<void> Function() work) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = '本机处理中…';
    });
    try {
      await work();
    } on PlatformException catch (error) {
      if (mounted) setState(() => status = '系统选择器未完成：${_safeCode(error.code)}');
    } catch (_) {
      // Do not display paths, private material, file content or arbitrary codec
      // / crypto exception strings. Fixed diagnostics only.
      if (mounted) setState(() => status = '操作失败：可能未初始化、图片超限/损坏/动画或本机空间不足。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> runBytes(List<int> bytes) async {
    final output = await service!.roundTrip(bytes);
    if (!mounted) return;
    setState(() {
      result = output;
      status =
          'PASS：静态图片 → lossless WebP → 随机会话钥匙 AES-GCM 密文文件\n'
          '→ 新对象存储实例读取 → 解密/摘要一致；错误钥匙被拒绝。\n'
          '${output.width}×${output.height}；输入 ${output.inputBytes} B，WebP ${output.webpBytes} B。\n'
          '小图可能变大；无损压图不保证体积变小。';
    });
  }

  Widget button(String label, VoidCallback work) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Semantics(
      button: true,
      enabled: !busy,
      child: GestureDetector(
        onTap: busy ? null : work,
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: busy ? const Color(0xffdedede) : const Color(0xffd6eaff),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: const TextStyle(color: Color(0xff123456), fontSize: 16),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => WidgetsApp(
    color: const Color(0xfff7f7f7),
    debugShowCheckedModeBanner: false,
    builder: (context, child) => Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xfff7f7f7),
        child: SafeArea(
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Color(0xff222222),
              fontSize: 15,
              height: 1.4,
            ),
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                const Text(
                  '在座 · Android 验证壳',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                const Text(
                  '非正式 UI / 非完整 IM / 前台手动 Git 开发验证\n仅测试资料；不要导入真实账户或敏感照片。',
                ),
                const SizedBox(height: 12),
                const ProjectLicensePanel(),
                const SizedBox(height: 12),
                Text(environment),
                const SizedBox(height: 12),
                button(
                  '1. 初始化本机私密测试 profile',
                  () => unawaited(
                    action(() async {
                      await service!.initialize();
                      if (mounted)
                        setState(
                          () => status = '测试 profile 已初始化/重新解锁。\n测试口令与第二因素都在本机应用目录，不是 Android Keystore 或独立 2FA 保证。',
                        );
                    }),
                  ),
                ),
                button(
                  '2. 内置 PNG 压图 + 加密往返',
                  () => unawaited(
                    action(() async {
                      final asset = await rootBundle.load('assets/probe.png');
                      await runBytes(
                        asset.buffer.asUint8List(
                          asset.offsetInBytes,
                          asset.lengthInBytes,
                        ),
                      );
                    }),
                  ),
                ),
                button(
                  '3. 系统选择图片后本机往返（≤8MiB / ≤4M像素）',
                  () => unawaited(
                    action(() async {
                      final bytes = await channel.invokeMethod<Uint8List>(
                        'pickImage',
                      );
                      if (bytes == null) {
                        if (mounted)
                          setState(() => status = '已取消选择；没有写入或上传图片。');
                        return;
                      }
                      await runBytes(bytes);
                    }),
                  ),
                ),
                const SizedBox(height: 12),
                if (service != null)
                  GitProbePanel(
                    root: Directory('${service!.root.path}/git-probe'),
                  ),
                Text(status),
                if (result != null) ...[
                  const SizedBox(height: 12),
                  const Text('解密后 WebP 预览（只在本机内存）：'),
                  Image.memory(
                    result!.preview,
                    height: 200,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Text('系统图像预览失败；不能据此声称设备端图片链路通过。'),
                  ),
                  Text(
                    '密文对象 SHA-256：${result!.cipherHash}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
                const SizedBox(height: 18),
                const Text(
                  '卸载此测试包会删除本机测试资料与 Git 凭据。PAT 接 AndroidKeyStore，但测试 profile 口令/因素仍同目录。\nGit 仅显式前台操作；无后台同步、通知、相机或外部平台。原图片往返不联网；Git 附件测试单独明确触发上传。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

String _safeCode(String code) =>
    const {
      'picker_busy',
      'picker_unavailable',
      'input_limit',
      'input_unreadable',
    }.contains(code)
    ? code
    : 'native_failure';
