import 'package:Bloomee/blocs/sync/sync_cubit.dart';
import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:Bloomee/core/models/sync/sync_setup.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/l10n/app_localizations.dart';
import 'package:Bloomee/screens/widgets/bloomee_ui_kit/bloomee_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Shows, wherever the owner is in the app, what Library Sync needs them to
/// see: the Removal Guard's question and the alerts for a refused clock, an
/// unreadable Device State, a needed update, a refused sign-in (to Dropbox,
/// or to a WebDAV server) or an unreadable system keyring.
class SyncAlertListener extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  const SyncAlertListener(
      {super.key, required this.child, required this.navigatorKey});

  @override
  State<SyncAlertListener> createState() => _SyncAlertListenerState();
}

class _SyncAlertListenerState extends State<SyncAlertListener> {
  bool _showingAlert = false;

  /// Whether the Removal Guard's question is open: a sync meanwhile does not
  /// open a second one.
  bool _askingAboutHold = false;

  BuildContext get _dialogContext =>
      widget.navigatorKey.currentContext ?? context;

  Future<void> _showNextAlert(SyncState state) async {
    if (_showingAlert || state.alerts.isEmpty) return;
    final alert = state.alerts.first;
    _showingAlert = true;
    final dialogContext = _dialogContext;
    final l10n = AppLocalizations.of(dialogContext)!;
    final (title, body) = switch (alert) {
      ClockRefusedAlert(:final deviceName, :final changedAt) => (
          l10n.dialogSyncClockTitle,
          l10n.dialogSyncClockBody(deviceName, formatSyncTime(l10n, changedAt))
        ),
      UnreadableDeviceStateAlert(:final device) => (
          l10n.dialogSyncUnreadableTitle,
          l10n.dialogSyncUnreadableBody(device)
        ),
      UpdateNeededAlert(:final deviceName) => (
          l10n.dialogSyncUpdateTitle,
          l10n.dialogSyncUpdateBody(deviceName ?? l10n.dialogSyncAnotherDevice)
        ),
      SignInNeededAlert(kind: SyncLocationKind.webDav) => (
          l10n.dialogSyncWebDavSignInTitle,
          l10n.dialogSyncWebDavSignInBody
        ),
      SignInNeededAlert() => (
          l10n.dialogSyncSignInTitle,
          l10n.dialogSyncSignInBody
        ),
      KeyringUnavailableAlert() => (
          l10n.dialogSyncKeyringTitle,
          l10n.dialogSyncKeyringBody
        ),
    };
    await showBloomeeDialog<void>(
      context: dialogContext,
      title: title,
      subtitle: body,
      icon: Icons.sync_problem_rounded,
      actions: [BloomeeDialogAction.filled(l10n.buttonOk)],
    );
    _showingAlert = false;
    if (!mounted) return;
    final cubit = context.read<SyncCubit>();
    cubit.alertShown(alert);
    await _showNextAlert(cubit.state);
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<SyncCubit, SyncState>(
          listenWhen: (previous, current) =>
              current.askAboutHold != null &&
              !identical(previous.askAboutHold, current.askAboutHold),
          listener: (context, state) async {
            if (_askingAboutHold) return;
            _askingAboutHold = true;
            final cubit = context.read<SyncCubit>();
            final hold = state.askAboutHold!;
            final confirm = await showRemovalGuardDialog(_dialogContext, hold);
            _askingAboutHold = false;
            if (confirm == null) {
              cubit.removalGuardDismissed(hold);
            } else {
              await cubit.answerRemovalGuard(hold, confirm: confirm);
            }
          },
        ),
        BlocListener<SyncCubit, SyncState>(
          listenWhen: (previous, current) => current.alerts.isNotEmpty,
          listener: (context, state) => _showNextAlert(state),
        ),
      ],
      child: widget.child,
    );
  }
}

/// [time] as the sync screens show it, in this Device's time zone.
String formatSyncTime(AppLocalizations l10n, DateTime time) =>
    DateFormat.yMd(l10n.localeName).add_jm().format(time.toLocal());

/// Asks the owner about a merge the Removal Guard holds, showing what it
/// would remove and from which Device. Completes with whether they confirmed
/// it.
Future<bool?> showRemovalGuardDialog(
    BuildContext context, RemovalGuardHold hold) async {
  final l10n = AppLocalizations.of(context)!;
  bool? confirmed;
  String song(HeldRemoval removal) => removal.title ?? removal.mediaId ?? '';
  String describe(HeldRemoval removal) => switch (removal.kind) {
        RemovalKind.playlist =>
          l10n.dialogSyncGuardPlaylistDeleted(removal.playlistName ?? ''),
        RemovalKind.song => l10n.dialogSyncGuardSongRemoved(
            song(removal), removal.playlistName ?? ''),
        RemovalKind.like => l10n.dialogSyncGuardUnliked(song(removal)),
        // Unsaves are not held by the Removal Guard.
        RemovalKind.album || RemovalKind.artist => song(removal),
      };
  final secondary = Default_Theme.primaryColor2.withValues(alpha: 0.6);
  await showBloomeeDialog<void>(
    context: context,
    title: l10n.dialogSyncGuardTitle,
    subtitle:
        '${l10n.dialogSyncGuardSummary(hold.songsRemoved, hold.songsInLibrary)}\n'
        '${l10n.dialogSyncGuardFrom(hold.deviceNames.join(', '))}',
    icon: Icons.warning_amber_rounded,
    barrierDismissible: false,
    body: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final removal in hold.removals)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text.rich(TextSpan(children: [
                TextSpan(
                    text: describe(removal),
                    style: const TextStyle(color: Default_Theme.primaryColor1)),
                TextSpan(
                    text:
                        '  ${l10n.dialogSyncGuardOnDevice(removal.deviceName)}',
                    style: TextStyle(color: secondary, fontSize: 12)),
              ])),
            ),
          const SizedBox(height: 12),
          Text(l10n.dialogSyncGuardDeclineNote,
              style: TextStyle(color: secondary, fontSize: 12)),
        ],
      ),
    ),
    actions: [
      BloomeeDialogAction.text(l10n.buttonSyncKeepLibrary,
          onPressed: () => confirmed = false),
      BloomeeDialogAction.filled(l10n.buttonSyncRemove,
          isDestructive: true, onPressed: () => confirmed = true),
    ],
  );
  return confirmed;
}
