{
  description = "KOReader dev shell: emulator build/run on the PC, plus the Android SDK/NDK toolchain";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        androidComposition = pkgs.androidenv.composeAndroidPackages {
          cmdLineToolsVersion = "13.0";
          toolsVersion = "26.1.1";
          platformToolsVersion = "35.0.2";
          buildToolsVersions = [ "34.0.0" ];
          platformVersions = [ "30" "34" ];
          ndkVersions = [ "23.2.8568313" ];
          includeNDK = true;
          includeEmulator = false;
          includeSystemImages = false;
        };

        androidSdk = androidComposition.androidsdk;

        # KOReader's build prepends the NDK's own llvm toolchain bin/ to PATH
        # (see base/Makefile.defs ANDROID_TOOLCHAIN), which shadows the bare
        # `clang`/`clang++` names used both by meson's native (build-machine)
        # toolchain file and by LuaJIT's Makefile (which reuses $(HOSTCC) as
        # the base name for its cross $(CROSS)$(CC) compiler, so it must stay
        # a bare name). The NDK's plain `clang` isn't a nix-aware wrapper and
        # can't find glibc/crt objects under Nix (no /usr/include, /usr/lib).
        #
        # Fix at the root, without breaking cross-compilation: every
        # per-target script (aarch64-linux-android21-clang, etc.) invokes
        # `dirname $0`/clang, i.e. resolves "clang" relative to its own
        # directory, not via $PATH. So we rename the real compiler binary to
        # clang-ndk(++), repoint every per-target script at that new name
        # (sed, since they're tiny generated dispatcher scripts), and only
        # then repurpose the now-free "clang"/"clang++" names as forwarders
        # to nixpkgs' properly-wrapped clang for host/build-machine use.
        ndkPath = "${androidSdk}/libexec/android-sdk/ndk/23.2.8568313";
        patchedNdk = pkgs.runCommand "android-ndk-23.2.8568313-patched" { } ''
          mkdir -p "$out"
          cp -rs --no-preserve=mode "${ndkPath}/." "$out/"
          bin="$out/toolchains/llvm/prebuilt/linux-x86_64/bin"
          chmod -R u+w "$bin"

          ln -sf clang-12 "$bin/clang-ndk"
          ln -sf clang-ndk "$bin/clang-ndk++"

          for f in "$bin"/*-clang "$bin"/*-clang++; do
            case "$(basename "$f")" in
              clang | clang++) continue ;;
            esac
            # cp -rs turned these into symlinks into the read-only store;
            # materialize a real, writable copy before editing in place.
            content="$(cat "$f")"
            rm -f "$f"
            printf '%s\n' "$content" > "$f"
            chmod +x "$f"
            sed -i -e 's#/clang++#/clang-ndk++#g' -e 's#/clang #/clang-ndk #g' -e 's#/clang"#/clang-ndk"#g' "$f"
          done

          for name in clang clang++; do
            rm -f "$bin/$name"
            cat > "$bin/$name" <<EOF
          #!/bin/sh
          exec ${pkgs.clang}/bin/$name "\$@"
          EOF
            chmod +x "$bin/$name"
          done
        '';
        # Everything ./kodev needs to build & run the emulator target.
        commonPackages = with pkgs; [
          autoconf
          automake
          cmake
          gcc
          clang
          gettext
          git
          gnumake
          gnupatch
          libtool
          meson
          nasm
          ninja
          perl
          pkg-config
          python3
          sdl3
          unzip
          wget
          ccache
          gdb
          # lpeg lets a plain luajit compile the .moon sources of the
          # custom_plugins outside of KOReader (moonscript's parser needs it).
          (luajit.withPackages (ps: [ ps.lpeg ]))
          luajitPackages.luacheck
          p7zip
          shellcheck
          shfmt
        ];

        androidPackages = with pkgs; [
          androidSdk
          jdk17
          gradle
          android-tools
        ];

        # base/thirdparty/cmake_modules/koreader_thirdparty_common.cmake matches
        # the literal string "libraries: =" in `$CC -print-search-dirs` output.
        # gcc translates that label, so under a non-English locale configure
        # dies with "could not find compiler search paths for libraries".
        # LC_MESSAGES alone keeps the user's collation and encoding intact.
        commonEnv = ''
          export LC_MESSAGES=C
          export LD_LIBRARY_PATH=${pkgs.sdl3}/lib:$LD_LIBRARY_PATH
        '';

        # KOReader bundles its own FreeType and HarfBuzz and dlopen()s them from
        # libs/. Under Wayland, SDL3 loads libdecor for client-side decorations,
        # whose GTK plugin drags in pango and therefore a *second*, complete
        # HarfBuzz from the store. The two interpose, so an object allocated by
        # one implementation is reallocated by the other and glibc aborts with
        # "corrupted size vs. prev_size" while the font list is being built.
        #
        # The X11 backend needs none of that (the window manager draws the
        # decorations), so a single HarfBuzz stays in the process. KOReader
        # already forces this driver on another desktop for its own reasons, see
        # base/ffi/SDL3.lua. XWayland handles it on a Wayland session; set
        # SDL_VIDEODRIVER yourself to override.
        #
        # Do NOT "fix" this by putting the build's libs/ on LD_LIBRARY_PATH: it
        # cures the crash but shadows the system HarfBuzz and SQLite for every
        # other library in the process, and libdecor then fails to load its
        # plugins ("undefined symbol: hb_ot_color_has_layers") — leaving a
        # window that exists but is never displayed.
        emulatorEnv = ''
          export SDL_VIDEODRIVER="''${SDL_VIDEODRIVER:-x11}"
        '';

        androidEnv = ''
          export ANDROID_HOME=${androidSdk}/libexec/android-sdk
          export ANDROID_SDK_ROOT=$ANDROID_HOME
          export ANDROID_NDK_HOME=${patchedNdk}
          export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
          export JAVA_HOME=${pkgs.jdk17}
          export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/34.0.0/aapt2"
        '';

        # `nix run` helpers: they drive ./kodev from the repository root, so
        # they must be started from within a checkout (there is no pure
        # derivation building KOReader — ./kodev downloads thirdparty sources
        # at build time, which a sandboxed build cannot do).
        kodevApp = name: args: pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = commonPackages;
          text = ''
            ${commonEnv}
            if [ ! -x ./kodev ]; then
              echo "$0: run me from a KOReader checkout (no ./kodev here)" >&2
              exit 1
            fi
            ${emulatorEnv}
            exec ./kodev ${args} "$@"
          '';
        };

        # Same as kodevApp, but also asks the Makefile to merge
        # custom_plugins/*.koplugin into the emulator's plugin directory
        # (see Makefile's "Install plugins" step).
        kodevAppCustomPlugins = name: args: pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = commonPackages;
          text = ''
            ${commonEnv}
            if [ ! -x ./kodev ]; then
              echo "$0: run me from a KOReader checkout (no ./kodev here)" >&2
              exit 1
            fi
            ${emulatorEnv}
            export CUSTOM_PLUGINS=1
            exec ./kodev ${args} "$@"
          '';
        };

        # Checks vatican.koplugin against the live site, which the offline unit
        # tests deliberately cannot do. Needs an emulator build (nix run .#build).
        vaticanSmoke = pkgs.writeShellApplication {
          name = "vatican-smoke";
          runtimeInputs = commonPackages;
          text = ''
            ${commonEnv}
            ${emulatorEnv}
            emulator=(./koreader-emulator-*/koreader)
            if [ ! -x "''${emulator[0]}/luajit" ]; then
              echo "$0: no emulator build found — run 'nix run .#build' first" >&2
              exit 1
            fi
            cd "''${emulator[0]}"
            exec ./luajit ../../custom_plugins/vatican.koplugin/smoketest.lua "$@"
          '';
        };

        # Downloads the real divinum-officium data and generates a real 1962
        # office end-to-end through the actual plugin code (not the busted
        # test harness). Needs an emulator build (nix run .#build) and network.
        breviariumSmoke = pkgs.writeShellApplication {
          name = "breviarium-smoke";
          runtimeInputs = commonPackages;
          text = ''
            ${commonEnv}
            ${emulatorEnv}
            emulator=(./koreader-emulator-*/koreader)
            if [ ! -x "''${emulator[0]}/luajit" ]; then
              echo "$0: no emulator build found — run 'nix run .#build' first" >&2
              exit 1
            fi
            cd "''${emulator[0]}"
            exec ./luajit ../../custom_plugins/breviarium.koplugin/smoketest.lua "$@"
          '';
        };

        # Throwaway verification tool (not shipped): loops over a year of
        # dates and writes the port's own rendered HTML per day/hora, via
        # the real plugin code. Controlled by env vars (GENCORPUS_YEAR,
        # GENCORPUS_OUTDIR, GENCORPUS_ONLY_DATE, GENCORPUS_FROM_DATE -- see
        # custom_plugins/breviarium.koplugin/gencorpus.lua's own header).
        # Needs an emulator build (nix run .#build) and network.
        breviariumGencorpus = pkgs.writeShellApplication {
          name = "breviarium-gencorpus";
          runtimeInputs = commonPackages;
          text = ''
            ${commonEnv}
            ${emulatorEnv}
            emulator=(./koreader-emulator-*/koreader)
            if [ ! -x "''${emulator[0]}/luajit" ]; then
              echo "$0: no emulator build found — run 'nix run .#build' first" >&2
              exit 1
            fi
            cd "''${emulator[0]}"
            exec ./luajit ../../custom_plugins/breviarium.koplugin/gencorpus.lua "$@"
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = commonPackages ++ androidPackages;
          shellHook = commonEnv + emulatorEnv + androidEnv;
        };

        apps = {
          build = {
            type = "app";
            program = "${kodevApp "koreader-build" "build"}/bin/koreader-build";
          };
          run = {
            type = "app";
            program = "${kodevApp "koreader-run" "run"}/bin/koreader-run";
          };
          run-custom-plugins = {
            type = "app";
            program = "${kodevAppCustomPlugins "koreader-run-custom-plugins" "run"}/bin/koreader-run-custom-plugins";
          };
          test = {
            type = "app";
            program = "${kodevApp "koreader-test" "test"}/bin/koreader-test";
          };
          vatican-smoke = {
            type = "app";
            program = "${vaticanSmoke}/bin/vatican-smoke";
          };
          breviarium-smoke = {
            type = "app";
            program = "${breviariumSmoke}/bin/breviarium-smoke";
          };
          breviarium-gencorpus = {
            type = "app";
            program = "${breviariumGencorpus}/bin/breviarium-gencorpus";
          };
          default = self.apps.${system}.run;
        };
      });
}
