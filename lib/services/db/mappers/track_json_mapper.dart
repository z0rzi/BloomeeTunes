import 'package:Bloomee/services/db/global_db.dart';

// Track and playlist details as plain JSON maps, shared by the backup format
// and the Device State so a song or a saved collection can be recreated on a
// Device that never saw it.

Map<String, dynamic>? artworkDBToJson(ArtworkDB? a) => a == null
    ? null
    : {
        'url': a.url,
        'urlLow': a.urlLow,
        'urlHigh': a.urlHigh,
        'layout': a.layout.name,
      };
Map<String, dynamic> artistSummaryDBToJson(ArtistSummaryDB a) => {
      'mediaId': a.mediaId,
      'name': a.name,
      'url': a.url,
      'subtitle': a.subtitle,
      'thumbnail': artworkDBToJson(a.thumbnail),
    };
Map<String, dynamic>? albumSummaryDBToJson(AlbumSummaryDB? a) => a == null
    ? null
    : {
        'mediaId': a.mediaId,
        'title': a.name,
        'year': a.year,
        'url': a.url,
        'artists': a.artists?.map(artistSummaryDBToJson).toList(),
        'thumbnail': artworkDBToJson(a.thumbnail),
      };
Map<String, dynamic> trackDBToJson(TrackDB t) => {
      'mediaId': t.mediaId,
      'title': t.title,
      'artists': t.artists?.map(artistSummaryDBToJson).toList(),
      'album': albumSummaryDBToJson(t.album),
      'thumbnail': artworkDBToJson(t.thumbnail),
      'durationMs': t.durationMs,
      'genre': t.genre,
      'language': t.language,
      'isExplicit': t.isExplicit,
    };
ArtworkDB? artworkDBFromJson(dynamic value) {
  if (value == null) return null;
  final m = value as Map<String, dynamic>;
  return ArtworkDB()
    ..url = m['url'] as String? ?? ''
    ..urlLow = m['urlLow'] as String?
    ..urlHigh = m['urlHigh'] as String?
    ..layout = ImageLayoutDB.values.byName(m['layout'] as String? ?? 'square');
}

List<ArtistSummaryDB>? artistSummariesDBFromJson(dynamic value) => value == null
    ? null
    : (value as List).map((v) {
        final a = v as Map<String, dynamic>;
        return ArtistSummaryDB()
          ..name = a['name'] as String?
          ..mediaId = a['mediaId'] as String?
          ..url = a['url'] as String?
          ..subtitle = a['subtitle'] as String?
          ..thumbnail = artworkDBFromJson(a['thumbnail']);
      }).toList();
AlbumSummaryDB? albumSummaryDBFromJson(dynamic value) {
  if (value == null) return null;
  final a = value as Map<String, dynamic>;
  if (a['year'] != null && a['year'] is! String && a['year'] is! int) {
    throw const FormatException('Invalid album year.');
  }
  return AlbumSummaryDB()
    ..name = a['title'] as String? ?? ''
    ..mediaId = a['mediaId'] as String?
    ..url = a['url'] as String?
    ..year = a['year']?.toString()
    ..artists = artistSummariesDBFromJson(a['artists'])
    ..thumbnail = artworkDBFromJson(a['thumbnail']);
}

TrackDB trackDBFromJson(Map<String, dynamic> t) => TrackDB(
      mediaId: t['mediaId'] as String,
      title: t['title'] as String,
      artists: artistSummariesDBFromJson(t['artists']),
      album: albumSummaryDBFromJson(t['album']),
      thumbnail: artworkDBFromJson(t['thumbnail']),
      durationMs: t['durationMs'] as int?,
      genre: t['genre'] as String?,
      language: t['language'] as String?,
      isExplicit: t['isExplicit'] as bool? ?? false,
    );

Map<String, dynamic> playlistDBToJson(PlaylistDB p) => {
      'name': p.name,
      'type': p.type.name,
      'subtitle': p.subtitle,
      'description': p.description,
      'thumbnail': artworkDBToJson(p.thumbnail),
      'artists': p.artists?.map(artistSummaryDBToJson).toList(),
      'album': albumSummaryDBToJson(p.album),
      'isPinned': p.isPinned,
      'sortOrder': p.sortOrder,
      'createdAt': p.createdAt.toUtc().toIso8601String(),
      'updatedAt': p.updatedAt.toUtc().toIso8601String(),
      'remotePlaylist': p.remotePlaylist == null
          ? null
          : {
              'title': p.remotePlaylist!.name,
              'mediaId': p.remotePlaylist!.mediaId,
              'url': p.remotePlaylist!.url,
              'subtitle': p.remotePlaylist!.subtitle,
              'artists': p.remotePlaylist!.artists
                  ?.map(artistSummaryDBToJson)
                  .toList(),
              'album': albumSummaryDBToJson(p.remotePlaylist!.album),
              'thumbnail': artworkDBToJson(p.remotePlaylist!.thumbnail),
            },
    };

PlaylistDB playlistDBFromJson(Map<String, dynamic> p) {
  final row = PlaylistDB(
      name: p['name'] as String,
      type: PlaylistTypeDB.values.byName(p['type'] as String),
      description: p['description'] as String?,
      subtitle: p['subtitle'] as String?,
      thumbnail: artworkDBFromJson(p['thumbnail']),
      artists: artistSummariesDBFromJson(p['artists']),
      album: albumSummaryDBFromJson(p['album']),
      sortOrder: p['sortOrder'] as int? ?? 0,
      isPinned: p['isPinned'] as bool? ?? false,
      createdat: p['createdAt'] == null
          ? null
          : DateTime.parse(p['createdAt'] as String),
      updatedat: p['updatedAt'] == null
          ? null
          : DateTime.parse(p['updatedAt'] as String));
  if (p['remotePlaylist'] != null) {
    final r = p['remotePlaylist'] as Map<String, dynamic>;
    row.remotePlaylist = RemotePlaylistSummaryDB(
        title: r['title'] as String?,
        mediaId: r['mediaId'] as String?,
        url: r['url'] as String?,
        subtitle: r['subtitle'] as String?,
        artists: artistSummariesDBFromJson(r['artists']),
        album: albumSummaryDBFromJson(r['album']),
        thumbnail: artworkDBFromJson(r['thumbnail']));
  }
  return row;
}
