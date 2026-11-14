# Library Sync

Keeping one person's Bloomee library identical across their own devices, through plain file storage and without an account or server logic.

## Language

**Device**:
One Bloomee install taking part in sync, with a name its owner chose.
_Avoid_: Client, node, peer

**Sync Location**:
The single place a Device syncs with: a Dropbox app folder, a WebDAV URL, or a local folder that some other tool keeps identical across machines. Every Device of one person points at the same Sync Location.
_Avoid_: Remote, cloud, sync folder, backend

**Device State**:
The file a Device publishes in the Sync Location describing its Synced Library. Only that Device ever writes it.
_Avoid_: Sync file, snapshot, backup

**Synced Library**:
The part of the library that sync covers: playlists (details, songs and their order, and the order of the playlists themselves), liked songs, and saved albums and artists. History, settings, downloads and audio files are not part of it.
_Avoid_: Library (alone), user data

**First Sync**:
The sync a Device performs when it has no sync history. It pairs playlists with other Devices' by name and only adds; it never removes.
_Avoid_: Initial import, bootstrap

**Removal Marker**:
The record that a playlist was deleted or a song was taken out of a playlist, kept so the removal reaches other Devices.
_Avoid_: Tombstone, deletion flag

**Latest Change Wins**:
The rule that settles every disagreement between Devices: the more recent change prevails, including an addition made after a removal.
_Avoid_: Conflict resolution, last write wins

**Forget a Device**:
The owner's explicit act of deleting a retired Device's Device State from the Sync Location. Devices are never forgotten automatically.
_Avoid_: Expire, unlink, remove device

**Removal Guard**:
The pause for the owner's confirmation before a sync that would remove an unusually large part of the Synced Library.
_Avoid_: Safety check, threshold

**Location Backup**:
A full-library backup a Device writes daily into the Sync Location, separate from its Device State and covering history and settings too.
_Avoid_: Sync backup, cloud backup
