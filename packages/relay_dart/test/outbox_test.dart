import 'dart:async';

import 'package:test/test.dart';
import 'package:zaizuo_relay/src/outbox.dart';
import 'package:zaizuo_relay/src/rate_window.dart';
import 'package:zaizuo_relay/src/transport.dart';

void main() {
  group('finite outbox', () {
    test('counts the in-flight item and closes once on overflow', () {
      final blocked = Completer<void>();
      final sent = <String>[];
      var failures = 0;
      final outbox = BoundedOutbox(
        capacity: 2,
        timeout: const Duration(seconds: 5),
        write: (message) {
          sent.add(message);
          return blocked.future;
        },
        onBackpressure: () => failures++,
      );
      expect(outbox.add('first'), isTrue);
      expect(outbox.add('second'), isTrue);
      expect(outbox.pending, 2);
      expect(outbox.add('overflow'), isFalse);
      expect(outbox.pending, 0);
      expect(outbox.add('after failure'), isFalse);
      expect(failures, 1);
      expect(sent, ['first']);
      blocked.complete();
    });

    test('does not drain into a blocked sink and preserves order', () async {
      final first = Completer<void>();
      final secondStarted = Completer<void>();
      final second = Completer<void>();
      final sent = <String>[];
      final outbox = BoundedOutbox(
        capacity: 3,
        timeout: const Duration(seconds: 5),
        write: (message) {
          sent.add(message);
          if (message == 'one') return first.future;
          secondStarted.complete();
          return second.future;
        },
        onBackpressure: () => fail('unexpected backpressure'),
      );
      outbox.add('one');
      outbox.add('two');
      expect(sent, ['one']);
      expect(outbox.pending, 2);
      first.complete();
      await secondStarted.future;
      expect(sent, ['one', 'two']);
      expect(outbox.pending, 1);
      outbox.stop();
      second.complete();
      expect(outbox.pending, 0);
    });

    test('an unrelated receiver keeps making progress', () async {
      final blocked = Completer<void>();
      final delivered = Completer<void>();
      final slow = BoundedOutbox(
        capacity: 1,
        timeout: const Duration(seconds: 5),
        write: (_) => blocked.future,
        onBackpressure: () {},
      );
      final fast = BoundedOutbox(
        capacity: 1,
        timeout: const Duration(seconds: 5),
        write: (_) async => delivered.complete(),
        onBackpressure: () => fail('fast closed'),
      );
      slow.add('event');
      fast.add('event');
      await delivered.future;
      expect(slow.pending, 1);
      slow.stop();
      fast.stop();
      blocked.complete();
    });

    test('a failed transport closes without an unhandled async error',
        () async {
      final failed = Completer<void>();
      final outbox = BoundedOutbox(
        capacity: 1,
        timeout: const Duration(seconds: 5),
        write: (_) => Future<void>.error(StateError('test transport')),
        onBackpressure: failed.complete,
      );
      outbox.add('event');
      await failed.future;
      expect(outbox.pending, 0);
      expect(outbox.add('after failure'), isFalse);
    });

    test('write timeout signals backpressure, no hard sleep', () async {
      final blocked = Completer<void>();
      final failed = Completer<void>();
      final outbox = BoundedOutbox(
        capacity: 1,
        timeout: const Duration(milliseconds: 10),
        write: (_) => blocked.future,
        onBackpressure: failed.complete,
      );
      outbox.add('event');
      await failed.future;
      expect(outbox.add('after timeout'), isFalse);
      blocked.complete();
    });
  });

  group('fixed rate window', () {
    test('100 per fixed ten seconds, exact boundary resets', () {
      final window = RequestWindow(100);
      for (var i = 0; i < 100; i++) {
        expect(window.accept(i * 1000), isTrue);
      }
      expect(window.accept(9999999), isFalse);
      expect(window.accept(10000000), isTrue);
    });
    test('idle jumps do not keep a previous window alive', () {
      final window = RequestWindow(1);
      expect(window.accept(0), isTrue);
      expect(window.accept(1), isFalse);
      expect(window.accept(30000001), isTrue);
      expect(window.accept(39999999), isFalse);
      expect(window.accept(40000000), isTrue);
    });
  });

  group('outgoing-only header tracking', () {
    test('counts text only after its full payload, control frames independent',
        () {
      final tracker = OutgoingFrameTracker();
      expect(tracker.inspect([0x81]).applicationFrames, 0);
      expect(tracker.inspect([3, 1, 2]).applicationFrames, 0);
      expect(tracker.inspect([3, 0x89, 0]).applicationFrames, 1);
      expect(tracker.inspect([0x81, 0]).applicationFrames, 1);
    });
    test('rewrites just close status across arbitrary chunk boundaries', () {
      final tracker = OutgoingFrameTracker()..closeCodeOverride = 1013;
      final input = <List<int>>[
        [0x81, 2, 0x03, 0xf3], // opaque application bytes, not changed
        [0x88], [2], [0x03], [0xf3], // native 1011 => wire 1013
      ];
      final output = [
        for (final bytes in input) ...tracker.inspect(bytes).bytes
      ];
      expect(output, [0x81, 2, 0x03, 0xf3, 0x88, 2, 0x03, 0xf5]);
      expect(input.last, [0xf3]); // does not mutate SDK buffers
    });
    test('handles extended lengths and combined output chunks', () {
      final tracker = OutgoingFrameTracker();
      final bytes = [0x81, 126, 0, 126, ...List<int>.filled(126, 1), 0x8a, 0];
      expect(tracker.inspect(bytes).applicationFrames, 1);
      expect(
          tracker
              .inspect([0x81, 127, 0, 0, 0, 0, 0, 0, 0, 1]).applicationFrames,
          0);
      expect(tracker.inspect([1]).applicationFrames, 1);
    });
  });
}
