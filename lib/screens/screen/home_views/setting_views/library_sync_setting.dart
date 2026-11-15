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
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
    _deviceName.text = _cubit.state.deviceName;
    _cubit.load().then((_) {
      if (mounted && !_deviceNameFocus.hasFocus) {
        _deviceName.text = _cubit.state.deviceName;
      }
    },
        onError: (Object error) =>
            debugPrint('Library Sync settings could not load: $error'));
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
      if (mounted) _deviceName.text = _cubit.state.deviceName;
    } else if (name != _cubit.state.deviceName) {
      _cubit.renameDevice(name);
    }
  }

  /// The folder the owner picks, or null if they picked none or the system
  /// folder picker failed (which is shown).
  Future<String?> _pickFolder() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      return await FilePicker.platform.getDirectoryPath();
    } catch (error) {
      SnackbarService.showMessage(
          l10n.snackbarSyncFolderPickerFailed('$error'));
      return null;
    }
  }

  Future<void> _turn(bool on) async {
    final cubit = _cubit;
    if (on) {
      final folder = cubit.state.folder ?? await _pickFolder();
      if (folder != null) {
        cubit.chooseFolder(folder);
        await cubit.enable(folder, deviceName: _deviceName.text);
      }
    } else {
      await cubit.disable();
    }
    if (mounted) setState(() => _switchKey++);
  }

  /// While sync is on, choosing another folder moves sync there.
  Future<void> _chooseFolder() async {
    final folder = await _pickFolder();
    if (folder != null && mounted) await _cubit.changeFolder(folder);
  }

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
                      value: state.enabled,
                      onChanged: _turn,
                    ),
                    if (state.setupProblem case final problem?) ...[
                      const SettingDivider(),
                      SettingInfoText(
                        text: switch (problem) {
                          SyncLocationProblem.notFound =>
                            l10n.syncFolderNotFound,
                          SyncLocationProblem.notWritable =>
                            l10n.syncFolderNotWritable,
                        },
                        color: Colors.redAccent,
                      ),
                    ],
                  ]),
                  const SizedBox(height: 28),
                  SettingSectionHeader(label: l10n.syncLocationHeader),
                  SettingCard(children: [
                    if (state.locationKinds
                        .contains(SyncLocationKind.localFolder)) ...[
                      SettingNavTile(
                        icon: Icons.folder_outlined,
                        title: l10n.syncLocalFolder,
                        subtitle: state.folder ?? l10n.syncNoFolder,
                        onTap: _chooseFolder,
                      ),
                      SettingInfoText(text: l10n.syncLocalFolderNote),
                      if (state.enabled)
                        SettingInfoText(text: l10n.syncFolderMoveNote),
                    ],
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
                  if (state.enabled && state.devices.isNotEmpty) ...[
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
                  if (state.enabled) ...[
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
