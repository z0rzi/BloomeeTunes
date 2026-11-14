/// A song's place in a synced playlist.
class SyncedSong {
  /// The existing source-scoped media ID; a song appears once per playlist.
  final String mediaId;
  final DateTime addedAt;

  const SyncedSong({required this.mediaId, required this.addedAt});

  Map<String, dynamic> toJson() => {
        'mediaId': mediaId,
        'addedAt': addedAt.toUtc().toIso8601String(),
      };

  factory SyncedSong.fromJson(Map<String, dynamic> json) => SyncedSong(
      mediaId: _string(json, 'mediaId'), addedAt: _time(json, 'addedAt'));
}

/// One playlist of the Synced Library, identified by its permanent sync ID.
class SyncedPlaylist {
  final String id;
  final String name;
  final String? description;
  final DateTime createdAt;

  /// In the playlist's order.
  final List<SyncedSong> songs;

  const SyncedPlaylist({
    required this.id,
    required this.name,
    this.description,
    required this.createdAt,
    required this.songs,
  });

  SyncedPlaylist withSongs(List<SyncedSong> songs) => SyncedPlaylist(
      id: id,
      name: name,
      description: description,
      createdAt: createdAt,
      songs: songs);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'songs': [for (final s in songs) s.toJson()],
      };

  factory SyncedPlaylist.fromJson(Map<String, dynamic> json) => SyncedPlaylist(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        description: json['description'] as String?,
        createdAt: _time(json, 'createdAt'),
        songs: [
          for (final s in _list(json, 'songs'))
            SyncedSong.fromJson(s as Map<String, dynamic>)
        ],
      );
}

/// The part of a library that sync covers, as one Device sees it.
class SyncedLibrary {
  final List<SyncedPlaylist> playlists;

  /// Details needed to recreate each song on a Device that never saw it,
  /// keyed by media ID, in the backup format's track shape.
  final Map<String, Map<String, dynamic>> tracks;

  const SyncedLibrary({required this.playlists, required this.tracks});
}

/// The file a Device publishes in the Sync Location; only it writes it.
class DeviceState {
  static const format = 'bloomee-device-state';

  /// The newest format this build reads and the one it writes.
  static const formatVersion = 1;

  final String deviceId;
  final String deviceName;
  final DateTime writtenAt;
  final SyncedLibrary library;

  const DeviceState({
    required this.deviceId,
    required this.deviceName,
    required this.writtenAt,
    required this.library,
  });

  /// Everything but [writtenAt], so two states can be compared for change.
  Map<String, dynamic> contentJson() {
    final playlists = [...library.playlists]
      ..sort((a, b) => a.id.compareTo(b.id));
    final mediaIds = library.tracks.keys.toList()..sort();
    return {
      'format': format,
      'formatVersion': formatVersion,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'playlists': [for (final p in playlists) p.toJson()],
      'tracks': [for (final id in mediaIds) library.tracks[id]],
    };
  }

  Map<String, dynamic> toJson() =>
      contentJson()..['writtenAt'] = writtenAt.toUtc().toIso8601String();

  factory DeviceState.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format || json['formatVersion'] is! int) {
      throw const FormatException('Not a Bloomee Device State.');
    }
    final tracks = <String, Map<String, dynamic>>{};
    for (final t in _list(json, 'tracks')) {
      final track = t as Map<String, dynamic>;
      tracks[_string(track, 'mediaId')] = track;
    }
    return DeviceState(
      deviceId: _string(json, 'deviceId'),
      deviceName: _string(json, 'deviceName'),
      writtenAt: _time(json, 'writtenAt'),
      library: SyncedLibrary(
        playlists: [
          for (final p in _list(json, 'playlists'))
            SyncedPlaylist.fromJson(p as Map<String, dynamic>)
        ],
        tracks: tracks,
      ),
    );
  }
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Device State field "$key" is missing.');
  }
  return value;
}

DateTime _time(Map<String, dynamic> json, String key) =>
    DateTime.parse(_string(json, key)).toUtc();

List<dynamic> _list(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('Device State field "$key" is missing.');
  }
  return value;
}

/// This Device's identity in Library Sync.
class SyncIdentity {
  /// Permanent; names this Device's Device State.
  final String deviceId;

  /// A label only; renaming changes nothing about what syncs.
  final String deviceName;
  final DateTime? lastSyncAt;

  const SyncIdentity({
    required this.deviceId,
    required this.deviceName,
    this.lastSyncAt,
  });
}
