# Fork-only: development environment for building and testing Bloomee on NixOS.
# Not part of upstream; keep it out of upstream pull requests.
#
# Enter it with `nix develop` from the repository root. See CLAUDE.md.
{
  description = "Bloomee development environment (NixOS, Linux desktop)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;
      libmpv = pkgs.mpv-unwrapped;

      # nixpkgs only packages Flutter 3.47.4; upstream CI pins 3.47.7
      # (FLUTTER_VERSION in .github/workflows/main.yml). nix/flutter-3.47.7.json
      # was generated with nixpkgs' own flutter update script
      # (pkgs/development/compilers/flutter/update/update.py --version 3.47.7),
      # restricted to x86_64-linux and the "linux" + "universal" artifacts.
      flutterNixpkgsDir = "${nixpkgs}/pkgs/development/compilers/flutter";
      # Same patch selection as nixpkgs' flutter/default.nix (getPatches).
      patchesIn = dir: map (file: "${dir}/${file}") (builtins.attrNames (builtins.readDir dir));
      flutterUnwrapped = pkgs.flutterPackages.mkFlutter (
        lib.importJSON ./nix/flutter-3.47.7.json
        // {
          patches =
            patchesIn "${flutterNixpkgsDir}/patches" ++ patchesIn "${flutterNixpkgsDir}/versions/3_47/patches";
        }
      );
      flutter = (pkgs.flutterPackages.wrapFlutter flutterUnwrapped).override {
        supportedTargetFlutterPlatforms = [
          "universal"
          "linux"
        ];
        # media_kit_libs_linux builds against libmpv; flutter_secure_storage
        # (Library Sync's credentials) against libsecret.
        extraPkgConfigPackages = [
          libmpv
          pkgs.libsecret
        ];
      };

      # Cargokit (rust_builder/) drives cargo through `rustup run stable cargo`,
      # and without rustup on PATH it looks for precompiled binaries that this
      # crate does not publish. This stand-in answers the three rustup calls
      # Cargokit makes with the nixpkgs Rust toolchain below, which stands for
      # "stable"; any other toolchain or rustup command is refused.
      rustTarget = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      rustupShim = pkgs.writeShellScriptBin "rustup" ''
        case "$*" in
          "toolchain list") echo "stable-${rustTarget} (default)" ;;
          "target list --toolchain stable --installed" | \
          "target list --toolchain stable-${rustTarget} --installed") echo "${rustTarget}" ;;
          "run stable "*) shift 2; exec "$@" ;;
          *)
            echo "rustup stand-in (flake.nix): unsupported: rustup $*" >&2
            exit 1
            ;;
        esac
      '';

      # What the built app needs at run time without linking against it:
      # media_kit opens libmpv by name, and path_provider asks `xdg-user-dir`
      # for the documents directory (startup fails without either).
      runtimeLibraries = [ libmpv ];
      runtimeTools = [ pkgs.xdg-user-dirs ];
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          flutter
          pkgs.cargo
          pkgs.rustc
          pkgs.clippy
          pkgs.rustfmt
          rustupShim
        ]
        ++ runtimeTools;

        LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibraries;
        # For opting in to the libmpv player tests: MPV_TEST_LIBRARY=$BLOOMEE_LIBMPV.
        BLOOMEE_LIBMPV = "${libmpv}/lib/libmpv.so";

        # Database code running in worker isolates opens Isar Core by bare name
        # (libisar.so), so the tests need the locked isar_community_flutter_libs
        # binary on the library path, as upstream CI sets up in checkout.yml.
        # The path is read from pubspec.lock when the shell starts; re-enter the
        # shell after a `flutter pub get` that changes the Isar version.
        shellHook = ''
          isar_version=$(awk '/^  isar_community_flutter_libs:/ { found = 1 }
            found && /^    version:/ { gsub(/"/, "", $2); print $2; exit }' ${./pubspec.lock})
          isar_dir="''${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev/isar_community_flutter_libs-$isar_version/linux"
          export LD_LIBRARY_PATH="$isar_dir:$LD_LIBRARY_PATH"
          if [ -z "$isar_version" ] || [ ! -f "$isar_dir/libisar.so" ]; then
            echo "warning: $isar_dir/libisar.so not found; database tests will fail." >&2
            echo "         Run 'flutter pub get --enforce-lockfile', then re-enter the shell." >&2
          fi
          echo "Bloomee dev shell: Flutter ${flutter.version}, Rust ${pkgs.rustc.version}" >&2
        '';
      };
    };
}
