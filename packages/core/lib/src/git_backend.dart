import 'dart:typed_data';

/// Trusted Git plumbing only. Implementations must never check out remote trees,
/// execute hooks/filters/helpers from repository configuration, or follow a new
/// remote URL supplied by remote content. [open] binds this instance once.
abstract interface class GitBackend {
  Future<void> open(
      {required String worktreePath,
      required String remoteUrl,
      required bool create});
  Future<String?> getRef(String ref);

  /// expectedOld == null means unconditional; forty zeroes means must not exist.
  Future<void> updateRef(String ref, String oid, {String? expectedOld});
  Future<void> deleteRef(String ref);
  Future<Map<String, String>> listRefs(String prefix);
  Future<bool> isAncestor(String oldOid, String newOid);
  Future<GitObjectInfo> objectInfo(String oidOrPath);
  Future<Uint8List> readBlob(String oidOrPath);
  Future<List<GitTreeEntry>> listTree(String commit, {required bool recursive});
  Future<String> createBlob(Uint8List bytes);

  /// Paths are repository-relative POSIX paths; only ordinary 100644 blobs.
  Future<String> createTree(Map<String, String> blobs);
  Future<String> createCommit(
      {required String tree,
      required List<String> parents,
      required String message,
      required String authorName,
      required String authorEmail,
      required String committerName,
      required String committerEmail,
      String? authorDate,
      String? committerDate});
  Future<Map<String, String>> advertise(String refPattern);
  Future<void> fetch(String refspec);

  /// Exact source:destination only, never force. Must report server rejection.
  Future<void> push(String refspec);
  Future<void> close();
}

class GitObjectInfo {
  final String type;
  final int size;
  const GitObjectInfo(this.type, this.size);
}

class GitTreeEntry {
  final String mode;
  final String type;
  final String oid;
  final String path;
  const GitTreeEntry(
      {required this.mode,
      required this.type,
      required this.oid,
      required this.path});
}
