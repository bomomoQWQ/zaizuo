import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_git_mobile/git_mobile.dart';

// FFI unavailability is deliberately a test failure, never a skipped test.
GitBackend nativeBackend() => EmbeddedGitBackend.testLocalBare();
