import 'dart:async';

import 'package:Bloomee/blocs/sync/sync_cubit.dart';
import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/known_device.dart';
import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:Bloomee/core/models/sync/sync_setup.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/l10n/app_localizations.dart';
import 'package:Bloomee/repository/backup/backup_repository.dart';
import 'package:Bloomee/repository/sync/sync_repository.dart';
import 'package:Bloomee/screens/screen/home_views/setting_views/custom_switch.dart';
import 'package:Bloomee/screens/screen/home_views/setting_views/library_sync_setting.dart';
import 'package:Bloomee/screens/widgets/sync_alert_listener.dart';
import 'package:Bloomee/services/db/dao/backup_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';

/// Library Sync as the dialogs see it: [state] as given, and a Dropbox
/// sign-in that begins at once. Nothing reaches a database.
class _StandInSyncCubit extends SyncCubit {
  _StandInSyncCubit(SyncState state) : super(_repository()) {
    emit(state);
  }

  static SyncRepository _repository() {
    final database = Completer<Isar>().future;
    return SyncRepository(
      database: database,
      backups: BackupRepository(
          dao: BackupDAO(database), database: database, supportPath: ''),
      locationKinds: SyncLocationKind.values,
    );
  }

  void show(SyncState state) => emit(state);

  @override
  Future<void> load() async {}

  @override
  Future<Uri?> beginDropboxSignIn() async =>
      Uri.parse('https://www.dropbox.com/oauth2/authorize');
}

/// A phone's width, where the longest translations are the tightest fit.
/// The test font draws each glyph as a square one em wide, wider than the
/// app's fonts draw Latin text: a dialog that fits here fits on a phone at
/// the default text size.
const _phone = Size(360, 740);

void main() {
  const otherDevice = KnownDevice(
      deviceId: 'b',
      deviceName: 'Kitchen laptop',
      lastSyncedAt: null,
      isThisDevice: false);
  final hold = RemovalGuardHold(songsInLibrary: 40, removals: [
    for (var i = 0; i < 3; i++)
      HeldRemoval(
          kind: RemovalKind.playlist,
          playlistName: 'Road trip $i',
          songCount: 12,
          deviceId: 'b',
          deviceName: otherDevice.deviceName,
          key: 'playlist $i'),
  ]);

  Future<void> pumpApp(WidgetTester tester, Locale locale,
      _StandInSyncCubit cubit, Widget home) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = _phone;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(BlocProvider<SyncCubit>.value(
      value: cubit,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        locale: locale,
        theme: AppTheme().defaultThemeData,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            SyncAlertListener(navigatorKey: navigatorKey, child: child!),
        home: home,
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// The dialogs that did not lay out, and why.
  final overflows = <String>[];

  /// Notes whether the dialog open now lays out, then closes it.
  Future<void> expectFits(WidgetTester tester, String dialog) async {
    expect(find.byType(Dialog), findsOneWidget, reason: dialog);
    if (tester.takeException() case final error?) {
      overflows.add('$dialog: $error');
    }
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    // The list builds only what is near the screen.
    await tester.scrollUntilVisible(find.text(text), 100,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text(text));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  tearDown(overflows.clear);

  for (final locale in AppLocalizations.supportedLocales) {
    final tag = locale.toLanguageTag();

    testWidgets('$tag: the sync settings dialogs fit a phone', (tester) async {
      final l10n = await AppLocalizations.delegate.load(locale);
      final cubit = _StandInSyncCubit(const SyncState(
          locationKinds: SyncLocationKind.values, loaded: true));
      addTearDown(cubit.close);
      await pumpApp(tester, locale, cubit, const LibrarySyncSettings());

      await tester.tap(find.byType(BloomeeSwitch));
      await tester.pumpAndSettle();
      await expectFits(tester, 'choosing a Sync Location');

      await tapText(tester, l10n.syncDropbox);
      await expectFits(tester, 'Dropbox app, needed');

      cubit.show(cubit.state
          .copyWith(setup: const SyncSetup(dropboxAppKey: 'own key')));
      await tester.pumpAndSettle();
      await tapText(tester, l10n.syncDropbox);
      await expectFits(tester, 'Dropbox sign-in');

      await tapText(tester, l10n.syncDropboxOwnApp);
      await expectFits(tester, 'Dropbox app');

      await tapText(tester, l10n.syncWebDav);
      await expectFits(tester, 'WebDAV sign-in');

      cubit.show(cubit.state.copyWith(
          setup: const SyncSetup(
              enabled: true,
              locationKind: SyncLocationKind.localFolder,
              folder: '/music'),
          devices: const [
            KnownDevice(
                deviceId: 'a',
                deviceName: 'Phone',
                lastSyncedAt: null,
                isThisDevice: true),
            otherDevice,
          ]));
      await tester.pumpAndSettle();
      await tapText(tester, l10n.syncForgetDevice);
      await expectFits(tester, 'forgetting a Device');
      expect(overflows, isEmpty);
    });

    testWidgets('$tag: the sync alerts and the Removal Guard fit a phone',
        (tester) async {
      final cubit = _StandInSyncCubit(const SyncState(loaded: true));
      addTearDown(cubit.close);
      await pumpApp(tester, locale, cubit, const Scaffold());

      final alerts = <SyncAlert>[
        ClockRefusedAlert(otherDevice.deviceName, DateTime(2026, 11, 15, 10)),
        const UnreadableDeviceStateAlert('b'),
        UpdateNeededAlert(otherDevice.deviceName),
        const SignInNeededAlert(SyncLocationKind.dropbox),
        const SignInNeededAlert(SyncLocationKind.webDav),
        const KeyringUnavailableAlert(),
      ];
      for (final alert in alerts) {
        cubit.show(cubit.state.copyWith(alerts: [alert]));
        await tester.pumpAndSettle();
        await expectFits(tester, '$alert');
      }

      unawaited(
          showRemovalGuardDialog(tester.element(find.byType(Scaffold)), hold));
      await tester.pumpAndSettle();
      await expectFits(tester, 'the Removal Guard');
      expect(overflows, isEmpty);
    });
  }
}
