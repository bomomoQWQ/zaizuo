/// 在座哑中继协议 v1：仅供 Dart VM / Flutter Native 使用。
///
/// 此包只鉴别中继连接凭据并转发不透明 payload，不提供业务加密或持久化。
library;

export 'src/config.dart' show RelayConfig;
export 'src/server.dart' show RelayServer;
