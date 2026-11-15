import 'dart:async';

/// Decides when Library Sync runs while the app is open: at startup, on
/// return to the foreground, a few seconds after a change to the Synced
/// Library, every two minutes while in the foreground, and on request. Only
/// one sync runs at a time; asking while one runs makes one more afterwards.
///
/// A sync that fails (completes with an error) is retried quietly after a
/// growing delay, which replaces the two-minute cycle until a sync succeeds.
/// Nothing runs before [start] or after [stop]: there is no work while the
/// app is closed, and a change it was waiting to publish is published by the
/// startup sync of the next run, since a sync always publishes the whole
/// Synced Library.
class SyncScheduler {
  /// How long after the latest change to the Synced Library its sync runs.
  final Duration debounce;

  /// How often a sync runs while the app is in the foreground.
  final Duration interval;

  /// The delays before retrying after one, two, ... failed syncs in a row;
  /// the last one repeats.
  final List<Duration> retryDelays;

  final Future<void> Function() _run;

  bool _started = false;
  bool _stopped = false;
  bool _inBackground = false;
  int _failuresInARow = 0;

  Future<void>? _running;

  /// Completes once the sync asked for while one was running has run.
  Completer<void>? _followUp;

  Timer? _changeTimer;
  Timer? _nextTimer;

  SyncScheduler({
    required Future<void> Function() run,
    this.debounce = const Duration(seconds: 5),
    this.interval = const Duration(minutes: 2),
    this.retryDelays = const [
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 2),
      Duration(minutes: 5),
      Duration(minutes: 10),
    ],
  }) : _run = run;

  bool get _active => _started && !_stopped;

  /// Starts scheduling with a sync; completes when that sync has run.
  Future<void> start() {
    if (_started) return Future.value();
    _started = true;
    return _request();
  }

  /// Runs a sync as soon as none is running; completes when a sync that
  /// started after this call has run.
  Future<void> syncNow() => _active ? _request() : Future.value();

  /// Notes a change to the Synced Library, published a few seconds after the
  /// latest one.
  void libraryChanged() {
    if (!_active) return;
    _changeTimer?.cancel();
    _changeTimer = Timer(debounce, () {
      _changeTimer = null;
      _request();
    });
  }

  /// The app left the foreground: the two-minute cycle and retries stop
  /// until it comes back. Changes made meanwhile are still published.
  void moveToBackground() {
    _inBackground = true;
    _nextTimer?.cancel();
    _nextTimer = null;
  }

  /// The app came back to the foreground: a sync runs at once.
  void returnToForeground() {
    if (!_inBackground) return;
    _inBackground = false;
    if (_active) _request();
  }

  /// Stops scheduling, as the app closes. A sync already running finishes;
  /// the returned future completes when it has.
  Future<void> stop() async {
    _stopped = true;
    _changeTimer?.cancel();
    _nextTimer?.cancel();
    await _running;
  }

  Future<void> _request() {
    if (_running != null) {
      return (_followUp ??= Completer<void>()).future;
    }
    _nextTimer?.cancel();
    _nextTimer = null;
    final run = _runOnce();
    _running = run;
    return run;
  }

  Future<void> _runOnce() async {
    var failed = false;
    try {
      await _run();
    } catch (_) {
      // Reported by the sync itself; retried below.
      failed = true;
    }
    _failuresInARow = failed ? _failuresInARow + 1 : 0;
    _running = null;
    final followUp = _followUp;
    _followUp = null;
    if (!_active) {
      followUp?.complete();
      return;
    }
    if (followUp != null) {
      unawaited(_request().whenComplete(followUp.complete));
      return;
    }
    _scheduleNext();
  }

  void _scheduleNext() {
    // In the background only changes run; returning syncs anyway.
    if (_inBackground) return;
    final Duration delay;
    if (_failuresInARow > 0) {
      final index = _failuresInARow - 1;
      delay = retryDelays[
          index < retryDelays.length ? index : retryDelays.length - 1];
    } else {
      delay = interval;
    }
    _nextTimer = Timer(delay, () {
      _nextTimer = null;
      _request();
    });
  }
}
