import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('pinned native runtime reports the actual TLS backend', () {
    expect(Libgit2.features, contains(GitFeature.https));
    // No URLs, credentials, filesystem paths or native error strings.
    // ignore: avoid_print
    print('PINNED_LIBGIT2_VERSION=${Libgit2.version}');
    // ignore: avoid_print
    print('PINNED_HTTPS_BACKEND=${Libgit2.featureBackend(GitFeature.https)}');
  });
}
