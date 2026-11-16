import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';

import '../lib/git_binding_service.dart';
import '../lib/git_config_store.dart';
import '../lib/git_token_store.dart';

const remote = 'https://example.invalid/repository.git';
const saved = GitConfig(remote: remote, username: 'saved-user', remember: true);

class Harness {
  GitConfig? config = saved;
  String? secret = 'test-only-token';
  Object? readError;
  Object? deleteError;
  Object? saveConfigError;
  int factories = 0;
  int reads = 0;
  int saves = 0;
  int clears = 0;
  int disconnects = 0;
  bool connected = true;
  GitHttpsToken? connectedCredential;
  String? deletedRemote;
  String? deletedUsername;

  late final service = GitBindingService(
    loadConfig: () async => config,
    saveConfig: (value) async {
      if (saveConfigError case final error?) throw error;
      config = value;
    },
    clearConfig: () async {
      clears++;
      config = null;
    },
    readToken: ({required repositoryUrl, required username}) async {
      reads++;
      if (readError case final error?) throw error;
      return secret;
    },
    saveToken:
        ({required repositoryUrl, required username, required token}) async {
          saves++;
          secret = token;
        },
    deleteToken: ({required repositoryUrl, required username}) async {
      if (deleteError case final error?) throw error;
      deletedRemote = repositoryUrl;
      deletedUsername = username;
    },
    connect: (remote, credential) async {
      factories++;
      connectedCredential = credential;
      return connected;
    },
    disconnect: () async {
      disconnects++;
      return true;
    },
  );
}

Matcher code(String value) =>
    isA<GitSyncException>().having((error) => error.code, 'safe code', value);

void main() {
  test(
    'Windows DPAPI fixture restores through service without network',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zaizuo-binding-test-',
      );
      try {
        final config = GitConfigStore(directory);
        final tokens = GitTokenStore(
          Directory('${directory.path}/credentials'),
        );
        await config.save(saved);
        await tokens.save(
          repositoryUrl: remote,
          username: saved.username,
          token: 'dpapi-test-only-token',
        );
        var factories = 0;
        final service = GitBindingService(
          loadConfig: config.load,
          saveConfig: config.save,
          clearConfig: config.clear,
          readToken: tokens.read,
          saveToken: tokens.save,
          deleteToken: tokens.delete,
          connect: (url, credential) async {
            factories++;
            expect(url, remote);
            expect(credential!.username, saved.username);
            expect(credential.token, 'dpapi-test-only-token');
            return true;
          },
          disconnect: () async => true,
        );
        expect(await service.restore(), isTrue);
        expect(factories, 1);
        await tokens.delete(repositoryUrl: remote, username: saved.username);
        await expectLater(
          service.restore(),
          throwsA(code('credentials_required')),
        );
        expect(factories, 1);
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  test('saved binding with absent token cannot claim deletion', () async {
    final h = Harness()..secret = null;
    await expectLater(
      h.service.forget(remote: remote, username: 'ignored'),
      throwsA(code('credentials_required')),
    );
    expect(h.clears, 0);
    expect(h.disconnects, 0);
  });

  test('remembered token absence fails closed before factory', () async {
    final h = Harness()..secret = null;
    await expectLater(
      h.service.restore(),
      throwsA(code('credentials_required')),
    );
    expect(h.factories, 0);
  });

  for (final failure in <Object>[
    const GitTokenStoreException('credential_corrupt'),
    const FormatException('test secret must not escape'),
    ArgumentError('test secret must not escape'),
  ]) {
    test(
      'unreadable token fails closed and sanitizes ${failure.runtimeType}',
      () async {
        final h = Harness()..readError = failure;
        try {
          await h.service.restore();
          fail('expected fixed Git diagnostic');
        } on GitSyncException catch (error) {
          expect(error.toString(), isNot(contains('test secret')));
        }
        expect(h.factories, 0);
      },
    );
  }

  test('remember=false does not read retained secret', () async {
    final h = Harness()
      ..config = const GitConfig(
        remote: remote,
        username: 'saved-user',
        remember: false,
      );
    expect(await h.service.restore(), isTrue);
    expect(h.reads, 0);
    expect(h.connectedCredential, isNull);
  });

  test('restored factory receives saved username and token', () async {
    final h = Harness();
    expect(await h.service.restore(), isTrue);
    expect(h.connectedCredential!.username, 'saved-user');
    expect(h.connectedCredential!.token, 'test-only-token');
  });

  test('empty token with useSaved opts into remembered binding', () async {
    final h = Harness();
    await h.service.configure(
      remote: remote,
      username: 'saved-user',
      token: '',
      remember: false,
      useSaved: true,
    );
    expect(h.config!.remember, isTrue);
    expect(h.saves, 0);
  });

  test(
    'new session-only token preserves old secret but disables auto-use',
    () async {
      final h = Harness();
      await h.service.configure(
        remote: remote,
        username: 'saved-user',
        token: 'session-only-test-token',
        remember: false,
        useSaved: false,
      );
      expect(h.secret, 'test-only-token');
      expect(h.connectedCredential!.token, 'session-only-test-token');
      expect(h.config!.remember, isFalse);
      await h.service.restore();
      expect(h.connectedCredential, isNull);
      expect(h.reads, 0);
    },
  );

  test('forget uses persisted scope not edited form', () async {
    final h = Harness()
      ..readError = const GitTokenStoreException('credential_corrupt');
    await h.service.forget(
      remote: 'https://example.invalid/edited.git',
      username: 'edited-user',
    );
    expect(h.deletedRemote, remote);
    expect(h.deletedUsername, 'saved-user');
    expect(h.clears, 1);
  });

  test('delete failure retains binding', () async {
    final h = Harness()
      ..deleteError = const GitTokenStoreException('credential_unavailable');
    await expectLater(
      h.service.forget(remote: remote, username: 'ignored'),
      throwsA(code('credential_unavailable')),
    );
    expect(h.clears, 0);
    expect(h.config, saved);
  });

  test('missing saved scope cannot claim deletion', () async {
    final h = Harness()
      ..config = null
      ..secret = null;
    await expectLater(
      h.service.forget(remote: remote, username: 'nobody'),
      throwsA(code('credentials_required')),
    );
    expect(h.disconnects, 0);
    expect(h.deletedRemote, isNull);
    expect(h.clears, 0);
  });

  test('explicit scope works without persisted config', () async {
    final h = Harness()..config = null;
    expect(
      await h.service.forget(remote: remote, username: 'explicit-user'),
      isTrue,
    );
    expect(h.deletedUsername, 'explicit-user');
    expect(h.clears, 0);
  });

  test(
    'non-secret write failure after connection has controlled diagnostic',
    () async {
      final h = Harness()
        ..saveConfigError = const FileSystemException('private path');
      await expectLater(
        h.service.configure(
          remote: remote,
          username: 'saved-user',
          token: 'test-token',
          remember: false,
          useSaved: false,
        ),
        throwsA(code('git_binding_write_failed')),
      );
      expect(h.factories, 1);
    },
  );

  test('controller connection failure does not persist new binding', () async {
    final h = Harness()..connected = false;
    expect(
      await h.service.configure(
        remote: remote,
        username: 'other',
        token: 'test-token',
        remember: false,
        useSaved: false,
      ),
      isFalse,
    );
    expect(h.config, saved);
  });
}
