import 'dart:async';
import 'dart:developer';

import 'package:Bloomee/core/models/sync/known_device.dart';
import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:Bloomee/core/models/sync/sync_setup.dart';
import 'package:Bloomee/repository/sync/sync_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Something about sync the owner must see, raised once per problem.
sealed class SyncAlert extends Equatable {
  const SyncAlert();
}

/// Another Device's Device State is dated more than a day ahead: its clock
/// is wrong, and its changes are refused until it is fixed.
final class ClockRefusedAlert extends SyncAlert {
  final String deviceName;
  final DateTime changedAt;
  const ClockRefusedAlert(this.deviceName, this.changedAt);

  /// One alert per Device: later changes from the same wrong clock are not
  /// a new problem.
  @override
  List<Object?> get props => [deviceName];
}

/// Another Device's Device State cannot be read and is left out.
final class UnreadableDeviceStateAlert extends SyncAlert {
  /// Its name, or its permanent ID when the file did not tell it.
  final String device;
  const UnreadableDeviceStateAlert(this.device);

  @override
  List<Object?> get props => [device];
}

/// A Device State is in a newer format: sync stopped until Bloomee is
/// updated on this Device.
final class UpdateNeededAlert extends SyncAlert {
  /// The Device that wrote it, when known.
  final String? deviceName;
  const UpdateNeededAlert(this.deviceName);

  @override
  List<Object?> get props => [deviceName];
}

/// The Sync Location no longer accepts this Device's sign-in (the Dropbox
/// sign-in, the WebDAV password): sync is stopped until the owner signs in
/// again.
final class SignInNeededAlert extends SyncAlert {
  /// The kind of Sync Location that refused it.
  final SyncLocationKind? kind;
  const SignInNeededAlert(this.kind);

  @override
  List<Object?> get props => [kind];
}

/// The system keyring, which holds this Device's sign-in, cannot be read:
/// sync does not start until it can.
final class KeyringUnavailableAlert extends SyncAlert {
  const KeyringUnavailableAlert();

  @override
  List<Object?> get props => const [];
}

class SyncState extends Equatable {
  /// The kinds of Sync Location this Device offers; none means sync cannot
  /// be set up here yet.
  final List<SyncLocationKind> locationKinds;
  final bool loaded;

  /// How sync is set up on this Device, as last read.
  final SyncSetup setup;

  /// Whether this Device is signed in to Dropbox.
  final bool dropboxSignedIn;

  /// Whether this Device has a WebDAV server set up, with its password.
  final bool webDavSignedIn;

  /// Setting sync up is in progress (the Sync Location being tested).
  final bool settingUp;

  /// Why the Sync Location chosen last could not be used, and its kind.
  final SyncLocationProblem? setupProblem;
  final SyncLocationKind? setupProblemKind;
  final SyncStatus status;

  /// A merge the Removal Guard holds that the owner must be asked about now.
  final RemovalGuardHold? askAboutHold;

  /// The merge the owner declined: sync is paused until they confirm it.
  final RemovalGuardHold? declinedHold;

  /// Alerts to show, oldest first.
  final List<SyncAlert> alerts;

  /// The Devices known in the Sync Location, this one included, as last
  /// read; none while sync is off.
  final List<KnownDevice> devices;

  const SyncState({
    this.locationKinds = const [],
    this.loaded = false,
    this.setup = const SyncSetup(),
    this.dropboxSignedIn = false,
    this.webDavSignedIn = false,
    this.settingUp = false,
    this.setupProblem,
    this.setupProblemKind,
    this.status = const SyncStatus(),
    this.askAboutHold,
    this.declinedHold,
    this.alerts = const [],
    this.devices = const [],
  });

  SyncState copyWith({
    bool? loaded,
    SyncSetup? setup,
    bool? dropboxSignedIn,
    bool? webDavSignedIn,
    bool? settingUp,
    (SyncLocationProblem?, SyncLocationKind?) Function()? setupProblem,
    SyncStatus? status,
    RemovalGuardHold? Function()? askAboutHold,
    RemovalGuardHold? Function()? declinedHold,
    List<SyncAlert>? alerts,
    List<KnownDevice>? devices,
  }) {
    final (problem, problemKind) = setupProblem == null
        ? (this.setupProblem, setupProblemKind)
        : setupProblem();
    return SyncState(
      locationKinds: locationKinds,
      loaded: loaded ?? this.loaded,
      setup: setup ?? this.setup,
      dropboxSignedIn: dropboxSignedIn ?? this.dropboxSignedIn,
      webDavSignedIn: webDavSignedIn ?? this.webDavSignedIn,
      settingUp: settingUp ?? this.settingUp,
      setupProblem: problem,
      setupProblemKind: problemKind,
      status: status ?? this.status,
      askAboutHold: askAboutHold != null ? askAboutHold() : this.askAboutHold,
      declinedHold: declinedHold != null ? declinedHold() : this.declinedHold,
      alerts: alerts ?? this.alerts,
      devices: devices ?? this.devices,
    );
  }

