import 'dart:developer';
import 'dart:io';

import 'package:Bloomee/blocs/sync/sync_cubit.dart';
import 'package:Bloomee/core/models/sync/known_device.dart';
import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:Bloomee/core/models/sync/sync_setup.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/l10n/app_localizations.dart';
import 'package:Bloomee/screens/screen/home_views/setting_views/setting_shared_widgets.dart';
import 'package:Bloomee/screens/widgets/bloomee_ui_kit/bloomee_dialog.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/screens/widgets/sync_alert_listener.dart';
import 'package:Bloomee/services/download/download_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

/// Library Sync settings: turning it on, the Sync Location, this Device's
/// name and the status line.
class LibrarySyncSettings extends StatefulWidget {
  const LibrarySyncSettings({super.key});

  @override
  State<LibrarySyncSettings> createState() => _LibrarySyncSettingsState();
}

class _LibrarySyncSettingsState extends State<LibrarySyncSettings> {
  final TextEditingController _deviceName = TextEditingController();
  final FocusNode _deviceNameFocus = FocusNode();
  late final SyncCubit _cubit;

  /// Changes after the switch was turned, so that it is rebuilt showing
  /// whether sync really is on (turning it on may be refused).
  int _switchKey = 0;

  @override
  void initState() {
    super.initState();
    _cubit = context.read<SyncCubit>();
    _deviceName.text = _cubit.state.setup.deviceName;
    _cubit.load().then((_) {
      if (mounted && !_deviceNameFocus.hasFocus) {
        _deviceName.text = _cubit.state.setup.deviceName;
      }
    },
        onError: (Object error) => log(
            'Library Sync settings could not load: $error',
            name: 'LibrarySyncSettings'));
    _deviceNameFocus.addListener(() {
      if (!_deviceNameFocus.hasFocus) _saveDeviceName();
    });
  }

  @override
  void dispose() {
    // A name typed but not submitted is kept when leaving the screen.
    _saveDeviceName();
    _deviceName.dispose();
    _deviceNameFocus.dispose();
    super.dispose();
  }

  void _saveDeviceName() {
    final name = _deviceName.text.trim();
    if (name.isEmpty) {
      if (mounted) _deviceName.text = _cubit.state.setup.deviceName;
    } else if (name != _cubit.state.setup.deviceName) {
      _cubit.renameDevice(name);
    }
  }

