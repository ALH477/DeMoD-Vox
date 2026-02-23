{
  description = ''
    DeMoD Vox — Power Armor Voice FX
    LV2 plugin (Faust) + Csound instrument, for Carla and
    EasyEffects over PipeWire/JACK on NixOS.

    Usage in flake.nix:
      inputs.demod-vox.url = "github:ALH477/DeMoD-Vox";

    NixOS module:
      imports = [ demod-vox.nixosModules.default ];
      programs.demod-vox.enable = true;

    Home Manager module:
      imports = [ demod-vox.homeManagerModules.default ];
      programs.demod-vox.enable = true;
  '';

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:

    # Per-system outputs (packages, devShells, checks)
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # --------------------------------------------------------
        #  LV2 plugin — compiled from DeMoD_Vox.dsp via faust2lv2
        #
        #  Build flags:
        #    -srate 96000   → locks SR at compile time, folds the
        #                     sr_ok guard to a no-op multiply by 1.0
        #    -vec -vs 32    → Faust auto-vectorisation (SIMD)
        #    -dfs           → deep-first-search scheduling — better
        #                     cache locality for the sequential chain
        #    -O3 -ffast-math → compiler speed optimisations (passed
        #                     through faust2lv2 to g++)
        #
        #  LV2 URI (check generated manifest.ttl to confirm):
        #    https://faustlv2.grame.fr/DeMoD_Vox
        # --------------------------------------------------------
        demod-vox-lv2 = pkgs.stdenv.mkDerivation {
          pname   = "demod-vox";
          version = "1.0.0";

          src = self;   # the flake repo is the source

          nativeBuildInputs = with pkgs; [
            faust         # provides faust compiler + faust2lv2 script
            pkg-config    # needed by faust2lv2 to locate lv2 headers
            gcc           # C++ compiler called by faust2lv2
          ];

          buildInputs = with pkgs; [
            lv2           # LV2 headers — pulled in via pkg-config
          ];

          buildPhase = ''
            runHook preBuild

            # faust2lv2 is a bash script that:
            #   1. Calls faust -lang cpp -a lv2.cpp ... to produce C++
            #   2. Calls g++ to compile the shared library
            #   3. Assembles the .lv2 bundle and generates manifest.ttl
            #
            # nativeBuildInputs puts faust, g++, and pkg-config into PATH.
            # PKG_CONFIG_PATH is set by Nix from buildInputs automatically.

            faust2lv2 \
              -srate 96000 \
              -vec -vs 32 -dfs \
              DeMoD_Vox.dsp

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/lv2
            cp -r DeMoD_Vox.lv2 $out/lib/lv2/

            # Install Csound CSD alongside the LV2 bundle for users
            # who prefer the Csound route (lower baseline latency,
            # more flexible runtime control via channels).
            mkdir -p $out/share/demod-vox
            cp DeMoD_Vox.csd $out/share/demod-vox/

            # Install EasyEffects preset
            mkdir -p $out/share/easyeffects/input
            cp easyeffects/DeMoD_Vox_input.json \
              $out/share/easyeffects/input/DeMoD_Vox.json

            # Install a Csound runner script that connects over JACK/PipeWire
            mkdir -p $out/bin
            cat > $out/bin/demod-vox-csound << 'EOF'
            #!/usr/bin/env bash
            # DeMoD Vox — launch Csound instrument over JACK/PipeWire
            # Usage: demod-vox-csound [csound options]
            #   -b 256  = 2.67 ms hardware buffer at 96 kHz (default)
            #   JACK must be running (PipeWire-JACK is fine)
            exec csound \
              -+rtaudio=jack \
              -+rtmidi=null \
              -odac \
              -iadc \
              -b 256 \
              -B 512 \
              -m 0 \
              "@{DEMOD_VOX_CSD:-@out@/share/demod-vox/DeMoD_Vox.csd}" \
              "$@"
            EOF
            # Patch the @out@ placeholder to the actual store path
            sed -i "s|@out@|$out|g" $out/bin/demod-vox-csound
            chmod +x $out/bin/demod-vox-csound

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description  = "Power Armor Voice FX — LV2 plugin and Csound instrument";
            homepage     = "https://github.com/ALH477/DeMoD-Vox";
            license      = licenses.mit;
            maintainers  = [ ];
            platforms    = platforms.linux;
          };
        };

      in {
        # --------------------------------------------------------
        #  Packages
        # --------------------------------------------------------
        packages = {
          default   = demod-vox-lv2;
          demod-vox = demod-vox-lv2;
        };

        # --------------------------------------------------------
        #  Development shell
        #  nix develop — drops you into an environment with
        #  everything needed to iterate on the DSP files.
        # --------------------------------------------------------
        devShells.default = pkgs.mkShell {
          name = "demod-vox-dev";

          packages = with pkgs; [
            # DSP toolchain
            faust           # Faust compiler + faust2lv2
            csound          # Csound runtime
            pkg-config
            gcc

            # Audio host / monitoring
            carla           # LV2 host — test the built plugin
            easyeffects     # PipeWire effects host

            # Plugin headers and tools
            lv2
            jalv            # minimal LV2 host for quick CLI testing

            # Debugging
            lv2lint         # LV2 plugin linter
            serd            # Turtle (TTL) parser for inspecting manifests
          ];

          shellHook = ''
            echo "DeMoD Vox dev shell"
            echo ""
            echo "Build LV2:"
            echo "  faust2lv2 -srate 96000 -vec -vs 32 -dfs DeMoD_Vox.dsp"
            echo "  cp -r DeMoD_Vox.lv2 ~/.lv2/"
            echo ""
            echo "Check LV2 URI (after build):"
            echo "  cat DeMoD_Vox.lv2/manifest.ttl | grep 'lv2:Plugin'"
            echo ""
            echo "Test with jalv:"
            echo "  jalv.gtk https://faustlv2.grame.fr/DeMoD_Vox"
            echo ""
            echo "Run Csound standalone:"
            echo "  csound -+rtaudio=jack -odac -iadc -b256 -B512 DeMoD_Vox.csd"
            echo ""

            # Set LV2_PATH so Carla/EasyEffects find locally-built plugins
            export LV2_PATH="$PWD:''${LV2_PATH:-/run/current-system/sw/lib/lv2}"
          '';
        };

        # --------------------------------------------------------
        #  Checks (run with: nix flake check)
        # --------------------------------------------------------
        checks = {
          # Verify the LV2 bundle was built and contains expected files
          bundle-structure = pkgs.runCommand "check-bundle-structure" {
            plugin = demod-vox-lv2;
          } ''
            test -f $plugin/lib/lv2/DeMoD_Vox.lv2/DeMoD_Vox.so     || exit 1
            test -f $plugin/lib/lv2/DeMoD_Vox.lv2/manifest.ttl      || exit 1
            test -f $plugin/share/demod-vox/DeMoD_Vox.csd            || exit 1
            test -f $plugin/share/easyeffects/input/DeMoD_Vox.json   || exit 1
            test -x $plugin/bin/demod-vox-csound                      || exit 1
            echo "Bundle structure OK" > $out
          '';
        };
      }
    )

    # --------------------------------------------------------
    #  System-level outputs (not per-system)
    # --------------------------------------------------------
    // {
      # NixOS module — system-wide config
      nixosModules.default = import ./modules/nixos.nix { inherit self; };

      # Home Manager module — per-user config
      homeManagerModules.default = import ./modules/home-manager.nix { inherit self; };
    };
}