  @override
  List<Object?> get props => [
        locationKinds,
        loaded,
        setup,
        dropboxSignedIn,
        webDavSignedIn,
        settingUp,
        setupProblem,
        setupProblemKind,
        status,
        askAboutHold,
        declinedHold,
        alerts,
        devices,
      ];
}

/// Library Sync for the settings screen and the app-wide alerts: its setup,
/// the status line, the Removal Guard's question and the alerts the owner
/// must see. Each problem is alerted once, until a sync no longer meets it;
/// a refused sign-in and an unreadable keyring are alerted each time sync
/// stops for them.
class SyncCubit extends Cubit<SyncState> {
  final SyncRepository _repository;
  final List<StreamSubscription<Object>> _subscriptions = [];
  Set<SyncAlert> _problems = {};

  /// The refused sign-in or unreadable keyring alerted last.
  SyncError? _stopAlerted;

  SyncCubit(this._repository)
      : super(SyncState(
            locationKinds: _repository.locationKinds,
            status: _repository.status)) {
    _subscriptions
      ..add(_repository.statusChanges.listen(_onStatus))
      ..add(_repository.outcomes.listen(_onOutcome));
    _onStatus(_repository.status);
  }

  Future<void> load() async {
    final setup = await _repository.setup();
    final signedIn = await _repository.dropboxSignedIn();
    final webDavSignedIn = await _repository.webDavSignedIn();
    if (isClosed) return;
    emit(state.copyWith(
        loaded: true,
        setup: setup,
        dropboxSignedIn: signedIn,
        webDavSignedIn: webDavSignedIn,
        status: _repository.status));
    await _readDevices();
  }

  /// Makes [choice] the Sync Location, once it passes its test: while sync
  /// is on, moves sync there; while it is off, turns it on with [choice],
  /// under [deviceName] if given. Otherwise [SyncState.setupProblem] says
  /// why it cannot be used, and sync stays as it was. Dropbox and WebDAV
  /// need this Device signed in ([finishDropboxSignIn], [signInToWebDav]).
  Future<void> choose(SyncLocationChoice choice, {String? deviceName}) async {
    final name = deviceName?.trim() ?? '';
    emit(state.copyWith(settingUp: true, setupProblem: () => (null, null)));
    SyncLocationProblem? problem;
    try {
      problem = state.setup.enabled
          ? await _repository.moveTo(choice)
          : await _repository.enable(choice,
              deviceName: name.isEmpty ? state.setup.deviceName : name);
    } finally {
      if (!isClosed) {
        emit(state.copyWith(
            settingUp: false,
            setupProblem: () =>
                (problem, problem == null ? null : choice.kind)));
      }
    }
    await load();
  }

  /// Starts signing in to Dropbox, returning the Dropbox page the owner
  /// opens to allow Bloomee.
  Uri beginDropboxSignIn() => _repository.beginDropboxSignIn();

  /// Finishes the sign-in with the [code] the owner pasted from that page;
  /// completes with why it failed, or null once signed in.
  Future<SyncLocationProblem?> finishDropboxSignIn(String code) =>
      _reloadingAfter(() => _repository.finishDropboxSignIn(code));

  /// Signs in to the WebDAV folder at [address] as [user] with [password],
  /// once it passes its test; completes with why it cannot be used, or null
  /// once signed in.
  Future<SyncLocationProblem?> signInToWebDav(
          {required String address,
          required String user,
          required String password}) =>
      _reloadingAfter(() => _repository.signInToWebDav(
          address: address, user: user, password: password));

  /// Runs [signIn], then reads the setup again.
  Future<SyncLocationProblem?> _reloadingAfter(
      Future<SyncLocationProblem?> Function() signIn) async {
    final problem = await signIn();
    try {
      await load();
    } catch (error) {
      log('Library Sync setup could not be read: $error', name: 'SyncCubit');
    }
    return problem;
  }