  /// The folder the owner picks, or null if they picked none or the system
  /// folder picker failed (which is shown). On Android, the picker gives
  /// Bloomee lasting access to the folder and answers its tree URI, as for
  /// the download folder.
  Future<String?> _pickFolder() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      return Platform.isAndroid
          ? await DownloadStorage.pickFolder()
          : await FilePicker.platform.getDirectoryPath();
    } catch (error) {
      SnackbarService.showMessage(
          l10n.snackbarSyncFolderPickerFailed('$error'));
      return null;
    }
  }

  Future<void> _turn(bool on) async {
    final cubit = _cubit;
    if (on) {
      final chosen = cubit.state.setup.locationKind;
      // A choice this build does not offer (one made on another platform's
      // build, say) is asked again.
      final kind = chosen != null && cubit.state.locationKinds.contains(chosen)
          ? chosen
          : await _askLocation();
      if (kind != null && mounted) await _choose(kind, again: false);
    } else {
      await cubit.disable();
    }
    if (mounted) setState(() => _switchKey++);
  }

  /// The kind of Sync Location to turn sync on with, when none was chosen:
  /// the only one offered, or the one the owner picks.
  Future<SyncLocationKind?> _askLocation() async {
    final kinds = _cubit.state.locationKinds;
    if (kinds.length < 2) return kinds.firstOrNull;
    final l10n = AppLocalizations.of(context)!;
    SyncLocationKind? chosen;
    await showBloomeeDialog<void>(
      context: context,
      title: l10n.dialogSyncChooseLocationTitle,
      icon: Icons.sync_rounded,
      actions: [
        for (final kind in kinds)
          BloomeeDialogAction.filled(_kindName(l10n, kind),
              onPressed: () => chosen = kind),
      ],
    );
    return chosen;
  }

  static String _kindName(AppLocalizations l10n, SyncLocationKind kind) =>
      switch (kind) {
        SyncLocationKind.dropbox => l10n.syncDropbox,
        SyncLocationKind.webDav => l10n.syncWebDav,
        SyncLocationKind.localFolder => l10n.syncLocalFolder,
      };

  /// Makes a Sync Location of [kind] the Sync Location: while sync is on,
  /// this moves sync there; while it is off, it turns sync on. First the
  /// owner signs in, or picks the folder, unless this Device is signed in
  /// already or has a folder chosen and they are not choosing [again]. Signing
  /// in to the WebDAV server sync is on with already goes on with it.
  Future<void> _choose(SyncLocationKind kind, {required bool again}) async {
    final state = _cubit.state;
    final SyncLocationChoice? choice = switch (kind) {
      SyncLocationKind.dropbox =>
        state.dropboxSignedIn || await _signInToDropbox()
            ? const SyncLocationChoice.dropbox()
            : null,
      SyncLocationKind.webDav =>
        (state.webDavSignedIn && !again) || await _signInToWebDav()
            ? const SyncLocationChoice.webDav()
            : null,
      SyncLocationKind.localFolder => switch (
            (again ? null : state.setup.folder) ?? await _pickFolder()) {
          final folder? => SyncLocationChoice.folder(folder),
          null => null,
        },
    };
    if (choice == null || !mounted) return;
    final setup = _cubit.state.setup;
    if (kind == SyncLocationKind.webDav &&
        setup.enabled &&
        setup.locationKind == SyncLocationKind.webDav) {
      return;
    }
    await _cubit.choose(choice, deviceName: _deviceName.text);
  }

  /// Signs this Device in to Dropbox; completes with whether it is. Without
  /// a Dropbox app key entered, first asks for the owner's own app.
  Future<bool> _signInToDropbox() async {
    if (!_cubit.state.hasDropboxApp && !await _editDropboxApp()) {
      return false;
    }
    final page = await _cubit.beginDropboxSignIn();
    if (page == null || !mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierColor: Colors.black54,
          builder: (_) => _DropboxSignInDialog(cubit: _cubit, page: page),
        ) ??
        false;
  }

  /// Asks for the key of the owner's own Dropbox app; completes with whether
  /// it was saved.
  Future<bool> _editDropboxApp() async {
    final changed = await showDialog<bool>(
          context: context,
          barrierColor: Colors.black54,
          builder: (_) => _DropboxAppDialog(cubit: _cubit),
        ) ??
        false;
    if (mounted) setState(() => _switchKey++);
    return changed;
  }

  /// Asks for the WebDAV server's address, user name and password, and
  /// signs in with them; completes with whether this Device is signed in.
  Future<bool> _signInToWebDav() async =>
      await showDialog<bool>(
        context: context,
        barrierColor: Colors.black54,
        builder: (_) => _WebDavSignInDialog(cubit: _cubit),
      ) ??
      false;

  /// Signs this Device out of [kind].
  Future<void> _signOutOf(SyncLocationKind kind) async {
    final l10n = AppLocalizations.of(context)!;
    if (!await _cubit.signOutOf(kind)) {
      SnackbarService.showMessage(l10n.snackbarSyncSignOutFailed);
    }
    if (mounted) setState(() => _switchKey++);
  }

  /// The button signing this Device out of [kind].
  Widget _signOutButton(SyncLocationKind kind, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _signOutOf(kind),
            icon: const Icon(Icons.logout_rounded),
            label: Text(label),
          ),
        ),
      );

  Future<void> _forget(KnownDevice device) async {
    final l10n = AppLocalizations.of(context)!;
    var confirmed = false;
    await showBloomeeDialog<void>(
      context: context,
      title: l10n.dialogSyncForgetTitle(device.deviceName),
      subtitle: l10n.dialogSyncForgetBody(device.deviceName),
      icon: Icons.phonelink_erase_rounded,
      actions: [
        BloomeeDialogAction.text(l10n.buttonCancel),
        BloomeeDialogAction.filled(l10n.buttonSyncForget,
            isDestructive: true, onPressed: () => confirmed = true),
      ],
    );
    if (confirmed && !await _cubit.forgetDevice(device.deviceId)) {
      SnackbarService.showMessage(
          l10n.snackbarSyncForgetFailed(device.deviceName));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Default_Theme.themeColor,
      appBar: AppBar(
        backgroundColor: Default_Theme.themeColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          l10n.syncTitle,
          style: const TextStyle(
            color: Default_Theme.primaryColor1,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ).merge(Default_Theme.secondoryTextStyleMedium),
        ),
      ),
      body: BlocBuilder<SyncCubit, SyncState>(
        builder: (context, state) => Column(children: [
          if (state.settingUp || state.status.running)
            const LinearProgressIndicator(),
          Expanded(
            child: AbsorbPointer(
              absorbing: state.settingUp,
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                children: [
                  SettingCard(children: [
                    SettingToggleTile(
                      key: ValueKey(_switchKey),
                      icon: Icons.sync_rounded,
                      title: l10n.syncEnableTitle,
                      subtitle: l10n.syncEnableSubtitle,
                      value: state.setup.enabled,
                      onChanged: _turn,
                    ),
                    if (state.setupProblem case final problem?) ...[
                      const SettingDivider(),
                      SettingInfoText(
                        text:
                            problemText(l10n, problem, state.setupProblemKind),
                        color: Colors.redAccent,
                      ),
                    ],
                  ]),
                  const SizedBox(height: 28),
                  SettingSectionHeader(label: l10n.syncLocationHeader),
                  SettingCard(children: [
                    for (final (index, kind)
                        in state.locationKinds.indexed) ...[
                      if (index > 0) const SettingDivider(),
                      ..._locationTiles(l10n, state, kind),
                    ],
                    if (state.setup.enabled)
                      SettingInfoText(text: l10n.syncLocationMoveNote),
                  ]),
                  const SizedBox(height: 28),
                  SettingSectionHeader(label: l10n.syncDeviceHeader),
                  SettingCard(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: TextField(
                        controller: _deviceName,
                        focusNode: _deviceNameFocus,
                        onSubmitted: (_) => _saveDeviceName(),
                        style: const TextStyle(
                            color: Default_Theme.primaryColor2, fontSize: 15),
                        decoration: InputDecoration(
                          labelText: l10n.syncDeviceName,
                          labelStyle: TextStyle(
                              color: Default_Theme.primaryColor2
                                  .withValues(alpha: 0.5)),
                        ),
                      ),
                    ),
                    SettingInfoText(text: l10n.syncDeviceNameSubtitle),
                  ]),
                  if (state.setup.enabled && state.devices.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    SettingSectionHeader(label: l10n.syncDevicesHeader),
                    SettingCard(children: [
                      for (final device in state.devices)
                        _KnownDeviceTile(
                          device: device,
                          onForget: device.isThisDevice
                              ? null
                              : () => _forget(device),
                        ),
                      SettingInfoText(text: l10n.syncDevicesNote),
                    ]),
                  ],
                  if (state.setup.enabled) ...[
                    const SizedBox(height: 28),
                    SettingSectionHeader(label: l10n.syncStatusHeader),
                    SettingCard(children: [
                      SettingInfoText(
                        text: _statusLine(l10n, state),
                        color: Default_Theme.primaryColor2,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Wrap(spacing: 8, children: [
                          TextButton.icon(
                            onPressed: state.status.running
                                ? null
                                : () => context.read<SyncCubit>().syncNow(),
                            icon: const Icon(Icons.sync_rounded),
                            label: Text(l10n.syncNow),
                          ),
                          if (state.declinedHold case final hold?)
                            TextButton.icon(
                              onPressed: () async {
                                final confirm =
                                    await showRemovalGuardDialog(context, hold);
                                if (confirm == true) {
                                  await _cubit.answerRemovalGuard(hold,
                                      confirm: true);
                                }
                              },
                              icon: const Icon(Icons.rule_rounded),
                              label: Text(l10n.syncReviewRemovals),
                            ),
                        ]),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// The choice of a Sync Location of [kind]: its tile, which makes it the
  /// Sync Location (signing in first where needed), and its note.
  List<Widget> _locationTiles(
      AppLocalizations l10n, SyncState state, SyncLocationKind kind) {
    final inUse =
        state.locationKinds.length > 1 && state.setup.locationKind == kind
            ? l10n.syncLocationInUse
            : null;
    return switch (kind) {
      SyncLocationKind.dropbox => [
          SettingNavTile(
            icon: Icons.cloud_outlined,
            title: l10n.syncDropbox,
            subtitle: state.dropboxSignedIn
                ? l10n.syncDropboxSignedIn
                : state.hasDropboxApp
                    ? l10n.syncDropboxSignedOut
                    : l10n.syncDropboxNeedsAppKey,
            badge: inUse,
            onTap: () => _choose(kind, again: false),
          ),
          SettingInfoText(text: l10n.syncDropboxNote),
          if (state.dropboxSignedIn)
            _signOutButton(kind, l10n.buttonDropboxSignOut),
          SettingNavTile(
            icon: Icons.key_rounded,
            title: l10n.syncDropboxOwnApp,
            subtitle: switch (state.setup.dropboxAppKey) {
              final key? => l10n.syncDropboxOwnAppKey(key),
              null => l10n.syncDropboxOwnAppNeeded,
            },
            onTap: _editDropboxApp,
          ),
        ],
      SyncLocationKind.webDav => [
          SettingNavTile(
            icon: Icons.dns_outlined,
            title: l10n.syncWebDav,
            subtitle: switch ((
              state.setup.webDavUser,
              state.setup.webDavAddress
            )) {
              (final user?, final address?) when state.webDavSignedIn =>
                l10n.syncWebDavAccount(user, address),
              _ => l10n.syncWebDavNotSetUp,
            },
            badge: inUse,
            onTap: () => _choose(kind, again: true),
          ),
          SettingInfoText(text: l10n.syncWebDavNote),
          if (state.webDavSignedIn)
            _signOutButton(kind, l10n.buttonWebDavSignOut),
        ],
      SyncLocationKind.localFolder => [
          SettingNavTile(
            icon: Icons.folder_outlined,
            title: l10n.syncLocalFolder,
            subtitle: state.setup.folderShownAs ?? l10n.syncNoFolder,
            badge: inUse,
            onTap: () => _choose(kind, again: true),
          ),
          SettingInfoText(text: l10n.syncLocalFolderNote),
        ],
    };
  }

  static String _statusLine(AppLocalizations l10n, SyncState state) {
    final status = state.status;
    final lines = [
      if (status.running) l10n.syncSyncing,
      if (status.lastSyncedAt case final at?)
        l10n.syncLastSynced(formatSyncTime(l10n, at))
      else
        l10n.syncNeverSynced,
      if (status.lastError case final error?)
        l10n.syncLastError(
            formatSyncTime(l10n, error.at), _describe(l10n, error)),
    ];
    return lines.join('\n');
  }

  static String _describe(AppLocalizations l10n, SyncError error) =>
      switch (error) {
        SyncLocationUnreachable() => l10n.syncErrorUnreachable,
        SyncSignInNeeded(kind: SyncLocationKind.webDav) =>
          l10n.syncErrorWebDavSignInNeeded,
        SyncSignInNeeded() => l10n.syncErrorSignInNeeded,
        SyncKeyringUnavailable() => l10n.syncErrorKeyringUnavailable,
        SyncAppKeyRefused() => l10n.syncDropboxAppKeyRefused,
        SyncFailed(:final detail) => l10n.syncErrorFailed(detail),
        SyncNeedsOwner(:final outcome) => switch (outcome) {
            SyncHeld(declined: true) => l10n.syncErrorPaused,
            SyncHeld() => l10n.syncErrorHeld,
            SyncUpdateNeeded() => l10n.syncErrorUpdateNeeded,
            SyncCompleted(:final skipped) =>
              l10n.syncErrorSkipped(skipped.length),
          },
      };
}

/// What [problem], met setting up a Sync Location of [kind], means for the
/// owner.
String problemText(AppLocalizations l10n, SyncLocationProblem problem,
        SyncLocationKind? kind) =>
    switch ((problem, kind)) {
      (SyncLocationProblem.notFound, SyncLocationKind.dropbox) =>
        l10n.syncDropboxNotReachable,
      (SyncLocationProblem.notFound, SyncLocationKind.webDav) =>
        l10n.syncWebDavNotReachable,
      (SyncLocationProblem.notFound, _) when Platform.isAndroid =>
        l10n.syncFolderNotFoundAndroid,
      (SyncLocationProblem.notFound, _) => l10n.syncFolderNotFound,
      (SyncLocationProblem.notWritable, SyncLocationKind.dropbox) =>
        l10n.syncDropboxNotWritable,
      (SyncLocationProblem.notWritable, SyncLocationKind.webDav) =>
        l10n.syncWebDavNotWritable,
      (SyncLocationProblem.notWritable, _) => l10n.syncFolderNotWritable,
      (SyncLocationProblem.signInRefused, SyncLocationKind.webDav) =>
        l10n.syncWebDavSignInRefused,
      (SyncLocationProblem.signInRefused, _) => l10n.syncSignInRefused,
      (SyncLocationProblem.keyringUnavailable, SyncLocationKind.webDav) =>
        l10n.syncWebDavKeyringUnavailable,
      (SyncLocationProblem.keyringUnavailable, _) =>
        l10n.syncKeyringUnavailable,
      (SyncLocationProblem.appKeyRefused, _) => l10n.syncDropboxAppKeyRefused,
      (SyncLocationProblem.invalidAddress, _) => l10n.syncWebDavInvalidAddress,
      (SyncLocationProblem.insecureAddress, _) =>
        l10n.syncWebDavInsecureAddress,
      (SyncLocationProblem.refused, SyncLocationKind.dropbox) =>
        l10n.syncDropboxRefused,
      (SyncLocationProblem.refused, SyncLocationKind.webDav) =>
        l10n.syncWebDavRefused,
      (SyncLocationProblem.refused, _) => l10n.syncLocationRefused,
    };

/// Signing in to Dropbox: the owner opens the Dropbox page, allows Bloomee,
/// and pastes back the code Dropbox shows. Pops with whether this Device is
/// signed in.
class _DropboxSignInDialog extends StatefulWidget {
  final SyncCubit cubit;

  /// The Dropbox page of the sign-in begun.
  final Uri page;

  const _DropboxSignInDialog({required this.cubit, required this.page});

  @override
  State<_DropboxSignInDialog> createState() => _DropboxSignInDialogState();
}

class _DropboxSignInDialogState extends State<_DropboxSignInDialog> {
  final TextEditingController _code = TextEditingController();
  bool _pageNotOpened = false;
  bool _signingIn = false;
  SyncLocationProblem? _problem;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _openPage() async {
    var opened = false;
    try {
      opened =
          await launchUrl(widget.page, mode: LaunchMode.externalApplication);
    } catch (error) {
      log('The Dropbox page could not be opened: $error',
          name: 'LibrarySyncSettings');
    }
    if (mounted) setState(() => _pageNotOpened = !opened);
  }

  Future<void> _finish() async {
    final code = _code.text.trim();
    if (code.isEmpty || _signingIn) return;
    setState(() {
      _signingIn = true;
      _problem = null;
    });
    SyncLocationProblem? problem;
    try {
      problem = await widget.cubit.finishDropboxSignIn(code);
    } catch (error) {
      log('Dropbox sign-in failed: $error', name: 'LibrarySyncSettings');
      problem = SyncLocationProblem.signInRefused;
    }
    if (!mounted) return;
    if (problem == null) return Navigator.of(context).pop(true);
    setState(() {
      _signingIn = false;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final secondary = Default_Theme.primaryColor2.withValues(alpha: 0.7);
    return BloomeeDialogSurface(
      title: l10n.dialogDropboxSignInTitle,
      icon: Icons.cloud_outlined,
      body: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.dialogDropboxSignInBody,
                style: TextStyle(color: secondary, fontSize: 14)),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _openPage,
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(l10n.buttonDropboxOpenPage),
            ),
            if (_pageNotOpened) ...[
              Text(l10n.dialogDropboxPageNotOpened,
                  style: TextStyle(color: secondary, fontSize: 13)),
              const SizedBox(height: 4),
              SelectableText(widget.page.toString(),
                  style: const TextStyle(
                      color: Default_Theme.primaryColor2, fontSize: 12)),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _code,
              enabled: !_signingIn,
              autocorrect: false,
              onSubmitted: (_) => _finish(),
              style: const TextStyle(
                  color: Default_Theme.primaryColor2, fontSize: 15),
              decoration: InputDecoration(
                labelText: l10n.dialogDropboxCode,
                labelStyle: TextStyle(color: secondary),
              ),
            ),
            if (_problem case final problem?) ...[
              const SizedBox(height: 8),
              Text(problemText(l10n, problem, SyncLocationKind.dropbox),
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ],
            const SizedBox(height: 12),
            // Wraps on a narrow screen rather than overflowing.
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              overflowAlignment: OverflowBarAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.buttonCancel),
                ),
                ValueListenableBuilder(
                  valueListenable: _code,
                  builder: (context, value, _) => FilledButton(
                    onPressed: _signingIn || value.text.trim().isEmpty
                        ? null
                        : _finish,
                    child: _signingIn
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(l10n.buttonDropboxSignIn),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The owner's own Dropbox app: the steps to register one, and its key,
/// which this Device then signs in through. Pops with whether it was
/// saved.
class _DropboxAppDialog extends StatefulWidget {
  final SyncCubit cubit;

  const _DropboxAppDialog({required this.cubit});

  @override
  State<_DropboxAppDialog> createState() => _DropboxAppDialogState();
}

class _DropboxAppDialogState extends State<_DropboxAppDialog> {
  /// Where Dropbox apps are registered.
  static final _appConsole =
      Uri.parse('https://www.dropbox.com/developers/apps');

  late final TextEditingController _key =
      TextEditingController(text: widget.cubit.state.setup.dropboxAppKey ?? '');
  bool _saving = false;
  bool _failed = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _openConsole() async {
    try {
      await launchUrl(_appConsole, mode: LaunchMode.externalApplication);
    } catch (error) {
      log('The Dropbox App Console could not be opened: $error',
          name: 'LibrarySyncSettings');
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    final saved = await widget.cubit.setDropboxAppKey(_key.text);
    if (!mounted) return;
    if (saved) return Navigator.of(context).pop(true);
    setState(() {
      _saving = false;
      _failed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = widget.cubit.state;
    final secondary = Default_Theme.primaryColor2.withValues(alpha: 0.7);
    final noteStyle = TextStyle(color: secondary, fontSize: 13);
    return BloomeeDialogSurface(
      title: l10n.dialogDropboxAppTitle,
      icon: Icons.key_rounded,
      body: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.dialogDropboxAppBody,
                style: TextStyle(color: secondary, fontSize: 14)),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _openConsole,
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(l10n.buttonDropboxOpenAppConsole),
            ),
            SelectableText(_appConsole.toString(),
                style: const TextStyle(
                    color: Default_Theme.primaryColor2, fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              enabled: !_saving,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _save(),
              style: const TextStyle(
                  color: Default_Theme.primaryColor2, fontSize: 15),
              decoration: InputDecoration(
                labelText: l10n.dialogDropboxAppKey,
                labelStyle: TextStyle(color: secondary),
              ),
            ),
            const SizedBox(height: 8),
            Text(l10n.dialogDropboxAppRequiredNote, style: noteStyle),
            if (state.dropboxSignedIn) ...[
              const SizedBox(height: 8),
              Text(l10n.dialogDropboxAppSignOutNote, style: noteStyle),
            ],
            if (_failed) ...[
              const SizedBox(height: 8),
              Text(l10n.dialogDropboxAppKeyFailed,
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ],
            const SizedBox(height: 12),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              overflowAlignment: OverflowBarAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.buttonCancel),
                ),
                ListenableBuilder(
                  listenable: _key,
                  builder: (context, _) => FilledButton(
                    // An empty key would leave nothing to sign in through,
                    // unless it clears the one entered.
                    onPressed: _saving ||
                            (state.setup.dropboxAppKey == null &&
                                _key.text.trim().isEmpty)
                        ? null
                        : _save,
                    child: _saving
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(l10n.buttonDropboxAppSave),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Signing in to a WebDAV server: the owner enters the address of the folder
/// to sync in, their user name and password; Bloomee tests the folder before
/// keeping them. Pops with whether this Device is signed in.
class _WebDavSignInDialog extends StatefulWidget {
  final SyncCubit cubit;

  const _WebDavSignInDialog({required this.cubit});

  @override
  State<_WebDavSignInDialog> createState() => _WebDavSignInDialogState();
}

class _WebDavSignInDialogState extends State<_WebDavSignInDialog> {
  late final TextEditingController _address =
      TextEditingController(text: widget.cubit.state.setup.webDavAddress ?? '');
  late final TextEditingController _user =
      TextEditingController(text: widget.cubit.state.setup.webDavUser ?? '');
  final TextEditingController _password = TextEditingController();
  bool _signingIn = false;
  SyncLocationProblem? _problem;

  @override
  void dispose() {
    _address.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _complete =>
      _address.text.trim().isNotEmpty &&
      _user.text.trim().isNotEmpty &&
      _password.text.isNotEmpty;

  Future<void> _finish() async {
    if (!_complete || _signingIn) return;
    setState(() {
      _signingIn = true;
      _problem = null;
    });
    SyncLocationProblem? problem;
    try {
      problem = await widget.cubit.signInToWebDav(
          address: _address.text, user: _user.text, password: _password.text);
    } catch (error) {
      log('WebDAV sign-in failed: $error', name: 'LibrarySyncSettings');
      problem = SyncLocationProblem.notFound;
    }
    if (!mounted) return;
    if (problem == null) return Navigator.of(context).pop(true);
    setState(() {
      _signingIn = false;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final secondary = Default_Theme.primaryColor2.withValues(alpha: 0.7);
    InputDecoration decoration(String label) => InputDecoration(
        labelText: label, labelStyle: TextStyle(color: secondary));
    const fieldStyle =
        TextStyle(color: Default_Theme.primaryColor2, fontSize: 15);
    return BloomeeDialogSurface(
      title: l10n.dialogWebDavTitle,
      icon: Icons.dns_outlined,
      body: SingleChildScrollView(
        child: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.dialogWebDavBody,
                  style: TextStyle(color: secondary, fontSize: 14)),
              const SizedBox(height: 8),
              TextField(
                controller: _address,
                enabled: !_signingIn,
                autocorrect: false,
                keyboardType: TextInputType.url,
                autofillHints: const [AutofillHints.url],
                style: fieldStyle,
                decoration: decoration(l10n.dialogWebDavAddress),
              ),
              TextField(
                controller: _user,
                enabled: !_signingIn,
                autocorrect: false,
                autofillHints: const [AutofillHints.username],
                style: fieldStyle,
                decoration: decoration(l10n.dialogWebDavUser),
              ),
              TextField(
                controller: _password,
                enabled: !_signingIn,
                autocorrect: false,
                obscureText: true,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _finish(),
                style: fieldStyle,
                decoration: decoration(l10n.dialogWebDavPassword),
              ),
              if (_problem case final problem?) ...[
                const SizedBox(height: 8),
                Text(problemText(l10n, problem, SyncLocationKind.webDav),
                    style:
                        const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              // Wraps on a narrow screen rather than overflowing.
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(l10n.buttonCancel),
                  ),
                  ListenableBuilder(
                    listenable: Listenable.merge([_address, _user, _password]),
                    builder: (context, _) => FilledButton(
                      onPressed: _signingIn || !_complete ? null : _finish,
                      child: _signingIn
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(l10n.buttonWebDavConnect),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A known Device: its name, when it last synced, and the way to forget it
/// ([onForget]; null for this Device).
class _KnownDeviceTile extends StatelessWidget {
  final KnownDevice device;
  final VoidCallback? onForget;

  const _KnownDeviceTile({required this.device, this.onForget});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final secondary = Default_Theme.primaryColor2.withValues(alpha: 0.5);
    final lastSynced = switch (device.lastSyncedAt) {
      final at? => l10n.syncLastSynced(formatSyncTime(l10n, at)),
      null when device.isThisDevice => l10n.syncNeverSynced,
      null => l10n.syncDeviceLastSyncUnknown,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(children: [
        SettingIconBox(
            icon: device.isThisDevice
                ? Icons.smartphone_rounded
                : Icons.devices_other_rounded),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                device.isThisDevice
                    ? '${device.deviceName} · ${l10n.syncThisDevice}'
                    : device.deviceName,
                style: Default_Theme.secondoryTextStyleMedium.copyWith(
                  color: Default_Theme.primaryColor2,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(lastSynced,
                  style: Default_Theme.secondoryTextStyle
                      .copyWith(color: secondary, fontSize: 13)),
            ],
          ),
        ),
        if (onForget case final forget?)
          TextButton(onPressed: forget, child: Text(l10n.syncForgetDevice)),
      ]),
    );
  }
}
