/// 中继的有限资源配置。配置对象不会在 [toString] 中暴露 token。
///
/// 所有数值必须为正数。[maxPayloadBytes] 可以下调，但不能超过 v1 的
/// 32768 字节上限。速率窗口固定为 10 秒，不能配置为其他协议。
final class RelayConfig {
  RelayConfig({
    required this.token,
    this.maxConnections = 128,
    this.maxTopicsPerConnection = 64,
    this.maxMessageBytes = 65536,
    this.maxPayloadBytes = 32768,
    this.maxPendingMessages = 32,
    this.maxRequestsPerWindow = 100,
    this.pingInterval = const Duration(seconds: 30),
    this.writeTimeout = const Duration(seconds: 5),
  }) {
    if (!isValidRelayToken(token)) {
      // Deliberately do not include the provided secret in the exception.
      throw ArgumentError(
          'token must contain 32–256 printable non-space ASCII characters');
    }
    for (final entry in <String, int>{
      'maxConnections': maxConnections,
      'maxTopicsPerConnection': maxTopicsPerConnection,
      'maxMessageBytes': maxMessageBytes,
      'maxPayloadBytes': maxPayloadBytes,
      'maxPendingMessages': maxPendingMessages,
      'maxRequestsPerWindow': maxRequestsPerWindow,
    }.entries) {
      if (entry.value <= 0) {
        throw ArgumentError('${entry.key} must be positive');
      }
    }
    if (maxPayloadBytes > 32768) {
      throw ArgumentError(
          'maxPayloadBytes cannot exceed the v1 limit of 32768');
    }
    if (pingInterval <= Duration.zero || writeTimeout <= Duration.zero) {
      throw ArgumentError('pingInterval and writeTimeout must be positive');
    }
  }

  /// 仅使用 Authorization Bearer 头传输，不写入 URL 或日志。
  final String token;
  final int maxConnections;
  final int maxTopicsPerConnection;

  /// 已由 dart:io 组装的完整文本消息的 UTF-8 字节上限。
  ///
  /// 不是底层接收缓冲的硬上限；详见包 README 的原生流帧边界。
  final int maxMessageBytes;
  final int maxPayloadBytes;

  /// 每连接等待/正在发送的应用消息总数，包括 ready、ok、error 和 event。
  final int maxPendingMessages;

  /// 每连接固定 10 秒窗口中所有文本请求（包括错误请求）的上限。
  final int maxRequestsPerWindow;
  final Duration pingInterval;

  /// 写入以及主动关闭的最长宽限。慢收件人不会阻塞其他连接。
  final Duration writeTimeout;
}

bool isValidRelayToken(String value) {
  if (value.length < 32 || value.length > 256) return false;
  return value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);
}
