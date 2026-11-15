## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

The seven default triage roles, written as a `Status:` line in each issue file. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Development environment (fork-only, NixOS)

`flake.nix`, `flake.lock` and `nix/` are fork-only; leave them out of upstream pull requests. The shell provides Flutter 3.47.7 (the version upstream CI pins), the Rust toolchain for `rust/`, and the Linux desktop build dependencies (GTK, libmpv, clang, cmake, ninja).

Limits of the shell, and what they mean:

- It targets `x86_64-linux` and the Linux desktop only: it carries no Android, web or other engine artifacts, so it cannot build the Android app (the fork's CI does that).
- Flutter 3.47.7 is not in nixpkgs; `nix/flutter-3.47.7.json` holds the data nixpkgs' Flutter update script generated for it, and `flake.nix` builds it through nixpkgs' internal `flutterPackages.mkFlutter`. A `nix flake update` can break that if nixpkgs reorganises its Flutter packaging; when upstream moves to another Flutter version, regenerate the JSON for it.
- Rust comes from the locked nixpkgs (1.99.0 at the time of writing), while upstream CI uses whatever Rust stable is current. Cargokit's calls to `rustup` are answered by a stand-in that maps `stable` to that toolchain.
- The shell puts the locked Isar Core (`libisar.so` in the pub cache) on `LD_LIBRARY_PATH` for the database tests and warns on entry if it is missing. It reads the version from `pubspec.lock` when the shell starts, so re-enter the shell after a `flutter pub get` that changes the Isar version.

Run everything from the repository root, inside the shell:

- Enter the environment: `nix develop` (or prefix a single command: `nix develop -c <command>`)
- Fetch packages (first time, and after `pubspec.lock` changes): `flutter pub get --enforce-lockfile`
- Run one test file: `flutter test test/backup_database_test.dart`
- Run the whole suite: `flutter test --no-pub` (as in `CONTRIBUTING.md`). It takes under 2 minutes. An agent should still wrap it, so that a hang a future change brings in cannot block it: `timeout 900 flutter test --no-pub`
- A test opens an Isar database with `createTestDirectory` and `openTestDatabase` from `test/support/isar_test_support.dart`, not `Isar.open` and `Directory.systemTemp`: they keep the database in memory (`/dev/shm`) and apart from every other test's, which is what keeps the database tests from timing out and a timed-out test from hanging the run (their comments say why).
- Static analysis, as upstream CI runs it: `flutter analyze --no-fatal-infos`
- Rust check, as upstream CI runs it: `cargo check --manifest-path rust/Cargo.toml`
- Linux build: `flutter build linux --release` (about 8 minutes from cold). A build offers Dropbox as a Sync Location with or without a Dropbox app key. Without one, it asks for the key of the person's own Dropbox app before signing in; given one with `--dart-define=BLOOMEE_DROPBOX_APP_KEY=<key>` (the key is never committed), a build signs in through that app unless a key was entered on the Device. The Dropbox sign-in is kept in the desktop secret service (GNOME Keyring, KWallet), which must be running and unlocked.
- Run the build, from inside the shell (the app needs the shell's libmpv and `xdg-user-dir`): `build/linux/x64/release/bundle/bloomee`

The app keeps its library in `~/.local/share/ls.bloomee.musicplayer`, the same place as the official Bloomee installed on this machine. When an agent launches a build, it must point it at throwaway directories so the owner's real library is never opened:

```sh
d=$(mktemp -d); mkdir -p "$d"/{data,config,cache,Documents}
echo 'XDG_DOCUMENTS_DIR="$HOME/Documents"' > "$d/config/user-dirs.dirs"
HOME="$d" XDG_DATA_HOME="$d/data" XDG_CONFIG_HOME="$d/config" XDG_CACHE_HOME="$d/cache" \
  timeout 30 build/linux/x64/release/bundle/bloomee
```

### Two instances on one machine (trying Library Sync)

Each instance needs its own data directory, so that each is a separate Device with its own library; the Linux app allows several instances at once. These commands run from the repository root, in any shell (fish included), after a `flutter build linux --release`. Each keeps its instance under `~/bloomee-instances/<name>` (its library in `data/ls.bloomee.musicplayer`), separate from the real library and from the official Bloomee, and the instance survives between runs:

```sh
mkdir -p ~/bloomee-instances/sync-location
nix develop -c bash -c '
  d="$HOME/bloomee-instances/$1"; mkdir -p "$d"/{data,config,cache,Documents}
  echo "XDG_DOCUMENTS_DIR=\"\$HOME/Documents\"" > "$d/config/user-dirs.dirs"
  HOME="$d" XDG_DATA_HOME="$d/data" XDG_CONFIG_HOME="$d/config" XDG_CACHE_HOME="$d/cache" \
    exec build/linux/x64/release/bundle/bloomee' _ one
```

For the second instance, run the same command in another terminal with `_ two` instead of `_ one` at the end. In each, go through the first-run screens, then open Settings, Library Sync, give the Device a name, and turn sync on with `~/bloomee-instances/sync-location` as the local folder (the folder picker may open in the instance's own home, `~/bloomee-instances/<name>`: type or browse to the full path). To start an instance from scratch, close it and delete its directory (`rm -rf ~/bloomee-instances/one`). These persistent instances are for the owner; an agent launching the app uses the throwaway recipe above instead.

The libmpv player tests in `test/player_network_test.dart` skip unless `MPV_TEST_LIBRARY` points at a libmpv; upstream CI leaves it unset. The shell exports the path of its libmpv as `BLOOMEE_LIBMPV`, so to run them: `MPV_TEST_LIBRARY=$BLOOMEE_LIBMPV flutter test test/player_network_test.dart`.

A Linux build marks `rust_builder/cargokit/run_build_tool.sh` executable, which git reports as a mode change; undo it with `git checkout -- rust_builder/cargokit/run_build_tool.sh` before committing.
