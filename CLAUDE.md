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
- Run the whole suite: `flutter test --no-pub` (as in `CONTRIBUTING.md`). It takes under 2 minutes; the database tests occasionally time out and then hang the run (see the baseline in `.scratch/library-sync/issues/01-build-from-source-on-nixos.md`), so an agent should wrap it: `timeout 900 flutter test --no-pub`
- Static analysis, as upstream CI runs it: `flutter analyze --no-fatal-infos`
- Rust check, as upstream CI runs it: `cargo check --manifest-path rust/Cargo.toml`
- Linux build: `flutter build linux --release` (about 8 minutes from cold)
- Run the build, from inside the shell (the app needs the shell's libmpv and `xdg-user-dir`): `build/linux/x64/release/bundle/bloomee`

The app keeps its library in `~/.local/share/ls.bloomee.musicplayer`, the same place as the official Bloomee installed on this machine. When an agent launches a build, it must point it at throwaway directories so the owner's real library is never opened:

```sh
d=$(mktemp -d); mkdir -p "$d"/{data,config,cache,Documents}
echo 'XDG_DOCUMENTS_DIR="$HOME/Documents"' > "$d/config/user-dirs.dirs"
HOME="$d" XDG_DATA_HOME="$d/data" XDG_CONFIG_HOME="$d/config" XDG_CACHE_HOME="$d/cache" \
  timeout 30 build/linux/x64/release/bundle/bloomee
```

The libmpv player tests in `test/player_network_test.dart` skip unless `MPV_TEST_LIBRARY` points at a libmpv; upstream CI leaves it unset. The shell exports the path of its libmpv as `BLOOMEE_LIBMPV`, so to run them: `MPV_TEST_LIBRARY=$BLOOMEE_LIBMPV flutter test test/player_network_test.dart`.

A Linux build marks `rust_builder/cargokit/run_build_tool.sh` executable, which git reports as a mode change; undo it with `git checkout -- rust_builder/cargokit/run_build_tool.sh` before committing.
