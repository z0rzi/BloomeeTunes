// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get onboardingTitle => 'Welcome to Bloomee';

  @override
  String get onboardingSubtitle => 'Let\'s set up your language and region.';

  @override
  String get continueButton => 'Continue';

  @override
  String get navHome => 'Home';

  @override
  String get navLibrary => 'Library';

  @override
  String get navSearch => 'Search';

  @override
  String get navLocal => 'Local';

  @override
  String get navOffline => 'Offline';

  @override
  String get playerEnjoyingFrom => 'Enjoying From';

  @override
  String get playerPlayWithMix => 'Auto-Mix Play';

  @override
  String get playerPlayNext => 'Play Next';

  @override
  String get playerAddToQueue => 'Add to Queue';

  @override
  String get playerAddToFavorites => 'Add to Favorites';

  @override
  String get playerNoLyricsFound => 'No Lyrics Found';

  @override
  String get playerLyricsNoPlugin =>
      'No lyrics provider configured. Go to Settings → Plugins to install one.';

  @override
  String get localMusicTitle => 'Local';

  @override
  String get localMusicGrantPermission => 'Grant Permission';

  @override
  String get localMusicStorageAccessRequired => 'Storage Access Required';

  @override
  String get localMusicStorageAccessDesc =>
      'Please grant permission to scan and play audio files stored on your device.';

  @override
  String get localMusicAddFolder => 'Add Music Folder';

  @override
  String get localMusicScanNow => 'Scan Now';

  @override
  String localMusicScanFailed(String message) {
    return 'Scan failed: $message';
  }

  @override
  String get localMusicScanning => 'Scanning device for audio files...';

  @override
  String get localMusicShuffle => 'Shuffle';

  @override
  String get localMusicPlayAll => 'Play All';

  @override
  String get localMusicSearchHint => 'Search local music...';

  @override
  String get localMusicRescanDevice => 'Rescan Device';

  @override
  String get buttonCancel => 'Cancel';

  @override
  String get buttonDelete => 'Delete';

  @override
  String get buttonOk => 'OK';

  @override
  String get buttonUpdate => 'Update';

  @override
  String get buttonDownload => 'Download';

  @override
  String get buttonLater => 'Later';

  @override
  String get buttonInfo => 'Info';

  @override
  String get buttonMore => 'More';

  @override
  String get dialogDeleteTrack => 'Delete Track';

  @override
  String dialogDeleteTrackMessage(String title) {
    return 'Are you sure you want to delete \"$title\" from your device? This action cannot be undone.';
  }

  @override
  String get dialogDeleteTrackLinkedPlaylists =>
      'This track will also be removed from:';

  @override
  String get dialogDontAskAgain => 'Don\'t ask me again';

  @override
  String get dialogUpdateAvailable => 'Update Available';

  @override
  String get dialogUpdateNow => 'Update Now';

  @override
  String get dialogDownloadPlaylist => 'Download playlist';

  @override
  String dialogDownloadPlaylistMessage(int count, String title) {
    return 'Do you want to download $count songs from \"$title\"? This will add them to the download queue.';
  }

  @override
  String get dialogDownloadAll => 'Download All';

  @override
  String get playlistEdit => 'Edit Playlist';

  @override
  String get playlistShareFile => 'Share file';

  @override
  String get playlistExportFile => 'Export File';

  @override
  String get playlistPlay => 'Play';

  @override
  String get playlistAddToQueue => 'Add Playlist to Queue';

  @override
  String get playlistShare => 'Share Playlist';

  @override
  String get playlistDelete => 'Delete Playlist';

  @override
  String get playlistEmptyState => 'No songs yet';

  @override
  String get playlistAvailableOffline => 'Available Offline';

  @override
  String get playlistShuffle => 'Shuffle';

  @override
  String get playlistNoMatchSearch => 'No playlists match your search';

  @override
  String get playlistCreateNew => 'Create playlist';

  @override
  String get playlistCreateFirstOne =>
      'No playlists yet. Create one to get started.';

  @override
  String get addToPlaylistNoSongSelected => 'No song selected';

  @override
  String get createPlaylistDialogBarrierLabel => 'Create playlist dialog';

  @override
  String get createPlaylistDialogNameHint => 'Summer Vibes';

  @override
  String get createPlaylistDialogCreate => 'Create';

  @override
  String playlistSongCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Songs',
      one: '1 Song',
    );
    return '$_temp0';
  }

  @override
  String playlistRemovedTrack(String title, String playlist) {
    return '$title removed from $playlist';
  }

  @override
  String get playlistFailedToLoad => 'Failed to load playlist';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsPlugins => 'Plugins';

  @override
  String get settingsPluginsSubtitle => 'Install, load and manage plugins.';

  @override
  String get settingsUpdates => 'Updates';

  @override
  String get settingsUpdatesSubtitle => 'Check for new updates';

  @override
  String get settingsDownloads => 'Downloads';

  @override
  String get settingsDownloadsSubtitle =>
      'Download Path, Download Quality and more...';

  @override
  String get settingsLocalTracks => 'Local Tracks';

  @override
  String get settingsLocalTracksSubtitle =>
      'Scan, manage folders and auto-scan settings.';

  @override
  String get settingsPlayer => 'Player Settings';

  @override
  String get settingsPlayerSubtitle => 'Stream quality, Auto Play, etc.';

  @override
  String get settingsPluginDefaults => 'Plugin Defaults';

  @override
  String get settingsPluginDefaultsSubtitle =>
      'Discover source, resolver priority.';

  @override
  String get settingsUIElements => 'UI Elements & Services';

  @override
  String get settingsUIElementsSubtitle => 'Auto slide, UI tweaks etc.';

  @override
  String get settingsLastFM => 'Last.FM Settings';

  @override
  String get settingsLastFMSubtitle =>
      'API Key, Secret, and Scrobbling settings.';

  @override
  String get settingsStorage => 'Storage';

  @override
  String get settingsStorageSubtitle =>
      'Backup, Cache, History, Restore and more...';

  @override
  String get settingsLanguageCountry => 'Language & Country';

  @override
  String get settingsLanguageCountrySubtitle =>
      'Select your language and country.';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsAboutSubtitle => 'About the app, version, developer, etc.';

  @override
  String get settingsScanning => 'Scanning';

  @override
  String get settingsMusicFolders => 'Music Folders';

  @override
  String get settingsQuality => 'Quality';

  @override
  String get settingsHistory => 'History';

  @override
  String get settingsBackupRestore => 'Backup & Restore';

  @override
  String get settingsAutomatic => 'Automatic';

  @override
  String get settingsDangerZone => 'Danger Zone';

  @override
  String get settingsScrobbling => 'Scrobbling';

  @override
  String get settingsAuthentication => 'Authentication';

  @override
  String get settingsHomeScreen => 'Home Screen';

  @override
  String get settingsChartVisibility => 'Chart Visibility';

  @override
  String get dialogAddingToDownloadQueue => 'Adding to download queue';

  @override
  String get emptyNoInternet => 'No Internet Connection!';

  @override
  String get emptyNoContentPlugin =>
      'No content plugin loaded. Load a Content Resolver in Plugin Manager.';

  @override
  String get emptyRefreshingSource =>
      'Refreshing Discover source... The previous source is no longer available.';

  @override
  String get emptyNoTracks => 'No tracks available';

  @override
  String get emptyNoResults => 'No matches found';

  @override
  String snackbarDeletedTrack(String title) {
    return 'Deleted \"$title\"';
  }

  @override
  String snackbarDeleteFailed(String title) {
    return 'Failed to delete \"$title\"';
  }

  @override
  String get snackbarAddedToNextQueue => 'Added to Next in Queue';

  @override
  String get snackbarAddedToQueue => 'Added to Queue';

  @override
  String snackbarAddedToLiked(String title) {
    return '$title added to favorites';
  }

  @override
  String snackbarNowPlaying(String name) {
    return 'Playing $name';
  }

  @override
  String snackbarPlaylistAddedToQueue(String name) {
    return 'Added $name to Queue';
  }

  @override
  String get snackbarPlaylistUpdated => 'Playlist updated';

  @override
  String get snackbarLinkCopied => 'Link copied';

  @override
  String get snackbarCouldNotOpenLink => 'Could not open link';

  @override
  String snackbarSongsAddedToQueue(int count) {
    return 'Added $count songs to download queue';
  }

  @override
  String get searchHintExplore => 'What do you want to listen to?';

  @override
  String get searchHintLibrary => 'Search library...';

  @override
  String get searchHintPlaylists => 'Search playlists...';

  @override
  String get searchStartTyping => 'Start typing to search...';

  @override
  String get searchNoSuggestions => 'No Suggestions found!';

  @override
  String get searchNoResults =>
      'No results found!\nTry another keyword or source.';

  @override
  String get searchFailed => 'Search failed!';

  @override
  String get searchDiscover => 'Discover new music';

  @override
  String get searchSources => 'SOURCES';

  @override
  String get searchNoPlugins => 'No plugins installed';

  @override
  String get searchTracks => 'Tracks';

  @override
  String get searchAlbums => 'Albums';

  @override
  String get searchArtists => 'Artists';

  @override
  String get searchPlaylists => 'Playlists';

  @override
  String get exploreDiscover => 'Discover';

  @override
  String get exploreRecently => 'Recently';

  @override
  String get exploreLastFmPicks => 'Last.Fm Picks';

  @override
  String get exploreFailedToLoad => 'Failed to load home sections.';

  @override
  String get libraryTitle => 'Library';

  @override
  String get libraryEmptyState =>
      'Your library is empty. Add songs and playlists to get started.';

  @override
  String libraryIn(String playlistName) {
    return 'in $playlistName';
  }

  @override
  String get menuAddToPlaylist => 'Add to Playlist';

  @override
  String get menuSmartReplace => 'Smart Replace';

  @override
  String get menuShare => 'Share';

  @override
  String get menuAvailableOffline => 'Available Offline';

  @override
  String get menuDownload => 'Download';

  @override
  String get menuOpenOriginalLink => 'Open original link';

  @override
  String get menuDeleteTrack => 'Delete';

  @override
  String get tooltipRemoveFromLibrary => 'Remove from Library';

  @override
  String get tooltipSaveToLibrary => 'Save to Library';

  @override
  String get tooltipOpenOriginalLink => 'Open Original Link';

  @override
  String get tooltipAvailableOffline => 'Available Offline';

  @override
  String get tooltipMoreOptions => 'More Options';

  @override
  String get appuiTitle => 'UI & Services';

  @override
  String get appuiAutoSlideCharts => 'Auto Slide Charts';

  @override
  String get appuiAutoSlideChartsSubtitle =>
      'Slide charts automatically in home screen.';

  @override
  String get appuiLastFmPicksSubtitle =>
      'Show suggestions from Last.FM. Login & restart required.';

  @override
  String get appuiNoChartsAvailable =>
      'No charts available. Load a chart provider plugin.';

  @override
  String get appuiLoginToLastFm => 'Please login to Last.FM first.';

  @override
  String get appuiShowInCarousel => 'Show in home carousel.';

  @override
  String get countrySettingTitle => 'Country & Language';

  @override
  String get countrySettingAutoDetect => 'Auto Detect Country';

  @override
  String get countrySettingAutoDetectSubtitle =>
      'Automatically detect your country when the app opens.';

  @override
  String get countrySettingCountryLabel => 'Country';

  @override
  String get countrySettingLanguageLabel => 'Language';

  @override
  String get countrySettingSystemDefault => 'System Default';

  @override
  String get downloadSettingTitle => 'Downloads';

  @override
  String get downloadSettingQuality => 'Download Quality';

  @override
  String get downloadSettingQualitySubtitle =>
      'Universal audio quality preference for downloaded tracks.';

  @override
  String get downloadSettingFolder => 'Download Folder';

  @override
  String get downloadSettingResetFolder => 'Reset Download Folder';

  @override
  String get downloadSettingResetFolderSubtitle =>
      'Restore the default download path.';

  @override
  String get lastfmTitle => 'Last.FM';

  @override
  String get lastfmScrobbleTracks => 'Scrobble Tracks';

  @override
  String get lastfmScrobbleTracksSubtitle =>
      'Send played tracks to your Last.FM profile.';

  @override
  String get lastfmAuthFirst => 'First Authenticate Last.FM API.';

  @override
  String get lastfmAuthenticatedAs => 'Authenticated as';

  @override
  String get lastfmAuthFailed => 'Authentication failed:';

  @override
  String get lastfmNotAuthenticated => 'Not authenticated';

  @override
  String get lastfmSteps =>
      'Steps to authenticate:\n1. Create / open a Last.FM account at last.fm\n2. Generate an API Key at last.fm/api/account/create\n3. Enter your API Key & Secret below\n4. Tap \"Start Auth\" and approve in the browser\n5. Tap \"Get & Save Session Key\" to finish';

  @override
  String get lastfmApiKey => 'API Key';

  @override
  String get lastfmApiSecret => 'API Secret';

  @override
  String get lastfmStartAuth => '1. Start Auth';

  @override
  String get lastfmGetSession => '2. Get & Save Session Key';

  @override
  String get lastfmRemoveKeys => 'Remove Keys';

  @override
  String get lastfmStartAuthFirst =>
      'Start Auth first, then approve in browser.';

  @override
  String get localSettingTitle => 'Local Tracks';

  @override
  String get localSettingAutoScan => 'Auto Scan on Startup';

  @override
  String get localSettingAutoScanSubtitle =>
      'Automatically scan for new local tracks when the app starts.';

  @override
  String get localSettingLastScan => 'Last Scan';

  @override
  String get localSettingNeverScanned => 'Never';

  @override
  String get localSettingScanInProgress => 'Scanning in progress…';

  @override
  String get localSettingScanNowSubtitle =>
      'Manually trigger a full library scan.';

  @override
  String get localSettingNoFolders =>
      'No folders added. Add a folder to start scanning.';

  @override
  String get localSettingAddFolder => 'Add Folder';

  @override
  String get playerSettingTitle => 'Player Settings';

  @override
  String get playerSettingStreamingHeader => 'Streaming';

  @override
  String get playerSettingStreamQuality => 'Streaming Quality';

  @override
  String get playerSettingStreamQualitySubtitle =>
      'Global audio bitrate for online playback.';

  @override
  String get playerSettingQualityLow => 'Low';

  @override
  String get playerSettingQualityMedium => 'Medium';

  @override
  String get playerSettingQualityHigh => 'High';

  @override
  String get playerSettingPlaybackHeader => 'Playback';

  @override
  String get playerSettingAutoPlay => 'Auto Play';

  @override
  String get playerSettingAutoPlaySubtitle =>
      'Enqueue similar songs when the queue ends.';

  @override
  String get playerSettingAutoFallback => 'Auto Fallback Playback';

  @override
  String get playerSettingAutoFallbackSubtitle =>
      'If a plugin is missing or returns no streams, try a compatible resolver for playback only.';

  @override
  String get playerSettingCrossfade => 'Crossfade';

  @override
  String get playerSettingCrossfadeOff => 'Off';

  @override
  String get playerSettingCrossfadeInstant => 'Tracks switch instantly';

  @override
  String playerSettingCrossfadeBlend(int seconds) {
    return '${seconds}s blend between tracks';
  }

  @override
  String get playerSettingEqualizer => 'Equalizer';

  @override
  String get playerSettingEqualizerActive => 'Active';

  @override
  String playerSettingEqualizerActivePreset(String preset) {
    return 'Enabled — $preset preset';
  }

  @override
  String get playerSettingEqualizerSubtitle =>
      '10-band parametric EQ via FFmpeg.';

  @override
  String get pluginDefaultsTitle => 'Plugin Defaults';

  @override
  String get pluginDefaultsDiscoverHeader => 'Discover Source';

  @override
  String get pluginDefaultsNoResolver =>
      'No content resolver loaded. Load a plugin to choose a Discover source.';

  @override
  String get pluginDefaultsAutomaticSubtitle =>
      'Use the first available content resolver.';

  @override
  String get pluginDefaultsPriorityHeader => 'Resolver Priority';

  @override
  String get pluginDefaultsNoPriority =>
      'No content resolvers loaded. Priority ordering will appear here once plugins are loaded.';

  @override
  String get pluginDefaultsPriorityDesc =>
      'Drag to reorder. Higher priority resolvers are tried first when resolving chart items or imported tracks to playable tracks.';

  @override
  String get pluginDefaultsLyricsHeader => 'Lyrics Priority';

  @override
  String get pluginDefaultsLyricsNone => 'No lyrics providers loaded.';

  @override
  String get pluginDefaultsLyricsDesc =>
      'Drag to reorder lyrics providers. The first provider is tried first.';

  @override
  String get pluginDefaultsSuggestionsHeader => 'Search Suggestions';

  @override
  String get pluginDefaultsSuggestionsNone => 'No suggestion providers loaded.';

  @override
  String get pluginDefaultsSuggestionsHistoryOnlyTitle => 'None';

  @override
  String get pluginDefaultsSuggestionsHistoryOnlySubtitle =>
      'Use search history only.';

  @override
  String get storageSettingTitle => 'Storage';

  @override
  String get storageClearHistoryEvery => 'Clear History In Every';

  @override
  String get storageClearHistorySubtitle =>
      'Clear listening history after the chosen period.';

  @override
  String storageDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Days',
      one: '1 Day',
    );
    return '$_temp0';
  }

  @override
  String storageBackupCreatedAt(String path) {
    return 'Backup created at $path';
  }

  @override
  String storageBackupShareFailed(String error) {
    return 'Failed to share backup: $error';
  }

  @override
  String get storageRestoreBackup => 'Restore Backup';

  @override
  String get storageRestoreBackupSubtitle =>
      'Restore your settings and data from a backup file.';

  @override
  String get storageAutoBackup => 'Auto Backup';

  @override
  String get storageAutoLyrics => 'Auto Save Lyrics';

  @override
  String get storageAutoLyricsSubtitle =>
      'Save lyrics automatically when a song plays.';

  @override
  String get storageResetApp => 'Reset Bloomee App';

  @override
  String get storageResetConfirmTitle => 'Confirm Reset';

  @override
  String get storageResetButton => 'Reset';

  @override
  String get storageRestoreOptionsTitle => 'Restore Options';

  @override
  String get storageRestoreContinue => 'Continue';

  @override
  String get storageRestoreConfirmTitle => 'Confirm Restore';

  @override
  String get storageRestoreYes => 'Yes, restore';

  @override
  String get storageRestoring =>
      'Restoring selected data…\nPlease wait until the operation completes.';

  @override
  String get storageRestoreFailedTitle => 'Restore Failed';

  @override
  String get updateSettingTitle => 'Updates';

  @override
  String get updateCheckForUpdates => 'Check for Updates';

  @override
  String get updateCheckSubtitle =>
      'See if a newer version of Bloomee is available.';

  @override
  String get updateAutoNotify => 'Auto Update Notify';

  @override
  String get updateAutoNotifySubtitle =>
      'Get notified when new updates are available on app start.';

  @override
  String get updateCheckTitle => 'Check for Updates';

  @override
  String get updateUpToDate => 'Bloomee is up to date';

  @override
  String get updateViewPreRelease => 'View Latest Pre-Release';

  @override
  String updateCurrentVersion(String curr, String build) {
    return 'Current Version: $curr + $build';
  }

  @override
  String get updateNewVersionAvailable =>
      'A new version of Bloomee is available';

  @override
  String updateVersion(String ver, String build) {
    return 'Version: $ver+$build';
  }

  @override
  String get updateDownloadNow => 'Download Now';

  @override
  String get updateChecking => 'Checking for updates…';

  @override
  String get timerTitle => 'Sleep Timer';

  @override
  String get timerInterludeMessage => 'Playback will stop in…';

  @override
  String get timerHours => 'Hours';

  @override
  String get timerMinutes => 'Minutes';

  @override
  String get timerSeconds => 'Seconds';

  @override
  String get timerStop => 'Stop Timer';

  @override
  String get timerFinishedMessage => 'The sleep timer stopped playback.';

  @override
  String get timerGotIt => 'Got it!';

  @override
  String get timerSetTimeError => 'Please set a time';

  @override
  String get timerStart => 'Start Timer';

  @override
  String get notificationsTitle => 'Notifications';

  @override
  String get notificationsEmpty => 'No Notifications yet!';

  @override
  String get recentsTitle => 'History';

  @override
  String playlistByCreator(String creator) {
    return 'by $creator';
  }

  @override
  String get playlistYou => 'You';

  @override
  String get pluginManagerTitle => 'Plugins';

  @override
  String get pluginManagerEmpty =>
      'No plugins installed.\nTap + to add a .bex file.';

  @override
  String get pluginManagerFilterAll => 'All';

  @override
  String get pluginManagerFilterContent => 'Content Resolvers';

  @override
  String get pluginManagerFilterCharts => 'Chart Providers';

  @override
  String get pluginManagerFilterLyrics => 'Lyrics Providers';

  @override
  String get pluginManagerFilterSuggestions => 'Suggestion Providers';

  @override
  String get pluginManagerFilterImporters => 'Content Importers';

  @override
  String get pluginManagerTooltipRefresh => 'Refresh';

  @override
  String get pluginManagerTooltipInstall => 'Install Plugin';

  @override
  String get pluginManagerNoMatch => 'No plugins match this filter';

  @override
  String pluginManagerPickFailed(String error) {
    return 'Failed to pick file: $error';
  }

  @override
  String get pluginManagerInstalling => 'Installing plugin...';

  @override
  String get pluginManagerTypeContentResolver => 'Content Resolver';

  @override
  String get pluginManagerTypeChartProvider => 'Chart Provider';

  @override
  String get pluginManagerTypeLyricsProvider => 'Lyrics Provider';

  @override
  String get pluginManagerTypeSuggestionProvider => 'Search Suggestions';

  @override
  String get pluginManagerTypeContentImporter => 'Content Importer';

  @override
  String get pluginManagerDeleteTitle => 'Delete Plugin?';

  @override
  String pluginManagerDeleteMessage(String name) {
    return 'Are you sure you want to delete \"$name\"? This will permanently remove its files.';
  }

  @override
  String get pluginManagerDeleteAction => 'Delete';

  @override
  String get pluginManagerCancel => 'Cancel';

  @override
  String get pluginManagerEnablePlugin => 'Enable Plugin';

  @override
  String get pluginManagerUnloadPlugin => 'Unload Plugin';

  @override
  String get pluginManagerDeleting => 'Deleting...';

  @override
  String get pluginManagerApiKeysTitle => 'API Keys';

  @override
  String get pluginManagerApiKeysSaved => 'API keys saved';

  @override
  String get pluginManagerSave => 'Save';

  @override
  String get pluginManagerDetailVersion => 'Version';

  @override
  String get pluginManagerDetailType => 'Type';

  @override
  String get pluginManagerDetailPublisher => 'Publisher';

  @override
  String get pluginManagerDetailLastUpdated => 'Last Updated';

  @override
  String get pluginManagerDetailCreated => 'Created';

  @override
  String get pluginManagerDetailHomepage => 'Homepage';

  @override
  String get pluginManagerDeleteStorageTitle => 'Delete Plugin Data?';

  @override
  String pluginManagerDeleteStorageMessage(String name) {
    return 'Also remove saved API keys and settings for \"$name\"?';
  }

  @override
  String get pluginManagerDeleteStorageKeep => 'Keep Data';

  @override
  String get pluginManagerDeleteStorageRemove => 'Remove Data';

  @override
  String get segmentsSheetTitle => 'Segments';

  @override
  String get segmentsSheetEmpty => 'No segments available';

  @override
  String get segmentsSheetUntitled => 'Untitled Segment';

  @override
  String get smartReplaceTitle => 'Smart Replace';

  @override
  String smartReplaceSubtitle(String title) {
    return 'Choose a playable replacement for \"$title\" and update saved playlist references.';
  }

  @override
  String get smartReplaceClose => 'Close';

  @override
  String get smartReplaceNoMatch => 'No replacement found';

  @override
  String get smartReplaceNoMatchSubtitle =>
      'None of the loaded resolver plugins returned a strong enough match.';

  @override
  String get smartReplaceBestMatch => 'Best match';

  @override
  String get smartReplaceSearchFailed => 'Search failed';

  @override
  String smartReplaceApplyFailed(String error) {
    return 'Smart Replace failed: $error';
  }

  @override
  String smartReplaceApplied(String queue) {
    return 'Applied replacement$queue.';
  }

  @override
  String get smartReplaceQueueUpdated => ' and updated the queue';

  @override
  String get playerUnknownQueue => 'Unknown';

  @override
  String playerLiked(String title) {
    return '$title added to favorites';
  }

  @override
  String playerUnliked(String title) {
    return '$title removed from favorites';
  }

  @override
  String get offlineNoDownloads => 'No Downloads';

  @override
  String get offlineTitle => 'Offline';

  @override
  String get offlineSearchHint => 'Search your songs...';

  @override
  String get offlineRefreshTooltip => 'Refresh Downloads';

  @override
  String get offlineCloseSearch => 'Close Search';

  @override
  String get offlineSearchTooltip => 'Search';

  @override
  String get offlineOpenFailed =>
      'Unable to open this offline track. Try refreshing downloads.';

  @override
  String get offlinePlayFailed =>
      'Could not play this offline song. Please try again.';

  @override
  String albumViewTrackCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Tracks',
      one: '1 Track',
    );
    return '$_temp0';
  }

  @override
  String get albumViewLoadFailed => 'Failed to load album';

  @override
  String get aboutCraftingSubtitle => 'Built for music.';

  @override
  String get aboutFollowGitHub => 'Follow him on GitHub';

  @override
  String get aboutSendInquiry => 'Send a business inquiry';

  @override
  String get aboutCreativeHighlights => 'Updates and creative highlights';

  @override
  String get aboutTipQuote =>
      'Enjoying Bloomee? You can support its development.';

  @override
  String get aboutTipButton => 'Support the project';

  @override
  String get aboutTipDesc => 'Your contribution helps improve Bloomee.';

  @override
  String get aboutGitHub => 'GitHub';

  @override
  String get songInfoSectionDetails => 'Song Details';

  @override
  String get songInfoSectionTechnical => 'Technical Info';

  @override
  String get songInfoSectionActions => 'Actions';

  @override
  String get songInfoLabelTitle => 'Title';

  @override
  String get songInfoLabelArtist => 'Artist';

  @override
  String get songInfoLabelAlbum => 'Album';

  @override
  String get songInfoLabelDuration => 'Duration';

  @override
  String get songInfoLabelSource => 'Source';

  @override
  String get songInfoLabelMediaId => 'Media ID';

  @override
  String get songInfoLabelPluginId => 'Plugin ID';

  @override
  String get songInfoCopyId => 'Copy ID';

  @override
  String get songInfoCopyLink => 'Copy Link';

  @override
  String get songInfoOpenBrowser => 'Open in browser';

  @override
  String get songInfoIdCopied => 'Media ID copied';

  @override
  String get songInfoLinkCopied => 'Link copied';

  @override
  String get songInfoNoLink => 'No link available';

  @override
  String get songInfoOpenFailed => 'Could not open link';

  @override
  String get songInfoUpdateMetadata => 'Get latest metadata';

  @override
  String get songInfoMetadataUpdated => 'Metadata updated';

  @override
  String get songInfoMetadataUpdateFailed => 'Could not update metadata';

  @override
  String get songInfoMetadataUnavailable =>
      'Metadata refresh is unavailable for this source';

  @override
  String get songInfoSearchTitle => 'Search for this song in Bloomee';

  @override
  String get songInfoSearchArtist => 'Search for this artist in Bloomee';

  @override
  String get songInfoSearchAlbum => 'Search for this album in Bloomee';

  @override
  String get eqTitle => 'Equalizer';

  @override
  String get chartNoItems => 'No items in this chart';

  @override
  String get chartLoadFailed => 'Failed to load chart';

  @override
  String get chartPlay => 'Play';

  @override
  String get chartResolving => 'Resolving';

  @override
  String get chartReady => 'Ready';

  @override
  String get chartAddToPlaylist => 'Add to Playlist';

  @override
  String get chartNoResolver =>
      'No content resolver loaded. Install a plugin to play.';

  @override
  String get chartResolveFailed => 'Could not resolve. Searching instead...';

  @override
  String get chartNoResolverAdd => 'No content resolver loaded.';

  @override
  String get chartNoMatch => 'Could not find a match. Try searching manually.';

  @override
  String get chartStatPeak => 'Peak';

  @override
  String get chartStatWeeks => 'Weeks';

  @override
  String get chartStatChange => 'Change';

  @override
  String menuSharePreparing(String title) {
    return 'Preparing $title for share.';
  }

  @override
  String get menuOpenLinkFailed => 'Could not open link';

  @override
  String get localMusicFolders => 'Music Folders';

  @override
  String get localMusicRemoveFolder => 'Remove folder';

  @override
  String get localMusicCloseSearch => 'Close search';

  @override
  String get localMusicOpenSearch => 'Search';

  @override
  String get localMusicNoMusicFound => 'No local music found';

  @override
  String get localMusicNoSearchResults =>
      'No tracks found matching your search.';

  @override
  String localMusicTrackCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tracks',
      one: '1 track',
    );
    return '$_temp0';
  }

  @override
  String get importSongsTitle => 'Import Songs';

  @override
  String get importNoPluginsLoaded =>
      'No content-importer plugins loaded.\nInstall an importer plugin to import playlists from external services.';

  @override
  String get importBloomeeFiles => 'Import Bloomee Files';

  @override
  String get importM3UFiles => 'Import M3U Playlist';

  @override
  String get importM3UNameDialogTitle => 'Playlist Name';

  @override
  String get importM3UNameHint => 'Enter a name for this playlist';

  @override
  String get importM3UNoTracks => 'No valid tracks found in the M3U file.';

  @override
  String get importNoteTitle => 'Note';

  @override
  String get importNoteMessage =>
      'You can only import files created by Bloomee.\nIf your file is from another source, it will not work. Continue anyway?';

  @override
  String get importTitle => 'Import';

  @override
  String get importCheckingUrl => 'Checking URL...';

  @override
  String get importFetchingTracks => 'Fetching tracks...';

  @override
  String get importSavingToLibrary => 'Saving to library...';

  @override
  String get importPasteUrlHint => 'Paste a playlist or album URL to import';

  @override
  String get importAction => 'Import';

  @override
  String importTrackCount(int count) {
    return '$count tracks';
  }

  @override
  String importResolvingProgress(int done, int total) {
    return 'Resolving tracks: $done / $total';
  }

  @override
  String importSaveTracks(int count) {
    return 'Save $count Tracks';
  }

  @override
  String importTracksSaved(int count) {
    return '$count tracks saved!';
  }

  @override
  String get importDone => 'Done';

  @override
  String get importMore => 'Import More';

  @override
  String get importUnknownError => 'Unknown error';

  @override
  String get importTryAgain => 'Try Again';

  @override
  String get importSkipTrack => 'Skip this track';

  @override
  String get importMatchOptions => 'Match options';

  @override
  String get importSkipped => 'Skipped';

  @override
  String get importReorderTip => 'Long press a playlist to start reordering';

  @override
  String get importErrorCannotHandleUrl =>
      'This plugin cannot handle the provided URL.';

  @override
  String get importErrorUnexpectedResponse =>
      'Unexpected response from plugin.';

  @override
  String importErrorFailedToCheck(String error) {
    return 'Failed to check URL: $error';
  }

  @override
  String importErrorFailedToFetchInfo(String error) {
    return 'Failed to fetch collection info: $error';
  }

  @override
  String importErrorFailedToFetchTracks(String error) {
    return 'Failed to fetch tracks: $error';
  }

  @override
  String importErrorFailedToSave(String error) {
    return 'Failed to save playlist: $error';
  }

  @override
  String get playlistPinToTop => 'Pin to Top';

  @override
  String get playlistUnpin => 'Unpin';

  @override
  String get snackbarInvalidFileFormat => 'Invalid File Format';

  @override
  String get snackbarProcessingFile => 'Processing File...';

  @override
  String get pluginManagerTabInstalled => 'Installed';

  @override
  String get pluginManagerTabStore => 'Plugin Store';

  @override
  String get pluginManagerSelectPackage => 'Select Plugin Package (.bex)';

  @override
  String get pluginManagerOutdatedManifest =>
      'Plugin uses an outdated manifest version. Some features might break. Consider updating.';

  @override
  String get pluginManagerStatusActive => 'Active';

  @override
  String get pluginManagerStatusInactive => 'Inactive';

  @override
  String get pluginRepositoryAddTitle => 'Add Repository';

  @override
  String get pluginRepositoryAddSubtitle =>
      'Enter the URL of a valid plugin repository JSON file.';

  @override
  String get pluginRepositoryAddAction => 'Add Repository';

  @override
  String get pluginRepositoryTitle => 'Plugin Repositories';

  @override
  String get pluginRepositorySubtitle =>
      'Add a JSON source to browse remote plugins.';

  @override
  String get pluginRepositoryEmpty => 'No repositories added yet.';

  @override
  String get pluginRepositoryUnknownUpdate => 'Unknown update';

  @override
  String get pluginRepositoryNoDescription => 'No description provided.';

  @override
  String get pluginRepositoryUrlCopied => 'Repository URL copied to clipboard';

  @override
  String pluginRepositoryPluginsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count plugins',
      one: '1 plugin',
    );
    return '$_temp0';
  }

  @override
  String pluginRepositoryUpdatedOn(String date) {
    return 'Updated $date';
  }

  @override
  String pluginRepositoryAvailableCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count plugins available',
      one: '1 plugin available',
    );
    return '$_temp0';
  }

  @override
  String get pluginRepositoryOutdatedManifest =>
      'Outdated manifest. Features may break.';

  @override
  String get pluginRepositoryUnknownPublisher => 'Unknown publisher';

  @override
  String get pluginRepositoryActionRetry => 'Retry';

  @override
  String get pluginRepositoryActionOutdated => 'Outdated';

  @override
  String get pluginRepositoryActionInstalled => 'Installed';

  @override
  String get pluginRepositoryActionInstall => 'Install';

  @override
  String get pluginRepositoryActionUnavailable => 'Unavailable';

  @override
  String get pluginRepositoryInstallFailed => 'Installation failed.';

  @override
  String pluginRepositoryDownloadFailed(String name) {
    return 'Failed to download $name.';
  }

  @override
  String get pluginRepositoryErrorLoad => 'Failed to load repositories.';

  @override
  String get pluginRepositoryErrorInvalid =>
      'Invalid repository URL or repository file.';

  @override
  String get pluginRepositoryErrorRemove => 'Failed to remove repository.';

  @override
  String smartReplaceAppliedPlaylistsSummary(int count, String queue) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Replaced in $count playlists$queue.',
      one: 'Replaced in 1 playlist$queue.',
    );
    return '$_temp0';
  }

  @override
  String get lyricsSearchFieldLabel => 'Search for lyrics...';

  @override
  String get lyricsSearchEmptyPrompt => 'Type a song or artist to find lyrics.';

  @override
  String lyricsSearchNoResults(String query) {
    return 'No lyrics found for \"$query\"';
  }

  @override
  String get lyricsSearchApplied => 'Lyrics successfully applied';

  @override
  String get lyricsSearchFetchFailed => 'Failed to fetch lyrics';

  @override
  String get lyricsSearchPreview => 'Preview';

  @override
  String get lyricsSearchPreviewTooltip => 'Preview lyrics';

  @override
  String get lyricsSearchSynced => 'SYNCED';

  @override
  String get lyricsSearchPreviewLoadFailed => 'Failed to load lyrics.';

  @override
  String get lyricsSearchApplyAction => 'Apply Lyrics';

  @override
  String get lyricsSettingsSearchTitle => 'Search Custom Lyrics';

  @override
  String get lyricsSettingsSearchSubtitle => 'Find alternative versions online';

  @override
  String get lyricsSettingsSyncTitle => 'Adjust Sync (Delay/Offset)';

  @override
  String get lyricsSettingsSyncSubtitle =>
      'Fix lyrics that are too fast or slow';

  @override
  String get lyricsSettingsSaveTitle => 'Save Offline';

  @override
  String get lyricsSettingsSaveSubtitle => 'Store these lyrics on your device';

  @override
  String get lyricsSettingsDeleteTitle => 'Delete Saved Lyrics';

  @override
  String get lyricsSettingsDeleteSubtitle => 'Remove offline lyrics data';

  @override
  String get lyricsSyncTapToReset => 'Tap to reset';

  @override
  String get upNextTitle => 'Up Next';

  @override
  String upNextItemsInQueue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items in queue',
      one: '1 item in queue',
    );
    return '$_temp0';
  }

  @override
  String get tooltipCopyToClipboard => 'Copy to clipboard';

  @override
  String get snackbarCopiedToClipboard => 'Copied to clipboard';

  @override
  String get tooltipSongInfo => 'Song Info';

  @override
  String get snackbarCannotDeletePlayingSong =>
      'Cannot delete currently playing song';

  @override
  String get playerLoopOff => 'Off';

  @override
  String get playerLoopOne => 'Loop One';

  @override
  String get playerLoopAll => 'Loop All';

  @override
  String get snackbarOpeningAlbumPage => 'Opening original album page.';

  @override
  String updateAvailableBody(String ver, String build) {
    return 'A new version of Bloomee is available.\n\nVersion: $ver+$build';
  }

  @override
  String pluginSnackbarInstalled(String id) {
    return 'Plugin \"$id\" installed successfully';
  }

  @override
  String pluginSnackbarDeleted(String id) {
    return 'Plugin \"$id\" deleted successfully';
  }

  @override
  String get pluginBootstrapTitle => 'Setting up Bloomee';

  @override
  String pluginBootstrapProgress(int percent) {
    return 'Setting up new plugin engine... $percent%';
  }

  @override
  String get pluginBootstrapHint => 'This only happens once.';

  @override
  String get backupSave => 'Save backup as JSON';

  @override
  String get backupShare => 'Share JSON backup';

  @override
  String get backupPortableDetails =>
      'Includes playlists, likes, saved collections, histories and portable preferences. Audio files, accounts and device folders are excluded.';

  @override
  String get backupHistories => 'Playback and search histories';

  @override
  String get backupPreferences => 'Portable preferences';

  @override
  String get backupNewCopy => 'Import as new playlists';

  @override
  String get backupMerge => 'Merge with existing data';

  @override
  String get backupReplace => 'Replace selected sections';

  @override
  String get backupMergeDetails =>
      'Existing tracks, metadata and preferences are preserved. Missing tracks are appended in file order. Likes are merged.';

  @override
  String get backupReplaceWarning =>
      'This replaces the selected sections, including existing playlists and likes when library is selected. Unselected sections and device files are preserved. A private recovery snapshot is created first.';

  @override
  String get backupAutoDetails =>
      'Keeps seven private recovery snapshots. Checked when the app opens, at most once per 24 hours. Private snapshots are removed on uninstall.';

  @override
  String get backupLocationDetails =>
      'Choose a destination with Save backup. Private recovery snapshots are kept inside the app.';

  @override
  String get backupResetDetails =>
      'Reset all database data on the next app start. Downloaded audio files and installed plugin files remain on this device. A private recovery snapshot is created first.';

  @override
  String get backupResetPending =>
      'Reset scheduled. Close and reopen Bloomee to complete it.';

  @override
  String backupPreviewCounts(int playlists, int tracks) {
    return '$playlists playlists and $tracks tracks';
  }

  @override
  String backupImportResult(
      int playlists, int tracks, int history, int settings) {
    return 'Import complete: $playlists playlists created, $tracks track entries added, $history history records added and $settings preferences applied.';
  }

  @override
  String get backupRefreshFailed =>
      'Data was imported. Close and reopen Bloomee to refresh all preferences.';

  @override
  String get backupRecoveryCopies => 'Recovery copies';

  @override
  String get backupNoRecoveryCopies => 'No recovery copies yet.';

  @override
  String get backupRecoveryAutomatic => 'Automatic backup';

  @override
  String get backupRecoveryBeforeImport => 'Before an import';

  @override
  String get backupRecoveryBeforeReset => 'Before a reset';

  @override
  String get backupCancelReset => 'Cancel reset';

  @override
  String get libraryRecoveryTitle => 'Recover missing library';

  @override
  String get libraryRecoverySubtitle =>
      'Look for playlists and download records retained from earlier versions.';

  @override
  String get libraryRecoveryChooseSource =>
      'Choose a retained database to scan. Your current library and original files will be preserved.';

  @override
  String get libraryRecoveryNoSources =>
      'No retained databases were found. Audio files alone cannot restore original playlist membership.';

  @override
  String libraryRecoverySummary(
      int tracks, int playlists, int downloads, int unavailable) {
    return 'Found $tracks tracks, $playlists playlists and $downloads download records. $unavailable files are currently unavailable; their records will be preserved.';
  }

  @override
  String libraryRecoveryWarnings(int broken) {
    return '$broken broken playlist references could not be reconstructed from this copy.';
  }

  @override
  String get libraryRecoveryMergeDetails =>
      'Recovery adds missing tracks, playlist entries and download records. Existing playlists, file mappings and settings are preserved. A recovery copy is created first. Repeat this with another retained copy if it contains more of your library.';

  @override
  String get libraryRecoveryMerge => 'Merge recovered library';

  @override
  String libraryRecoveryComplete(int entries, int downloads) {
    return 'Recovery complete: $entries playlist entries and $downloads download records added.';
  }

  @override
  String get backupStartupFailed => 'Bloomee could not start';

  @override
  String get backupStartupFailedDetails =>
      'Startup stopped without automatically repairing or replacing your database. Close the app and retry. Keep your app data when reporting this error.';

  @override
  String get lyricsTitle => 'Lyrics';

  @override
  String get lyricsEnterFullscreen => 'Fullscreen lyrics';

  @override
  String get lyricsExitFullscreen => 'Exit fullscreen';

  @override
  String get lyricsFollowPlayback => 'Follow playback';

  @override
  String get lyricsTimingEarlier => 'Earlier';

  @override
  String get lyricsTimingLater => 'Later';

  @override
  String get lyricsTimingSave => 'Save timing';

  @override
  String get lyricsSaved => 'Lyrics saved.';

  @override
  String get lyricsSaveFailed => 'Could not save lyrics. Try again.';

  @override
  String get lyricsDeleteFailed => 'Could not delete saved lyrics. Try again.';

  @override
  String get artistTopSongs => 'Top songs';

  @override
  String get artistLoadFailed => 'Failed to load artist';

  @override
  String get artistNoTopSongs => 'No top songs available';

  @override
  String get artistNoAlbums => 'No albums available';

  @override
  String get snackbarOpeningArtistPage => 'Opening original artist page.';

  @override
  String get snackbarOpeningPlaylistPage => 'Opening original playlist page.';

  @override
  String get playlistSaveOrderFailed =>
      'Unable to save playlist order. Please try again.';

  @override
  String get playlistReorderTracksHint => 'Hold the handle to reorder tracks';

  @override
  String get playlistTrackCountLabel => 'Number of tracks';

  @override
  String get playlistDescription => 'Description';

  @override
  String get playlistOriginalUrl => 'Original URL';

  @override
  String get searchSearching => 'Searching…';

  @override
  String get searchSuggestions => 'Suggestions';

  @override
  String get searchTopResults => 'Top results';

  @override
  String get changelogEmpty => 'No changelog information available.';

  @override
  String get changelogTitle => 'What\'s new';

  @override
  String get changelogLatest => 'Latest';

  @override
  String get changelogNext => 'Next version';

  @override
  String changelogVersion(String version) {
    return 'Version $version';
  }

  @override
  String get pluginBootstrapIncomplete => 'Setup incomplete';

  @override
  String get pluginBootstrapRetryBody =>
      'Some plugins could not be installed right now. Retry to finish setup.';

  @override
  String get pluginBootstrapInternetTitle => 'Internet required';

  @override
  String get pluginBootstrapInternetBody =>
      'Bloomee needs an internet connection once to detect your country and set up the plugin engine.';

  @override
  String get buttonExit => 'Exit';

  @override
  String get eqSource => 'Equalizer source';

  @override
  String get eqBuiltin => 'In-app equalizer';

  @override
  String get eqBuiltinSubtitle => '10-band equalizer';

  @override
  String get eqDevice => 'Device equalizer';

  @override
  String get eqDeviceSubtitle => 'System / Dolby Atmos';

  @override
  String get eqDeviceHint =>
      'The in-app equalizer is disabled. Configure your device equalizer in your device\'s sound settings.';

  @override
  String get eqPresets => 'Presets';

  @override
  String get eqCustomCurve => 'Custom curve';

  @override
  String get shortcutMuted => 'Muted';

  @override
  String get shortcutUnmuted => 'Unmuted';

  @override
  String get shortcutShuffleOn => 'Shuffle on';

  @override
  String get shortcutShuffleOff => 'Shuffle off';

  @override
  String get shortcutRepeatOff => 'Repeat off';

  @override
  String get shortcutLiked => 'Added to favorites';

  @override
  String get shortcutUnliked => 'Removed from favorites';

  @override
  String downloadFolderSelectFailed(String error) {
    return 'Could not select download folder: $error';
  }

  @override
  String get aboutVersionUnavailable => 'Version unavailable';

  @override
  String get backupNewCopyDetails =>
      'Creates separate playlists and merges favorites. Existing playlists are preserved. Selected histories and preferences are also imported.';

  @override
  String get changelogCurrent => 'Current';

  @override
  String get backupLibrary =>
      'Library (playlists, favorites and saved collections)';

  @override
  String get eqPresetFlat => 'Flat';

  @override
  String get eqPresetAcoustic => 'Acoustic';

  @override
  String get eqPresetBassBoost => 'Bass boost';

  @override
  String get eqPresetBassReducer => 'Bass reduction';

  @override
  String get eqPresetClassical => 'Classical';

  @override
  String get eqPresetDance => 'Dance';

  @override
  String get eqPresetDeep => 'Deep';

  @override
  String get eqPresetEDM => 'EDM';

  @override
  String get eqPresetElectronic => 'Electronic';

  @override
  String get eqPresetHipHop => 'Hip-hop';

  @override
  String get eqPresetJazz => 'Jazz';

  @override
  String get eqPresetLatin => 'Latin';

  @override
  String get eqPresetLive => 'Live';

  @override
  String get eqPresetLounge => 'Lounge';

  @override
  String get eqPresetMetal => 'Metal';

  @override
  String get eqPresetPiano => 'Piano';

  @override
  String get eqPresetPop => 'Pop';

  @override
  String get eqPresetRB => 'R&B';

  @override
  String get eqPresetRock => 'Rock';

  @override
  String get eqPresetSmallSpeakers => 'Small speakers';

  @override
  String get eqPresetSpokenWord => 'Spoken word';

  @override
  String get eqPresetTrebleBoost => 'Treble boost';

  @override
  String get eqPresetTrebleReducer => 'Treble reduction';

  @override
  String get eqPresetVocalBooster => 'Vocal boost';

  @override
  String get eqPresetCustom => 'Custom';

  @override
  String get settingsLibrarySync => 'Library Sync';

  @override
  String get settingsLibrarySyncSubtitle =>
      'Keep your playlists the same on all your devices.';

  @override
  String get syncTitle => 'Library Sync';

  @override
  String get syncEnableTitle => 'Sync this device';

  @override
  String get syncEnableSubtitle =>
      'Your playlists, favorites and saved albums and artists stay the same on every device that syncs with the same place. Nothing leaves this device until you turn this on or choose a sync location.';

  @override
  String get syncLocationHeader => 'Sync location';

  @override
  String get syncLocalFolder => 'Local folder (advanced)';

  @override
  String get syncLocalFolderNote =>
      'Bloomee only reads and writes files in this folder. Another tool, such as Syncthing, must carry it between your machines.';

  @override
  String get syncNoFolder => 'No folder chosen';

  @override
  String snackbarSyncFolderPickerFailed(String error) {
    return 'The folder picker could not open: $error';
  }

  @override
  String get syncFolderNotFound =>
      'This folder cannot be found. Check that it exists and that its drive is connected.';

  @override
  String get syncFolderNotFoundAndroid =>
      'Bloomee cannot reach this folder: it was moved or deleted, its memory card was removed, or Bloomee no longer has access to it. Choose the folder again.';

  @override
  String get syncFolderNotWritable =>
      'Bloomee cannot write into this folder. Choose a folder you are allowed to change.';

  @override
  String get syncDeviceHeader => 'This device';

  @override
  String get syncDeviceName => 'Device name';

  @override
  String get syncDeviceNameSubtitle =>
      'How your other devices name this one. Renaming changes nothing about what syncs.';

  @override
  String get syncDevicesHeader => 'Devices';

  @override
  String get syncDevicesNote =>
      'Every device that syncs through this sync location. A device you no longer use stays here until you forget it.';

  @override
  String get syncThisDevice => 'This device';

  @override
  String get syncDeviceLastSyncUnknown => 'Last sync unknown';

  @override
  String get syncForgetDevice => 'Forget';

  @override
  String dialogSyncForgetTitle(String device) {
    return 'Forget $device?';
  }

  @override
  String dialogSyncForgetBody(String device) {
    return 'What $device published is deleted from the sync location. Nothing is removed from your libraries, on this device or any other. If $device syncs again, it comes back in this list.';
  }

  @override
  String get buttonSyncForget => 'Forget device';

  @override
  String snackbarSyncForgetFailed(String device) {
    return '$device could not be forgotten: the sync location cannot be reached.';
  }

  @override
  String get syncStatusHeader => 'Status';

  @override
  String get syncNow => 'Sync now';

  @override
  String get syncSyncing => 'Syncing…';

  @override
  String get syncNeverSynced => 'Not synced yet';

  @override
  String syncLastSynced(String time) {
    return 'Last synced: $time';
  }

  @override
  String syncLastError(String time, String error) {
    return 'Last error ($time): $error';
  }

  @override
  String get syncErrorUnreachable =>
      'the sync location cannot be reached. Sync tries again by itself.';

  @override
  String syncErrorFailed(String detail) {
    return 'sync failed ($detail). Sync tries again by itself.';
  }

  @override
  String get syncErrorHeld =>
      'removals from another device are waiting for your decision.';

  @override
  String get syncErrorPaused =>
      'sync is paused because you declined removals from another device.';

  @override
  String get syncErrorUpdateNeeded => 'update Bloomee to keep syncing.';

  @override
  String syncErrorSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'the changes of $count devices were left out.',
      one: 'the changes of $count device were left out.',
    );
    return '$_temp0';
  }

  @override
  String get syncReviewRemovals => 'Review removals';

  @override
  String get dialogSyncGuardTitle => 'Confirm these removals?';

  @override
  String dialogSyncGuardSummary(int removed, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      removed,
      locale: localeName,
      other: 'This sync would remove $removed of your $total songs.',
      one: 'This sync would remove $removed of your $total songs.',
    );
    return '$_temp0';
  }

  @override
  String dialogSyncGuardFrom(String devices) {
    return 'Made on: $devices';
  }

  @override
  String dialogSyncGuardPlaylistDeleted(String name) {
    return 'Playlist “$name” deleted, with its songs';
  }

  @override
  String dialogSyncGuardSongRemoved(String title, String playlist) {
    return '“$title” taken out of “$playlist”';
  }

  @override
  String dialogSyncGuardUnliked(String title) {
    return '“$title” removed from favorites';
  }

  @override
  String dialogSyncGuardOnDevice(String device) {
    return 'on $device';
  }

  @override
  String get buttonSyncRemove => 'Remove them';

  @override
  String get buttonSyncKeepLibrary => 'Keep my library';

  @override
  String get dialogSyncGuardDeclineNote =>
      'If you keep your library, sync pauses until you confirm these removals from the Library Sync settings.';

  @override
  String get dialogSyncAnotherDevice => 'another device';

  @override
  String get dialogSyncClockTitle => 'A device\'s clock is wrong';

  @override
  String dialogSyncClockBody(String device, String time) {
    return '$device dates a change $time, more than a day ahead of this device. Its changes are refused until its clock is set right.';
  }

  @override
  String get dialogSyncUnreadableTitle =>
      'What a device published cannot be read';

  @override
  String dialogSyncUnreadableBody(String device) {
    return 'What $device published for your other devices is damaged or unreadable, so its changes are left out. Your other devices still sync. The next time $device syncs, it publishes again.';
  }

  @override
  String get dialogSyncUpdateTitle => 'Update Bloomee to keep syncing';

  @override
  String dialogSyncUpdateBody(String device) {
    return '$device uses a newer sync format than this version of Bloomee can read. Sync is stopped on this device until you update Bloomee.';
  }

  @override
  String get syncDropbox => 'Dropbox';

  @override
  String get syncDropboxNote =>
      'Bloomee only uses its own app folder in your Dropbox and cannot see your other files. Sign in once on each device.';

  @override
  String get syncDropboxSignedIn => 'Signed in';

  @override
  String get syncDropboxSignedOut => 'Not signed in';

  @override
  String get syncLocationInUse => 'In use';

  @override
  String get syncLocationMoveNote =>
      'Choosing another sync location moves sync there. Nothing in the old one is changed or deleted.';

  @override
  String get buttonDropboxSignOut => 'Sign out of Dropbox';

  @override
  String get dialogDropboxSignInTitle => 'Sign in to Dropbox';

  @override
  String get dialogDropboxSignInBody =>
      'With the key entered, open the Dropbox page and allow Bloomee. Dropbox then shows a code: copy it and paste it below.';

  @override
  String get buttonDropboxOpenPage => 'Open the Dropbox page';

  @override
  String get dialogDropboxPageNotOpened =>
      'The browser could not be opened. Open this address yourself:';

  @override
  String get dialogDropboxCode => 'Code from Dropbox';

  @override
  String get buttonDropboxSignIn => 'Sign in';

  @override
  String get syncDropboxNotReachable =>
      'Dropbox cannot be reached. Check your connection and try again.';

  @override
  String get syncDropboxNotWritable =>
      'Bloomee cannot write into its Dropbox folder.';

  @override
  String get syncSignInRefused =>
      'Dropbox did not accept this sign-in. Open the Dropbox page again and paste the new code.';

  @override
  String get syncKeyringUnavailable =>
      'The sign-in could not be kept in the system keyring. On Linux, check that a keyring such as GNOME Keyring or KWallet is running and unlocked.';

  @override
  String get syncErrorSignInNeeded =>
      'Dropbox no longer accepts this device\'s sign-in. Sign in again to keep syncing.';

  @override
  String get dialogSyncSignInTitle => 'Sign in to Dropbox again';

  @override
  String get dialogSyncSignInBody =>
      'Dropbox no longer accepts this device\'s sign-in: it expired or was revoked. Sync is stopped on this device until you sign in again in the Library Sync settings.';

  @override
  String get snackbarSyncSignOutFailed =>
      'Could not sign out: the system keyring cannot be changed.';

  @override
  String get dialogSyncChooseLocationTitle => 'Where should this device sync?';

  @override
  String get backupReplaceSyncWarning =>
      'Library Sync is on: this replacement will also reach your other devices. Playlists, songs, favorites and saved albums and artists this backup lacks will be removed from them too.';

  @override
  String get backupReplaceSyncOffWarning =>
      'Library Sync is set up on this device, though turned off: once it is back on, this replacement will reach your other devices. Playlists, songs, favorites and saved albums and artists this backup lacks will be removed from them too.';

  @override
  String get syncWebDav => 'WebDAV server';

  @override
  String get syncWebDavNote =>
      'Your own server, such as Nextcloud. Bloomee syncs in the folder you give, and creates it if needed. The password is kept in the system keyring.';

  @override
  String get syncWebDavNotSetUp => 'Not set up';

  @override
  String syncWebDavAccount(String user, String address) {
    return '$user on $address';
  }

  @override
  String get buttonWebDavSignOut => 'Sign out of the WebDAV server';

  @override
  String get dialogWebDavTitle => 'Connect to a WebDAV server';

  @override
  String get dialogWebDavBody =>
      'Enter the address of the folder to sync in, such as https://cloud.example.com/remote.php/dav/files/you/Bloomee, and your user name and password on that server.';

  @override
  String get dialogWebDavAddress => 'Folder address';

  @override
  String get dialogWebDavUser => 'User name';

  @override
  String get dialogWebDavPassword => 'Password';

  @override
  String get buttonWebDavConnect => 'Connect';

  @override
  String get syncWebDavInvalidAddress =>
      'This is not a server address. Enter one such as https://cloud.example.com/dav/Bloomee.';

  @override
  String get syncWebDavInsecureAddress =>
      'Bloomee does not send your password unprotected: use an https:// address. Plain http:// is only accepted for localhost.';

  @override
  String get syncDropboxRefused =>
      'Dropbox refused what Bloomee asked. Try again later; if it keeps refusing, sign out of Dropbox and sign in again.';

  @override
  String get syncWebDavRefused =>
      'The WebDAV server refused what Bloomee asked. Check that this user may write into that folder, and that the server\'s certificate is valid: a self-signed certificate is not accepted.';

  @override
  String get syncLocationRefused =>
      'The sync location refused what Bloomee asked.';

  @override
  String get syncWebDavNotReachable =>
      'The WebDAV server cannot be reached. Check the address and your connection and try again.';

  @override
  String get syncWebDavNotWritable =>
      'Bloomee cannot write into this folder on the WebDAV server.';

  @override
  String get syncWebDavSignInRefused =>
      'The WebDAV server did not accept this user name and password.';

  @override
  String get syncWebDavKeyringUnavailable =>
      'The password could not be kept in the system keyring. On Linux, check that a keyring such as GNOME Keyring or KWallet is running and unlocked.';

  @override
  String get syncErrorWebDavSignInNeeded =>
      'The WebDAV server no longer accepts this device\'s user name and password. Enter them again to keep syncing.';

  @override
  String get dialogSyncWebDavSignInTitle =>
      'The WebDAV server refused the password';

  @override
  String get dialogSyncWebDavSignInBody =>
      'The WebDAV server no longer accepts this device\'s user name and password. Sync is stopped on this device until you enter them again in the Library Sync settings.';

  @override
  String get syncErrorKeyringUnavailable =>
      'the system keyring, which holds this device\'s sign-in, cannot be read. Unlock it, then restart Bloomee.';

  @override
  String get dialogSyncKeyringTitle => 'The system keyring cannot be read';

  @override
  String get dialogSyncKeyringBody =>
      'Bloomee keeps this device\'s sign-in to its sync location in the system keyring, which cannot be read now, so this device does not sync. Unlock the keyring (on Linux, GNOME Keyring or KWallet), then restart Bloomee.';

  @override
  String get dialogDropboxAppBody =>
      'Register a Dropbox app of your own, which this device signs in through:\n1. In the Dropbox App Console, create an app: choose Scoped access, then App folder, and give it a name. Its folder in your Dropbox is Apps/<name>.\n2. In the app\'s Permissions tab, tick files.metadata.read, files.content.read and files.content.write, then Submit.\n3. In its Settings tab, copy the App key and paste it in the App key field above. The key is not a secret, and the App secret is not needed.\nEnter the same key on each of your devices: each app has its own folder, so devices on different apps do not sync together.';

  @override
  String get buttonDropboxOpenAppConsole => 'Open the Dropbox App Console';

  @override
  String get dialogDropboxAppKey => 'App key';

  @override
  String get dialogDropboxAppRequiredNote =>
      'Bloomee has no Dropbox app of its own: Dropbox needs yours.';

  @override
  String get syncDropboxAppKeyRefused =>
      'Dropbox does not know this app key. Sign out of Dropbox, then sign in again with the App key from the Settings tab of your app in the Dropbox App Console.';

  @override
  String get buttonDropboxAppKeyHelp => 'How do I get an app key?';

  @override
  String get dialogDropboxKeyChanged =>
      'The key changed: open the Dropbox page again.';

  @override
  String get dialogDropboxAppKeyRefused =>
      'Dropbox does not know this app key. Copy it again from the Settings tab of your app in the Dropbox App Console, then open the Dropbox page again.';
}
