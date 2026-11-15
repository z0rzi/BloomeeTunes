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

class SyncState extends Equatable {
  /// The kinds of Sync Location this Device offers; none means sync cannot
  /// be set up here yet.
  final List<SyncLocationKind> locationKinds;
  final bool loaded;
  final bool enabled;

  /// The kind of Sync Location chosen, if one was.
  final SyncLocationKind? locationKind;

  /// The local folder chosen, if one was.
  final String? folder;
  final String deviceName;

  /// Whether this Device is signed in to Dropbox.
  final bool dropboxSignedIn;

  /// The WebDAV server set up, if one was: its folder's address and the
  /// user name signed in with.
  final String? webDavAddress;
  final String? webDavUser;

  /// Whether this Device has a WebDAV server set up, with its password.
  final bool webDavSignedIn;

  /// Setting sync up is in progress (the Sync Location being tested).
  final bool settingUp;

  /// Why the folder chosen last could not be used.
  final SyncLocationProblem? setupProblem;
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
    this.enabled = false,
    this.locationKind,
    this.folder,
    this.deviceName = '',
    this.dropboxSignedIn = false,
    this.webDavAddress,
    this.webDavUser,
    this.webDavSignedIn = false,
    this.settingUp = false,
    this.setupProblem,
    this.status = const SyncStatus(),
    this.askAboutHold,
    this.declinedHold,
    this.alerts = const [],
    this.devices = const [],
  });

  SyncState copyWith({
    bool? loaded,
    bool? enabled,
    SyncLocationKind? locationKind,
    String? folder,
    String? deviceName,
    bool? dropboxSignedIn,
    String? webDavAddress,
    String? webDavUser,
    bool? webDavSignedIn,
    bool? settingUp,
    SyncLocationProblem? Function()? setupProblem,
    SyncStatus? status,
    RemovalGuardHold? Function()? askAboutHold,
    RemovalGuardHold? Function()? declinedHold,
    List<SyncAlert>? alerts,
    List<KnownDevice>? devices,
  }) =>
      SyncState(
        locationKinds: locationKinds,
        loaded: loaded ?? this.loaded,
        enabled: enabled ?? this.enabled,
        locationKind: locationKind ?? this.locationKind,
        folder: folder ?? this.folder,
        deviceName: deviceName ?? this.deviceName,
        dropboxSignedIn: dropboxSignedIn ?? this.dropboxSignedIn,
        webDavAddress: webDavAddress ?? this.webDavAddress,
        webDavUser: webDavUser ?? this.webDavUser,
        webDavSignedIn: webDavSignedIn ?? this.webDavSignedIn,
        settingUp: settingUp ?? this.settingUp,
        setupProblem: setupProblem != null ? setupProblem() : this.setupProblem,
        status: status ?? this.status,
        askAboutHold: askAboutHold != null ? askAboutHold() : this.askAboutHold,
        declinedHold: declinedHold != null ? declinedHold() : this.declinedHold,
        alerts: alerts ?? this.alerts,
        devices: devices ?? this.devices,
      );

  @override
  List<Object?> get props => [
        locationKinds,
        loaded,
        enabled,
        locationKind,
        folder,
        deviceName,
        dropboxSignedIn,
        webDavAddress,
        webDavUser,
        webDavSignedIn,
        settingUp,
        setupProblem,
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
/// a refused sign-in is alerted each time sync stops for it.
class SyncCubit extends Cubit<SyncState> {
  final SyncRepository _repository;
  final List<StreamSubscription<Object>> _subscriptions = [];
  Set<SyncAlert> _problems = {};

  /// The refused sign-in alerted last.
  SyncError? _signInAlerted;

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
        enabled: setup.enabled,
        locationKind: setup.locationKind,
        folder: setup.folder,
        deviceName: setup.deviceName,
        dropboxSignedIn: signedIn,
        webDavAddress: setup.webDavAddress,
        webDavUser: setup.webDavUser,
        webDavSignedIn: webDavSignedIn,
        status: _repository.status));
    await _readDevices();
  }

  /// Notes [folder] as the one to sync with when sync is turned on.
  void chooseFolder(String folder) => emit(state.copyWith(
      locationKind: SyncLocationKind.localFolder,
      folder: folder,
      setupProblem: () => null));

  /// Makes Dropbox the Sync Location, as [changeFolder] does a folder:
  /// while sync is on, moves sync there; while it is off, turns it on with
  /// Dropbox, under [deviceName] if given. This Device must be signed in
  /// ([finishDropboxSignIn]).
  Future<void> chooseDropbox({String? deviceName}) async {
    if (!state.enabled) {
      emit(state.copyWith(locationKind: SyncLocationKind.dropbox));
      return enableDropbox(deviceName: deviceName);
    }
    await _settingUp(_repository.moveToDropbox);
  }

  /// Turns sync on with Dropbox, under [deviceName] if given, as [enable]
  /// does with a folder.
  Future<void> enableDropbox({String? deviceName}) {
    final name = deviceName?.trim() ?? '';
    return _settingUp(() => _repository.enableDropbox(
        deviceName: name.isEmpty ? state.deviceName : name));
  }

  /// Starts signing in to Dropbox, returning the Dropbox page the owner
  /// opens to allow Bloomee.
  Uri beginDropboxSignIn() => _repository.beginDropboxSignIn();

  /// Finishes the sign-in with the [code] the owner pasted from that page;
  /// completes with why it failed, or null once signed in.
  Future<SyncLocationProblem?> finishDropboxSignIn(String code) async {
    final problem = await _repository.finishDropboxSignIn(code);
    try {
      await load();
    } catch (error) {
      log('Library Sync setup could not be read: $error', name: 'SyncCubit');
    }
    return problem;
  }

  /// Makes the WebDAV server the Sync Location, as [chooseDropbox] does
  /// Dropbox: while sync is off, turns it on under [deviceName] if given.
  /// This Device must be signed in ([signInToWebDav]).
  Future<void> chooseWebDav({String? deviceName}) async {
    if (!state.enabled) {
      emit(state.copyWith(locationKind: SyncLocationKind.webDav));
      return enableWebDav(deviceName: deviceName);
    }
    await _settingUp(_repository.moveToWebDav);
  }

  /// Turns sync on with the WebDAV server, under [deviceName] if given, as
  /// [enable] does with a folder.
  Future<void> enableWebDav({String? deviceName}) {
    final name = deviceName?.trim() ?? '';
    return _settingUp(() => _repository.enableWebDav(
        deviceName: name.isEmpty ? state.deviceName : name));
  }

  /// Signs in to the WebDAV folder at [address] as [user] with [password],
  /// once it passes its test; completes with why it cannot be used, or null
  /// once signed in.
  Future<SyncLocationProblem?> signInToWebDav(
      {required String address,
      required String user,
      required String password}) async {
    final problem = await _repository.signInToWebDav(
        address: address, user: user, password: password);
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

  /// Runs [change] to the setup, showing it under way, then what problem
  /// it met.
  Future<void> _settingUp(
      Future<SyncLocationProblem?> Function() change) async {
    emit(state.copyWith(settingUp: true, setupProblem: () => null));
    SyncLocationProblem? problem;
    try {
      problem = await change();
    } finally {
      if (!isClosed) {
        emit(state.copyWith(settingUp: false, setupProblem: () => problem));
      }
    }
    await load();
  }

  /// Makes [folder] the Sync Location, once it passes its test: while sync
  /// is on, moves sync there; while it is off, turns it on with [folder],
  /// under [deviceName] if given, as [enable] does. Otherwise
  /// [SyncState.setupProblem] says why it cannot be used, and sync stays as
  /// it was; while it is off, [folder] stays noted, as [chooseFolder] does,
  /// for when sync is turned on.
  Future<void> changeFolder(String folder, {String? deviceName}) async {
    if (!state.enabled) {
      chooseFolder(folder);
      return enable(folder, deviceName: deviceName);
    }
    await _settingUp(() => _repository.moveTo(folder));
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

  /// Turns sync on with [folder], under [deviceName] if given, once the
  /// folder passes its test; otherwise [SyncState.setupProblem] says why it
  /// cannot be used.
  Future<void> enable(String folder, {String? deviceName}) {
    final name = deviceName?.trim() ?? '';
    return _settingUp(() => _repository.enable(
        folder: folder, deviceName: name.isEmpty ? state.deviceName : name));
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
    final signInRefused =
        error is SyncSignInNeeded && !identical(error, _signInAlerted);
    if (signInRefused) _signInAlerted = error;
    final kind = error is SyncSignInNeeded ? error.kind : null;
    final alert = SignInNeededAlert(kind);
    emit(state.copyWith(
        status: status,
        // A refused Dropbox sign-in is forgotten; a WebDAV password is kept.
        dropboxSignedIn:
            signInRefused && kind == SyncLocationKind.dropbox ? false : null,
        alerts: signInRefused && !state.alerts.contains(alert)
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
