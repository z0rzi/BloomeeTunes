/// When a change to the Synced Library was made, and by which Device: the
/// order Latest Change Wins goes by. Two changes made at the same time are
/// ordered by Device ID, so every Device settles them the same way.
class ChangeStamp implements Comparable<ChangeStamp> {
  final DateTime at;

  /// The permanent ID of the Device that made the change.
  final String device;

  ChangeStamp(DateTime at, this.device) : at = at.toUtc();

  @override
  int compareTo(ChangeStamp other) {
    final byTime = at.compareTo(other.at);
    return byTime != 0 ? byTime : device.compareTo(other.device);
  }

  bool isAfter(ChangeStamp other) => compareTo(other) > 0;

  /// The later of [a] and [b]; [b] when [a] is null.
  static ChangeStamp latest(ChangeStamp? a, ChangeStamp b) =>
      a == null || b.isAfter(a) ? b : a;

  @override
  bool operator ==(Object other) =>
      other is ChangeStamp && other.at == at && other.device == device;

  @override
  int get hashCode => Object.hash(at, device);

  /// As `<verb>At` and `<verb>By` fields.
  Map<String, dynamic> toJson(String verb) =>
      {'${verb}At': at.toIso8601String(), '${verb}By': device};

  factory ChangeStamp.fromJson(Map<String, dynamic> json, String verb) =>
      ChangeStamp(_time(json, '${verb}At'), _string(json, '${verb}By'));
}

/// A song in a synced playlist or among the liked songs.
class SyncedSong {
  /// The existing source-scoped media ID; a song appears once per playlist.
  final String mediaId;

  /// Its latest addition.
  final ChangeStamp added;

  const SyncedSong({required this.mediaId, required this.added});

  Map<String, dynamic> toJson() =>
      {'mediaId': mediaId, ...added.toJson('added')};

  factory SyncedSong.fromJson(Map<String, dynamic> json) => SyncedSong(
      mediaId: _string(json, 'mediaId'),
      added: ChangeStamp.fromJson(json, 'added'));
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

/// The kinds of saved remote collection the Synced Library covers.
enum SavedKind { album, artist }

/// A saved album or artist.
class SavedCollection {
  final SavedKind kind;

  /// The collection's source-scoped media ID.
  final String mediaId;

  /// Its latest saving.
  final ChangeStamp saved;

  /// What is needed to recreate it on a Device that never saved it, in the
  /// backup format's playlist shape.
  final Map<String, dynamic> details;

  const SavedCollection({
    required this.kind,
    required this.mediaId,
    required this.saved,
    required this.details,
  });

  /// Identifies the collection among all saved ones.
  String get key => savedKey(kind, mediaId);

  static String savedKey(SavedKind kind, String mediaId) =>
      '${kind.name}:$mediaId';

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'mediaId': mediaId,
        ...saved.toJson('saved'),
        'details': details,
      };

  factory SavedCollection.fromJson(Map<String, dynamic> json) {
    final details = json['details'];
    if (details is! Map<String, dynamic>) {
      throw const FormatException('Device State field "details" is missing.');
    }
    return SavedCollection(
        kind: _enum(SavedKind.values, json),
        mediaId: _string(json, 'mediaId'),
        saved: ChangeStamp.fromJson(json, 'saved'),
        details: details);
  }
}

/// What a Removal Marker records the removal of.
enum RemovalKind {
  /// A deleted playlist.
  playlist,

  /// A song taken out of a playlist.
  song,

  /// An unliked song.
  like,

  /// An unsaved album.
  album,

  /// An unsaved artist.
  artist;

  static RemovalKind ofSaved(SavedKind kind) => switch (kind) {
        SavedKind.album => album,
        SavedKind.artist => artist,
      };
}

/// The record that something was taken out of the Synced Library, kept so the
/// removal reaches the other Devices. It holds the latest removal.
class RemovalMarker {
  final RemovalKind kind;

  /// The sync ID of the deleted playlist, or of the playlist a song was taken
  /// out of; null otherwise.
  final String? playlistId;

  /// The media ID of the removed song or collection; null for a playlist.
  final String? mediaId;

  final ChangeStamp removed;

  const RemovalMarker({
    required this.kind,
    this.playlistId,
    this.mediaId,
    required this.removed,
  });

  /// Identifies what was removed; one marker per key.
  String get key => removalKey(kind, playlistId, mediaId);

  static String removalKey(
          RemovalKind kind, String? playlistId, String? mediaId) =>
      [kind.name, playlistId ?? '', mediaId ?? ''].join('|');

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (playlistId != null) 'playlistId': playlistId,
        if (mediaId != null) 'mediaId': mediaId,
        ...removed.toJson('removed'),
      };

  factory RemovalMarker.fromJson(Map<String, dynamic> json) {
    final kind = _enum(RemovalKind.values, json);
    final inPlaylist = kind == RemovalKind.playlist || kind == RemovalKind.song;
    return RemovalMarker(
        kind: kind,
        playlistId: inPlaylist ? _string(json, 'playlistId') : null,
        mediaId: kind == RemovalKind.playlist ? null : _string(json, 'mediaId'),
        removed: ChangeStamp.fromJson(json, 'removed'));
  }
}

/// The part of a library that sync covers, as one Device sees it.
class SyncedLibrary {
  final List<SyncedPlaylist> playlists;

  /// The liked songs, in the order they were liked.
  final List<SyncedSong> liked;

  /// The saved albums and artists.
  final List<SavedCollection> saved;

  /// Every Removal Marker this Device knows of, its own and those it took in.
  final List<RemovalMarker> removals;

  /// Details needed to recreate each song on a Device that never saw it,
  /// keyed by media ID, in the backup format's track shape.
  final Map<String, Map<String, dynamic>> tracks;

  const SyncedLibrary({
    required this.playlists,
    this.liked = const [],
    this.saved = const [],
    this.removals = const [],
    required this.tracks,
  });
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
    List<T> sorted<T>(Iterable<T> items, String Function(T) key) =>
        [...items]..sort((a, b) => key(a).compareTo(key(b)));
    final mediaIds = library.tracks.keys.toList()..sort();
    return {
      'format': format,
      'formatVersion': formatVersion,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'playlists': [
        for (final p in sorted(library.playlists, (p) => p.id)) p.toJson()
      ],
      'liked': [
        for (final s in sorted(library.liked, (s) => s.mediaId)) s.toJson()
      ],
      'saved': [
        for (final c in sorted(library.saved, (c) => c.key)) c.toJson()
      ],
      'removals': [
        for (final r in sorted(library.removals, (r) => r.key)) r.toJson()
      ],
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
    List<T> items<T>(String key, T Function(Map<String, dynamic>) read) => [
          for (final item in _list(json, key))
            read(item as Map<String, dynamic>)
        ];
    return DeviceState(
      deviceId: _string(json, 'deviceId'),
      deviceName: _string(json, 'deviceName'),
      writtenAt: _time(json, 'writtenAt'),
      library: SyncedLibrary(
        playlists: items('playlists', SyncedPlaylist.fromJson),
        liked: items('liked', SyncedSong.fromJson),
        saved: items('saved', SavedCollection.fromJson),
        removals: items('removals', RemovalMarker.fromJson),
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

T _enum<T extends Enum>(List<T> values, Map<String, dynamic> json) {
  final name = _string(json, 'kind');
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Device State kind "$name" is unknown.');
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
