import 'package:equatable/equatable.dart';

/// A Device that takes part in sync through this Sync Location, as this
/// Device knows it.
class KnownDevice extends Equatable {
  /// Its permanent ID, which names its Device State.
  final String deviceId;

  /// Its name, or its permanent ID when its Device State does not tell it.
  final String deviceName;

  /// When it last synced, or null when that is not known: it has not synced
  /// yet, or its Device State cannot be read.
  final DateTime? lastSyncedAt;

  /// Whether it is this Device, which cannot be forgotten from itself.
  final bool isThisDevice;

  const KnownDevice({
    required this.deviceId,
    required this.deviceName,
    required this.lastSyncedAt,
    required this.isThisDevice,
  });

  @override
  List<Object?> get props => [deviceId, deviceName, lastSyncedAt, isThisDevice];
}
