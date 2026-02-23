{ self }:

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.demod-vox;
  pluginPkg = cfg.package;

in {

  # ============================================================
  #  Module options
  # ============================================================
  options.programs.demod-vox = {

    enable = lib.mkEnableOption ''
      DeMoD Vox Power Armor Voice FX (per-user Home Manager config).
      Installs the LV2 plugin to the user profile, sets LV2_PATH,
      and optionally installs an EasyEffects input preset.

      NOTE: For system-wide PipeWire + RT configuration, use the
      NixOS module (nixosModules.default) in addition to or instead
      of this module.  This HM module only handles per-user files
      and environment — it cannot set PAM limits or kernel sysctl.
    '';

    package = lib.mkOption {
      type        = lib.types.package;
      default     = self.packages.${pkgs.stdenv.system}.default;
      description = "The DeMoD Vox package to install.";
    };

    installEasyEffectsPreset = lib.mkOption {
      type    = lib.types.bool;
      default = true;
      description = ''
        Install the DeMoD Vox input preset to
        ~/.config/easyeffects/input/DeMoD_Vox.json.
        EasyEffects will list it in the presets dropdown.
      '';
    };

    installCarla = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = "Install Carla to the user profile.";
    };

    installEasyEffects = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = "Install EasyEffects to the user profile.";
    };

    installCsound = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = ''
        Install Csound and the demod-vox-csound runner to the
        user profile.
      '';
    };

    # Carla session config: optional drop-in for users who want
    # a pre-configured Carla rack with DeMoD Vox ready to load.
    installCarlaSession = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = ''
        Install a Carla rack session file to
        ~/.config/rncbc.org/Carla/DeMoD_Vox.carxs
        with the DeMoD Vox LV2 pre-loaded.
        Requires installCarla = true.
      '';
    };
  };


  # ============================================================
  #  Implementation
  # ============================================================
  config = lib.mkIf cfg.enable {

    # ----------------------------------------------------------
    #  Packages — user profile
    # ----------------------------------------------------------
    home.packages = [ pluginPkg ]
      ++ lib.optional cfg.installCarla        pkgs.carla
      ++ lib.optional cfg.installEasyEffects  pkgs.easyeffects
      ++ lib.optional cfg.installCsound       pkgs.csound;

    # ----------------------------------------------------------
    #  LV2_PATH — include the user profile's lv2 directory
    #
    #  When the plugin package is in home.packages, Nix links
    #  it into ~/.nix-profile/lib/lv2/.  We add that to
    #  LV2_PATH so Carla and EasyEffects discover it.
    #
    #  We also preserve any existing LV2_PATH entries so that
    #  other installed LV2 plugins remain visible.
    # ----------------------------------------------------------
    home.sessionVariables = {
      LV2_PATH = lib.concatStringsSep ":" [
        "${config.home.profileDirectory}/lib/lv2"   # user profile LV2s
        "/run/current-system/sw/lib/lv2"            # system LV2s (NixOS)
        "\${LV2_PATH:-}"                             # pre-existing entries
      ];
    };

    # ----------------------------------------------------------
    #  EasyEffects input preset
    #
    #  EasyEffects looks for input presets (microphone effects)
    #  in ~/.config/easyeffects/input/.  The preset references
    #  the LV2 plugin by URI — the URI must match what is in the
    #  built plugin's manifest.ttl.
    #
    #  DEFAULT URI from faust2lv2: https://faustlv2.grame.fr/DeMoD_Vox
    #  To confirm: cat ~/.lv2/DeMoD_Vox.lv2/manifest.ttl | grep Plugin
    # ----------------------------------------------------------
    xdg.configFile."easyeffects/input/DeMoD_Vox.json" =
      lib.mkIf cfg.installEasyEffectsPreset {
        source = "${pluginPkg}/share/easyeffects/input/DeMoD_Vox.json";
      };

    # ----------------------------------------------------------
    #  Carla session file (optional)
    #
    #  A minimal Carla rack XML session with DeMoD Vox LV2
    #  pre-loaded.  Open in Carla: File → Open Session.
    # ----------------------------------------------------------
    xdg.configFile."rncbc.org/Carla/DeMoD_Vox.carxs" =
      lib.mkIf (cfg.installCarlaSession && cfg.installCarla) {
        text = ''
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE CARLA-PROJECT>
          <CARLA-PROJECT VERSION="2.0">
           <EngineNode NAME="PipeWire" DRIVER="JACK"
             SAMPLE_RATE="${toString 96000}"
             BUFFER_SIZE="256"/>
           <Plugin>
            <Info>
             <Type>LV2</Type>
             <Name>DeMoD Vox</Name>
             <URI>https://faustlv2.grame.fr/DeMoD_Vox</URI>
            </Info>
            <Data>
             <Active>Yes</Active>
             <Volume>1.0</Volume>
             <DryWet>1.0</DryWet>
             <Balance-Left>-1.0</Balance-Left>
             <Balance-Right>1.0</Balance-Right>
            </Data>
           </Plugin>
          </CARLA-PROJECT>
        '';
      };
  };
}
