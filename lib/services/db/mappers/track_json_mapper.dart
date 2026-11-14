import 'package:Bloomee/services/db/global_db.dart';

// Track details as plain JSON maps, shared by the backup format and the
// Device State so a song can be recreated on a Device that never saw it.

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
