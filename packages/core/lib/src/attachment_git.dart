import 'dart:io';
import 'dart:typed_data';

import 'git_sync.dart';

/// On-demand ciphertext-only attachment transport. Descriptors, authorization
/// and decryption remain with the caller; this facade never accepts a key.
///
/// The repository is borrowed, so the caller retains its lifecycle. Attachment
/// refs are separate from main and device logs and use the same safe Git runner.
class AttachmentGit {
  final GitSync repository;
  const AttachmentGit({required this.repository});

  static const int maxAttachmentBytes = GitSync.maxAttachmentBytes;

  Future<void> publishAttachment({
    required String objectId,
    required File ciphertext,
  }) =>
      repository.publishAttachment(objectId: objectId, ciphertext: ciphertext);

  Future<Uint8List> fetchAttachment(
    String objectId, {
    int maxBytes = maxAttachmentBytes,
  }) =>
      repository.fetchAttachment(objectId, maxBytes: maxBytes);
}
