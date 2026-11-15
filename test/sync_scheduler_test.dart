import 'dart:async';

import 'package:Bloomee/repository/sync/sync_scheduler.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// A sync the test controls: it records when each run starts, can be made
/// to fail, and can be held open to see what happens meanwhile.
class _Syncs {
  final FakeAsync time;
  final List<Duration> started = [];
  int running = 0;
  int mostAtOnce = 0;
  bool failing = false;
  Completer<void>? holdOpen;

  _Syncs(this.time);

  Future<void> run() async {
    started.add(time.elapsed);
    running++;
    if (running > mostAtOnce) mostAtOnce = running;
    try {
      if (holdOpen case final gate?) await gate.future;
      if (failing) throw Exception('Sync Location unreachable');
    } finally {
      running--;
    }
  }
}

Duration _s(int n) => Duration(seconds: n);
Duration _min(int n) => Duration(minutes: n);

void main() {
  void withScheduler(
      void Function(FakeAsync time, _Syncs syncs, SyncScheduler scheduler)
          body) {
    fakeAsync((time) {
      final syncs = _Syncs(time);
      final scheduler = SyncScheduler(run: syncs.run);
      body(time, syncs, scheduler);
      scheduler.stop();
      time.flushMicrotasks();
    });
  }

  test('a sync runs at startup', () {
    withScheduler((time, syncs, scheduler) {
      scheduler.start();
      time.flushMicrotasks();
      expect(syncs.started, [Duration.zero]);
    });
  });

  test('a sync runs every two minutes while the app is open', () {
    withScheduler((time, syncs, scheduler) {
      scheduler.start();
      time.elapse(const Duration(minutes: 7));
      expect(syncs.started, [Duration.zero, _min(2), _min(4), _min(6)]);
    });
  });

  test('a change to the Synced Library syncs a few seconds later, debounced',
      () {
    withScheduler((time, syncs, scheduler) {
      scheduler.start();
      time.elapse(_s(10));
      scheduler.libraryChanged();
      time.elapse(_s(3));
      scheduler.libraryChanged();
      time.elapse(_s(3));
      scheduler.libraryChanged();
      time.elapse(_s(4));
      expect(syncs.started, [Duration.zero],
          reason: 'still within a few seconds of the last change');
      time.elapse(_s(1));
      expect(syncs.started, [Duration.zero, _s(21)]);
    });
  });

  test('a change restarts the two-minute cycle from its sync', () {
    withScheduler((time, syncs, scheduler) {
      scheduler.start();
      time.elapse(_min(1));
      scheduler.libraryChanged();
      time.elapse(const Duration(minutes: 3));
      expect(syncs.started, [Duration.zero, _min(1) + _s(5), _min(3) + _s(5)]);
    });
  });

  test('sync now runs at once and completes when that sync has', () {
    withScheduler((time, syncs, scheduler) {
      scheduler.start();
      time.elapse(_s(30));
      var done = false;
      syncs.holdOpen = Completer();
      scheduler.syncNow().then((_) => done = true);
      time.flushMicrotasks();
      expect(syncs.started, [Duration.zero, _s(30)]);
      expect(done, isFalse);
      syncs.holdOpen!.complete();
      time.flushMicrotasks();
      expect(done, isTrue);
    });
  });

  test('only one sync runs at a time; requests meanwhile make one more', () {
    withScheduler((time, syncs, scheduler) {
      syncs.holdOpen = Completer();
      scheduler.start();
      time.flushMicrotasks();
      var nowDone = 0;
      scheduler.syncNow().then((_) => nowDone++);
      scheduler.syncNow().then((_) => nowDone++);
      scheduler.libraryChanged();
      time.elapse(_s(20));
      scheduler.returnToForeground();
      time.elapse(_s(20));
      expect(syncs.started, [Duration.zero], reason: 'the first is still open');
      expect(nowDone, 0);

      final first = syncs.holdOpen!;
      syncs.holdOpen = null;
      first.complete();
      time.flushMicrotasks();

      expect(syncs.started, [Duration.zero, _s(40)]);
      expect(nowDone, 2, reason: 'the follow-up sync started after both asked');
      expect(syncs.mostAtOnce, 1);
      time.elapse(_min(1));
      expect(syncs.started.length, 2, reason: 'nothing is left over');
    });
  });

  test('a temporary failure is retried quietly with growing delays', () {
    withScheduler((time, syncs, scheduler) {
      syncs.failing = true;
      scheduler.start();
      time.elapse(const Duration(minutes: 20));
      expect(syncs.started, [
        Duration.zero,
        _s(15),
        _s(45),
        const Duration(minutes: 1, seconds: 45),
        const Duration(minutes: 3, seconds: 45),
        const Duration(minutes: 8, seconds: 45),
        const Duration(minutes: 18, seconds: 45),
      ]);
    });
  });

  test('after a failure, a successful sync returns to the two-minute cycle',
      () {
    withScheduler((time, syncs, scheduler) {
      syncs.failing = true;
      scheduler.start();
      time.elapse(_s(50)); // fails at 0, 15 s and 45 s
      syncs.failing = false;
      time.elapse(const Duration(minutes: 6));
      expect(syncs.started, [
        Duration.zero,
        _s(15),
        _s(45),
        const Duration(minutes: 1, seconds: 45),
        const Duration(minutes: 3, seconds: 45),
        const Duration(minutes: 5, seconds: 45),
      ]);
    });
  });

  test('a failed sync is retried from the start of the delays once it works',
      () {
    withScheduler((time, syncs, scheduler) {
      syncs.failing = true;
      scheduler.start();
      time.elapse(_s(50)); // fails at 0, 15 s and 45 s
      syncs.failing = false;
      time.elapse(const Duration(minutes: 1)); // succeeds at 1:45
      syncs.failing = true;
      time.elapse(const Duration(minutes: 2, seconds: 20));
      expect(syncs.started.sublist(4), [
        const Duration(minutes: 3, seconds: 45),
        const Duration(minutes: 4)
      ]);
    });
  });

  test('no periodic sync runs in the background; returning syncs at once', () {
    withScheduler((time, syncs, scheduler) {
      scheduler.start();
      time.elapse(_s(30));
      scheduler.moveToBackground();
      time.elapse(const Duration(minutes: 10));
      expect(syncs.started, [Duration.zero]);

      scheduler.returnToForeground();
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 2, seconds: 1));
      expect(syncs.started, [
        Duration.zero,
        const Duration(minutes: 10, seconds: 30),
        const Duration(minutes: 12, seconds: 30),
      ]);
    });
  });

  test('a change made in the background is still published', () {
    withScheduler((time, syncs, scheduler) {
      scheduler.start();
      scheduler.moveToBackground();
      time.elapse(_s(10));
      scheduler.libraryChanged();
      time.elapse(const Duration(minutes: 10));
      expect(syncs.started, [Duration.zero, _s(15)]);
    });
  });

  test('a failure in the background is retried once back in the foreground',
      () {
    withScheduler((time, syncs, scheduler) {
      scheduler.start();
      scheduler.moveToBackground();
      syncs.failing = true;
      scheduler.libraryChanged();
      time.elapse(const Duration(minutes: 10));
      expect(syncs.started, [Duration.zero, _s(5)],
          reason: 'no retries while in the background');

      syncs.failing = false;
      scheduler.returnToForeground();
      time.flushMicrotasks();
      expect(syncs.started.last, const Duration(minutes: 10));
    });
  });

  test('nothing runs once the app has closed, not even a pending change', () {
    withScheduler((time, syncs, scheduler) {
      scheduler.start();
      time.elapse(_s(10));
      scheduler.libraryChanged();
      time.elapse(_s(2));
      scheduler.stop();
      scheduler.libraryChanged();
      scheduler.returnToForeground();
      time.elapse(const Duration(hours: 1));
      expect(syncs.started, [Duration.zero]);
    });
  });

  test('nothing runs before startup', () {
    withScheduler((time, syncs, scheduler) {
      scheduler.libraryChanged();
      scheduler.returnToForeground();
      time.elapse(const Duration(minutes: 10));
      expect(syncs.started, isEmpty);
    });
  });
}
