---
status: accepted
---

# Sync through one Device State file per Device, Latest Change Wins

Library Sync must work without an account or any server logic, over storage that can only hold files (a local folder, WebDAV, a Dropbox app folder). Each Device therefore publishes its whole Synced Library, with Removal Markers and change times, in a Device State file that only it writes; a Device syncs by reading the others' files, merging them under Latest Change Wins, and rewriting its own. Because no file has two writers, no Sync Location needs locking or conflict handling, and because the merge gives the same result in any order, every Device converges.

## Considered Options

- **A sync server holding the library.** Rejected: Bloomee is deliberately login-free, and it would add something to host and maintain.
- **One shared library file all Devices rewrite.** Rejected: two Devices writing at once lose a change, and preventing that needs locking the storage kinds do not offer uniformly.
- **A shared log of changes.** Rejected: the same concurrent-append problem, plus compaction.

## Consequences

- Correctness depends on Device clocks being roughly right, so a Device State dated more than a day in the future is refused.
- Removal Markers expire after six months; a Device away longer than that goes through First Sync again, which only adds.
- A retired Device's file stays until its owner chooses to Forget it.
