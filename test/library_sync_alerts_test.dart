import 'dart:convert';
import 'dart:io';

import 'package:Bloomee/blocs/sync/sync_cubit.dart';
import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:Bloomee/core/models/sync/sync_setup.dart';
import 'package:Bloomee/repository/sync/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/isar_test_support.dart';
import 'support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncWorld world;
  final cubits = <SyncCubit>[];
  final repositories = <SyncRepository>[];

  setUpAll(initializeTestIsar);
  setUp(() async => world = await SyncWorld.create());
  tearDown(() async {
    for (final cubit in cubits) {
      await cubit.close();
    }
    for (final repository in repositories) {
      await repository.close();
    }
    cubits.clear();
    repositories.clear();
    await world.dispose();
  });

  /// The app on [device], with sync enabled through its settings.
  Future<SyncCubit> appWithSyncOn(SyncDevice device) async {
    final repository = SyncRepository(
        database: Future.value(device.isar),
        backups: device.backups,
        clock: device.clock,
        machineName: () => device.name);
    repositories.add(repository);
    final cubit = SyncCubit(repository);
    cubits.add(cubit);
    await cubit.load();
    await cubit.enable(world.locationPath);
    await cubit.syncNow();
    await pumpEventQueue();
    return cubit;
  }

  Future<void> syncNow(SyncCubit cubit) async {
    await cubit.syncNow();
    await pumpEventQueue();
  }

  List<String> ids(int from, int to) =>
      [for (var i = from; i <= to; i++) 'yt::$i'];

  test('Library Sync starts off, with the machine name as the Device name',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final repository = SyncRepository(
        database: Future.value(laptop.isar),
        backups: laptop.backups,
        machineName: () => 'workstation',
        locationKinds: SyncLocationKind.offeredOn('linux'));
    repositories.add(repository);
    final cubit = SyncCubit(repository);
    cubits.add(cubit);

    await cubit.load();

    expect(cubit.state.enabled, isFalse);
    expect(cubit.state.deviceName, 'workstation');
    expect(cubit.state.locationKinds, [SyncLocationKind.localFolder]);
  });

  test('the local folder is offered on Linux and not on Android', () {
    expect(SyncLocationKind.offeredOn('linux'), [SyncLocationKind.localFolder]);
    expect(SyncLocationKind.offeredOn('android'), isEmpty);
  });

  test('choosing a folder that cannot be used says why and stays off',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final repository = SyncRepository(
        database: Future.value(laptop.isar),
        backups: laptop.backups,
        machineName: () => 'laptop');
    repositories.add(repository);
    final cubit = SyncCubit(repository);
    cubits.add(cubit);
    await cubit.load();

    await cubit.enable(p.join(world.root.path, 'missing'));

    expect(cubit.state.setupProblem, SyncLocationProblem.notFound);
    expect(cubit.state.enabled, isFalse);
    expect(cubit.state.settingUp, isFalse);
  });

  test(
      'a held Removal Guard asks, showing what would be removed and from which Device; confirming applies it',
      () async {
    final phone = await world.device('phone');
    final laptop = await world.device('laptop', enabled: false);
    await phone.add(
        'Road trip', [for (final id in ids(1, 8)) song(id, title: 'Song $id')]);
    await phone.sync();
    final app = await appWithSyncOn(laptop);
    expect(app.state.askAboutHold, isNull);

    world.clock.advance(const Duration(minutes: 5));
    for (final id in ids(1, 3)) {
      await phone.remove('Road trip', id);
    }
    await phone.sync();
    await syncNow(app);

    final hold = app.state.askAboutHold!;
    expect(hold.deviceNames, {'phone'});
    expect(
        [for (final r in hold.removals) (r.playlistName, r.title)],
        unorderedEquals(
            [for (final id in ids(1, 3)) ('Road trip', 'Song $id')]));
    expect(await laptop.songsOf('Road trip'), ids(1, 8));

    await syncNow(app);
    expect(app.state.askAboutHold, same(hold),
        reason: 'a scheduled sync meanwhile does not ask again');

    await app.answerRemovalGuard(hold, confirm: true);
    await pumpEventQueue();
    expect(app.state.askAboutHold, isNull);
    expect(await laptop.songsOf('Road trip'), ids(4, 8));
  });

  test('a Removal Guard question closed without an answer is asked again',
      () async {
    final phone = await world.device('phone');
    final laptop = await world.device('laptop', enabled: false);
    await phone.add('Road trip', [for (final id in ids(1, 8)) song(id)]);
    await phone.sync();
    final app = await appWithSyncOn(laptop);
    world.clock.advance(const Duration(minutes: 5));
    for (final id in ids(1, 3)) {
      await phone.remove('Road trip', id);
    }
    await phone.sync();
    await syncNow(app);

    app.removalGuardDismissed(app.state.askAboutHold!);
    expect(app.state.askAboutHold, isNull);
    await syncNow(app);

    expect(app.state.askAboutHold, isNotNull);
    expect(await laptop.songsOf('Road trip'), ids(1, 8));
  });

  test(
      'declining the Removal Guard keeps the library, pauses sync without asking again, and can be confirmed later',
      () async {
    final phone = await world.device('phone');
    final laptop = await world.device('laptop', enabled: false);
    await phone.add('Road trip', [for (final id in ids(1, 8)) song(id)]);
    await phone.sync();
    final app = await appWithSyncOn(laptop);
    world.clock.advance(const Duration(minutes: 5));
    for (final id in ids(1, 3)) {
      await phone.remove('Road trip', id);
    }
    await phone.sync();
    await syncNow(app);

    await app.answerRemovalGuard(app.state.askAboutHold!, confirm: false);
    await pumpEventQueue();
    await syncNow(app);

    expect(app.state.askAboutHold, isNull);
    expect(app.state.declinedHold, isNotNull);
    expect(app.state.status.lastError, isA<SyncNeedsOwner>());
    expect(await laptop.songsOf('Road trip'), ids(1, 8));

    await app.answerRemovalGuard(app.state.declinedHold!, confirm: true);
    await pumpEventQueue();
    expect(app.state.declinedHold, isNull);
    expect(await laptop.songsOf('Road trip'), ids(4, 8));
  });

  test('a refused clock raises one alert naming the Device', () async {
    final phone = await world.device('phone');
    final laptop = await world.device('laptop', enabled: false);
    final app = await appWithSyncOn(laptop);
    phone.clockAhead = const Duration(days: 2);
    await phone.add('Road trip', [song('yt::1')]);
    await phone.sync();

    await syncNow(app);
    expect(app.state.alerts, [isA<ClockRefusedAlert>()]);
    final alert = app.state.alerts.single as ClockRefusedAlert;
    expect(alert.deviceName, 'phone');
    app.alertShown(alert);

    await syncNow(app);
    expect(app.state.alerts, isEmpty,
        reason: 'the same problem, already shown');
    world.clock.advance(const Duration(minutes: 1));
    await phone.add('Road trip', [song('yt::2')]);
    await phone.sync();
    await syncNow(app);
    expect(app.state.alerts, isEmpty,
        reason: 'a later change from the same wrong clock');
    expect(await laptop.songsOf('Road trip'), isNull);
  });

  test('declining the Removal Guard does not raise a shown alert again',
      () async {
    final phone = await world.device('phone');
    final desktop = await world.device('desktop');
    final laptop = await world.device('laptop', enabled: false);
    await phone.add('Road trip', [for (final id in ids(1, 8)) song(id)]);
    await phone.sync();
    final app = await appWithSyncOn(laptop);
    desktop.clockAhead = const Duration(days: 2);
    await desktop.add('Focus', [song('yt::20')]);
    await desktop.sync();
    await syncNow(app);
    app.alertShown(app.state.alerts.single);

    world.clock.advance(const Duration(minutes: 5));
    for (final id in ids(1, 3)) {
      await phone.remove('Road trip', id);
    }
    await phone.sync();
    await syncNow(app);
    await app.answerRemovalGuard(app.state.askAboutHold!, confirm: false);
    await pumpEventQueue();
    await syncNow(app);

    expect(app.state.alerts, isEmpty);
  });

  test('an unreadable Device State raises an alert naming the Device',
      () async {
    final phone = await world.device('phone');
    final laptop = await world.device('laptop', enabled: false);
    await phone.add('Road trip', [song('yt::1')]);
    await phone.sync();
    final app = await appWithSyncOn(laptop);
    final state = await world.stateOf(phone).readAsBytes();
    await world
        .stateOf(phone)
        .writeAsBytes(state.sublist(0, state.length ~/ 2));

    await syncNow(app);

    expect(app.state.alerts, [
      isA<UnreadableDeviceStateAlert>()
          .having((a) => a.device, 'device', phone.id)
    ]);
  });

  test('a Device State in a newer format raises an alert asking for an update',
      () async {
    final phone = await world.device('phone');
    final laptop = await world.device('laptop', enabled: false);
    await phone.sync();
    final app = await appWithSyncOn(laptop);
    final state = jsonDecode(await world.stateOf(phone).readAsString())
        as Map<String, dynamic>;
    state['formatVersion'] = DeviceState.formatVersion + 1;
    await world.stateOf(phone).writeAsString(jsonEncode(state));

    await syncNow(app);

    expect(app.state.alerts, [const UpdateNeededAlert('phone')]);
    expect(
        app.state.status.lastError,
        isA<SyncNeedsOwner>()
            .having((e) => e.outcome, 'outcome', isA<SyncUpdateNeeded>()));
  });

  test(
      'a temporary failure raises no alert; the status line shows it, then the next success',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final app = await appWithSyncOn(laptop);
    final firstSync = app.state.status.lastSyncedAt;
    expect(firstSync, isNotNull);

    final moved = p.join(world.root.path, 'moved');
    await Directory(world.locationPath).rename(moved);
    world.clock.advance(const Duration(minutes: 3));
    await syncNow(app);
    expect(app.state.alerts, isEmpty);
    expect(app.state.status.lastError, isA<SyncLocationUnreachable>());
    expect(app.state.status.lastSyncedAt, firstSync);

    await Directory(moved).rename(world.locationPath);
    world.clock.advance(const Duration(minutes: 3));
    await syncNow(app);
    expect(app.state.alerts, isEmpty);
    expect(app.state.status.lastSyncedAt, laptop.clock());
  });
}