  /// Signs this Device out of Dropbox, turning off sync through it.
  /// Completes with whether the sign-in was removed: it is not when the
  /// system keyring cannot be changed.
  Future<bool> signOutOfDropbox() async {
    try {
      await _repository.signOutOfDropbox();
      return true;
    } catch (error) {
      log('Could not sign out of Dropbox: $error', name: 'SyncCubit');
      return false;
    } finally {
      await load();
    }
  }

  /// Forgets the Device [deviceId], once the owner confirmed it. Completes
  /// with whether it was forgotten: it is not when the Sync Location cannot
  /// be changed now.
  Future<bool> forgetDevice(String deviceId) async {
    try {
      await _repository.forgetDevice(deviceId);
      return true;
    } catch (error) {
      log('Could not forget a Device: $error', name: 'SyncCubit');
      return false;
    } finally {
      await _readDevices();
    }
  }

  Future<void> disable() async {
    await _repository.disable();
    await load();
  }

  Future<void> renameDevice(String name) async {
    await _repository.renameDevice(name);
    await load();
  }

  Future<void> syncNow() => _repository.syncNow();

  /// Answers the Removal Guard about [hold], as the owner was shown it.
  Future<void> answerRemovalGuard(RemovalGuardHold hold,
      {required bool confirm}) async {
    emit(state.copyWith(askAboutHold: () => null));
    await _repository.answerRemovalGuard(hold, confirm: confirm);
  }

  /// The question about [hold] was closed without an answer: the next sync
  /// that still holds the merge asks again.
  void removalGuardDismissed(RemovalGuardHold hold) {
    if (identical(state.askAboutHold, hold)) {
      emit(state.copyWith(askAboutHold: () => null));
    }
  }

  /// [alert] was shown to the owner.
  void alertShown(SyncAlert alert) =>
      emit(state.copyWith(alerts: [...state.alerts]..remove(alert)));

  void _onStatus(SyncStatus status) {
    final error = status.lastError;
    // Each time sync stops for one of these, it is alerted.
    final alert = identical(error, _stopAlerted)
        ? null
        : switch (error) {
            SyncSignInNeeded(:final kind) => SignInNeededAlert(kind),
            SyncKeyringUnavailable() => const KeyringUnavailableAlert(),
            _ => null,
          };
    if (alert != null) _stopAlerted = error;
    emit(state.copyWith(
        status: status,
        // A refused Dropbox sign-in is forgotten; a WebDAV password is kept.
        dropboxSignedIn:
            alert == const SignInNeededAlert(SyncLocationKind.dropbox)
                ? false
                : null,
        alerts: alert != null && !state.alerts.contains(alert)
            ? [...state.alerts, alert]
            : null));
  }

  void _onOutcome(SyncOutcome outcome) {
    final problems = {
      for (final skipped in outcome.skipped)
        switch (skipped) {
          DeviceStateFromFuture(:final deviceName, :final changedAt) =>
            ClockRefusedAlert(deviceName!, changedAt),
          DamagedDeviceState(:final deviceId, :final deviceName) =>
            UnreadableDeviceStateAlert(deviceName ?? deviceId),
        },
      if (outcome case SyncUpdateNeeded(:final deviceName))
        UpdateNeededAlert(deviceName),
    };
    final fresh = problems.difference(_problems);
    // Only a completed sync reads every Device State, so only it shows that
    // a problem has gone; the others may stop early or read none.
    _problems =
        outcome is SyncCompleted ? problems : {..._problems, ...problems};

    var ask = state.askAboutHold;
    RemovalGuardHold? declined;
    switch (outcome) {
      case SyncHeld(:final hold, declined: false):
        if (ask == null || !ask.sameRemovalsAs(hold)) ask = hold;
      case SyncHeld(:final hold, declined: true):
        ask = null;
        declined = hold;
      default:
        ask = null;
    }
    emit(state.copyWith(
        askAboutHold: () => ask,
        declinedHold: () => declined,
        alerts: [...state.alerts, ...fresh]));
    unawaited(_readDevices());
  }

  /// Reads the known Devices again; when the Sync Location cannot be read,
  /// those read last stay, the status line telling what is wrong.
  Future<void> _readDevices() async {
    try {
      final devices = await _repository.knownDevices();
      if (!isClosed) emit(state.copyWith(devices: devices));
    } catch (error) {
      log('Could not list the Devices: $error', name: 'SyncCubit');
    }
  }

  @override
  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    return super.close();
  }
}
