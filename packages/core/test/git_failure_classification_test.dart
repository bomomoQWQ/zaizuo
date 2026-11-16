import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';

void main() {
  test(
      '502/503 gateway failures get a distinct code that triggers HTTP/1.1 retry',
      () {
    for (final stderr in [
      'error: RPC failed; HTTP 502 curl 22 The requested URL returned error: 502',
      "fatal: unable to access 'https://example.test/x.git/': The requested URL returned error: 503",
      'Received HTTP code 504 from proxy after CONNECT',
    ]) {
      final failure = GitCliBackend.classifyNetworkFailure(stderr);
      expect(failure.code, 'remote_gateway_failed', reason: stderr);
      // The message must not leak the URL or child output.
      expect(failure.message, isNot(contains('example.test')));
    }
  });

  test('Windows path limit errors are distinct and never echo the local path',
      () {
    final failure = GitCliBackend.classifyNetworkFailure(
        "error: cannot lock ref 'refs/zaizuo-incoming/nonce/device': Unable to create 'C:/private-token-area/refs/device.lock': Filename too long");
    expect(failure.code, 'git_path_too_long');
    expect(failure.message, isNot(contains('private-token-area')));
  });

  test('existing classifications stay stable', () {
    expect(
        GitCliBackend.classifyNetworkFailure(
                "fatal: could not read Username for 'https://github.com'")
            .code,
        'authentication_failed');
    expect(
        GitCliBackend.classifyNetworkFailure('remote: Permission denied').code,
        'permission_denied');
    expect(GitCliBackend.classifyNetworkFailure('repository not found').code,
        'repository_unavailable');
    expect(
        GitCliBackend.classifyNetworkFailure(
                'SSL certificate problem: unable to get local issuer certificate')
            .code,
        'tls_failed');
    expect(
        GitCliBackend.classifyNetworkFailure('Failed to connect to host').code,
        'network_unavailable');
    expect(GitCliBackend.classifyNetworkFailure('something odd').code,
        'git_failed');
  });
}
