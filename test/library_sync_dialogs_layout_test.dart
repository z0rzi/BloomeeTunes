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
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';

/// Library Sync as the dialogs see it: [state] as given, and a Dropbox
/// sign-in that begins and finishes at once, noting the keys it began with
/// and the codes it finished with. Nothing reaches a database.
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

  /// The keys each Dropbox sign-in began with, and the codes finishing one.
  final List<String> begunWith = [];
  final List<String> finishedWith = [];

  @override
  Future<Uri?> beginDropboxSignIn(String key) async {
    begunWith.add(key.trim());
    return Uri.parse('https://www.dropbox.com/oauth2/authorize')
        .replace(queryParameters: {'client_id': key.trim()});
  }

  @override
  Future<SyncLocationProblem?> finishDropboxSignIn(String code) async {
    finishedWith.add(code);
    return null;
  }

  /// The Sync Locations chosen once signed in.
  final List<SyncLocationChoice> chosen = [];

  @override
  Future<void> choose(SyncLocationChoice choice, {String? deviceName}) async =>
      chosen.add(choice);
}

/// A phone's width, where the longest translations are the tightest fit.
/// The test font draws each glyph as a square one em wide, wider than the
/// app's fonts draw Latin text: a dialog that fits here fits on a phone at
/// the default text size.
const _phone = Size(360, 740);

/// Opening a web page fails at once, as on a Device with no browser, rather
/// than waiting on a platform that tests do not have.
void noBrowser() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  // The Linux implementation answers an error text.
  const linuxLaunch =
      'dev.flutter.pigeon.url_launcher_linux.UrlLauncherApi.launchUrl';
  messenger
    ..setMockMethodCallHandler(channel, (call) async => false)
    ..setMockMessageHandler(
        linuxLaunch,
        (_) async => const StandardMessageCodec()
            .encodeMessage(<Object?>['No browser in tests.']));
  addTearDown(() => messenger
    ..setMockMethodCallHandler(channel, null)
    ..setMockMessageHandler(linuxLaunch, null));
}

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
    noBrowser();
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

      // No key signed in with yet: the steps to register an app are shown.
      await tapText(tester, l10n.syncDropbox);
      expect(find.text(l10n.dialogDropboxAppBody), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, l10n.dialogDropboxAppKey), 'own key');
      await tester.pump();
      await tapText(tester, l10n.buttonDropboxOpenPage);
      // The test opens no browser: the page's address is shown instead.
      expect(find.text(l10n.dialogDropboxPageNotOpened), findsOneWidget);
      await expectFits(tester, 'Dropbox sign-in, steps shown');

      cubit.show(cubit.state
          .copyWith(setup: const SyncSetup(dropboxAppKey: 'own key')));
      await tester.pumpAndSettle();
      await tapText(tester, l10n.syncDropbox);
      expect(find.text(l10n.dialogDropboxAppBody), findsNothing);
      await expectFits(tester, 'Dropbox sign-in');

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

    if (locale.languageCode == 'en') {
      testWidgets(
          'the Dropbox sign-in dialog takes the key and the code together, and a key changed after the page was opened needs it opened again',
          (tester) async {
        final l10n = await AppLocalizations.delegate.load(locale);
        final cubit = _StandInSyncCubit(const SyncState(
            locationKinds: SyncLocationKind.values, loaded: true));
        addTearDown(cubit.close);
        await pumpApp(tester, locale, cubit, const LibrarySyncSettings());
        final keyField =
            find.widgetWithText(TextField, l10n.dialogDropboxAppKey);
        final codeField =
            find.widgetWithText(TextField, l10n.dialogDropboxCode);
        bool enabled(String label) => tester
            .widget<ButtonStyleButton>(find.ancestor(
                of: find.text(label),
                matching: find.bySubtype<ButtonStyleButton>()))
            .enabled;

        expect(find.text(l10n.syncDropboxSignedOut), findsOneWidget);
        await tapText(tester, l10n.syncDropbox);
        expect(find.text(l10n.dialogDropboxAppRequiredNote), findsOneWidget);
        expect(find.text(l10n.dialogDropboxAppBody), findsOneWidget,
            reason: 'no key was ever entered on this Device');
        expect(enabled(l10n.buttonDropboxOpenPage), isFalse,
            reason: 'no key typed yet');

        await tester.enterText(keyField, ' own key ');
        await tester.pump();
        expect(enabled(l10n.buttonDropboxOpenPage), isTrue);
        await tester.enterText(codeField, 'the code');
        await tester.pump();
        expect(enabled(l10n.buttonDropboxSignIn), isFalse,
            reason: 'no sign-in begun');

        await tapText(tester, l10n.buttonDropboxOpenPage);
        expect(cubit.begunWith, ['own key']);
        expect(enabled(l10n.buttonDropboxSignIn), isTrue);
        expect(find.text(l10n.dialogDropboxPageNotOpened), findsOneWidget);

        await tester.enterText(keyField, 'other key');
        await tester.pump();
        expect(enabled(l10n.buttonDropboxSignIn), isFalse,
            reason: 'the sign-in begun went through the other key');
        expect(find.text(l10n.dialogDropboxKeyChanged), findsOneWidget);
        expect(find.text(l10n.dialogDropboxPageNotOpened), findsNothing,
            reason: 'that page is of the key before');

        await tapText(tester, l10n.buttonDropboxOpenPage);
        expect(cubit.begunWith, ['own key', 'other key']);
        expect(find.text(l10n.dialogDropboxKeyChanged), findsNothing);
        await tapText(tester, l10n.buttonDropboxSignIn);
        expect(cubit.finishedWith, ['the code']);
        expect(find.byType(Dialog), findsNothing, reason: 'signed in');
        expect(cubit.chosen, [const SyncLocationChoice.dropbox()]);

        // Signed out since, the key kept: it is offered, the steps folded.
        cubit.show(cubit.state
            .copyWith(setup: const SyncSetup(dropboxAppKey: 'other key')));
        await tester.pumpAndSettle();
        await tapText(tester, l10n.syncDropbox);
        expect(
            tester.widget<TextField>(keyField).controller!.text, 'other key');
        expect(find.text(l10n.dialogDropboxAppBody), findsNothing);
        expect(enabled(l10n.buttonDropboxOpenPage), isTrue);
        await tapText(tester, l10n.buttonDropboxAppKeyHelp);
        expect(find.text(l10n.dialogDropboxAppBody), findsOneWidget);
        expect(overflows, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

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
