// Public git2dart lacks binary ODB writes and header-only reads. Keep these
// reviewed, version-pinned internal pointer uses confined to this bridge.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:git2dart/git2dart.dart' as git;
import 'package:git2dart_binaries/git2dart_binaries.dart';

// Deliberately tiny native bridge: upstream's String ODB writer counts UTF-16
// code units, and its public ODB API does not expose read_header.
void checkNative(int result) {
  if (result < 0) throw StateError('native_operation_failed');
}

(int, String) objectHeader(git.Odb odb, git.Oid oid) => using((arena) {
  final size = arena<Size>();
  final type = arena<Int>();
  checkNative(
    libgit2Runtime.bindings.git_odb_read_header(
      size,
      type,
      odb.pointer,
      oid.pointer,
    ),
  );
  final name = switch (type.value) {
    1 => 'commit',
    2 => 'tree',
    3 => 'blob',
    4 => 'tag',
    _ => throw StateError('invalid_object_type'),
  };
  return (size.value, name);
});

String writeObject(git.Odb odb, Uint8List bytes, int type) => using((arena) {
  final out = arena<git_oid>();
  final data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  data.asTypedList(bytes.length).setAll(0, bytes);
  checkNative(
    libgit2Runtime.bindings.git_odb_write(
      out,
      odb.pointer,
      data.cast(),
      bytes.length,
      git_object_t.fromValue(type),
    ),
  );
  final oid = git.Oid.fromBorrowed(out);
  try {
    return oid.sha;
  } finally {
    oid.free();
  }
});

bool descendant(git.Repository repo, git.Oid oldOid, git.Oid newOid) {
  final result = libgit2Runtime.bindings.git_graph_descendant_of(
    repo.pointer,
    newOid.pointer,
    oldOid.pointer,
  );
  checkNative(result);
  return result == 1;
}
