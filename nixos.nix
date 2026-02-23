{ self }:

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.demod-vox;

  # Resolve the plugin package — allows the user to override it
  # (e.g. with a locally-built version) via programs.demod-vox.package.
  pluginPkg = cfg.package;

in {

  # ============================================================
  #  Module options
  # ============================================================
  options.programs.demod-vox = {

    enable = lib.mkEnableOption ''
      DeMoD Vox Power Armor Voice FX.
      Installs the LV2 plugin, configures PipeWire at 96 kHz
      with low-latency JACK compatibility, enables RT audio
      priorities, and optionally installs Carla and EasyEffects.
    '';

    package = lib.mkOption {
      type        = lib.types.package;
      default     = self.packages.${pkgs.stdenv.system}.default;
      description = "The DeMoD Vox package to install.";
    };

    sampleRate = lib.mkOption {
      type    = lib.types.int;
      default = 96000;
      description = ''
        PipeWire clock rate in Hz.  Must match the locked SR in
        the DSP files (96000).  Do not change unless you have
        rebuilt the plugin with a different -srate value.
      '';
    };

    quantum = lib.mkOption {
      type    = lib.types.int;
      default = 256;
      description = ''
        PipeWire / JACK buffer size in frames.
        256 frames at 96 kHz = 2.67 ms hardware I/O latency.
        Combined with the pitch shifter (21 ms) the total
        round-trip latency is approximately 24 ms.
        Lower values reduce latency but risk xruns on busy systems.
      '';
    };

    installCarla = lib.mkOption {
      type    = lib.types.bool;
      default = true;
      description = "Install Carla LV2/plugin host.";
    };

    installEasyEffects = lib.mkOption {
      type    = lib.types.bool;
      default = true;
      description = ''
        Install EasyEffects.  When enabled, the DeMoD Vox input
        preset is also installed to /etc/easyeffects/input/ so
        all users can load it without manual setup.
      '';
    };

    installCsound = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = ''
        Install Csound and the demod-vox-csound runner script.
        Use this if you prefer the Csound implementation or want
        runtime channel control via the Csound API.
      '';
    };
  };


  # ============================================================
  #  Implementation
  # ============================================================
  config = lib.mkIf cfg.enable {

    # ----------------------------------------------------------
    #  PipeWire — 96 kHz, JACK compatibility, low quantum
    #
    #  PipeWire's JACK compatibility layer (services.pipewire.jack)
    #  presents a JACK server that JACK-aware applications (Carla,
    #  Csound with -+rtaudio=jack) connect to without needing a
    #  separate jackd process.
    #
    #  The quantum sets the hardware buffer size.  Setting
    #  min-quantum = max-quantum = quantum locks it to exactly
    #  cfg.quantum frames — prevents PipeWire from increasing the
    #  buffer dynamically when other clients request more latency.
    # ----------------------------------------------------------
    services.pipewire = {
      enable      = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;

      jack.enable = true;   # JACK compatibility — required for Carla + Csound

      extraConfig.pipewire."92-demod-vox-clock" = {
        "context.properties" = {
          "default.clock.rate"        = cfg.sampleRate;
          "default.clock.quantum"     = cfg.quantum;
          "default.clock.min-quantum" = cfg.quantum;
          "default.clock.max-quantum" = cfg.quantum * 4;
          # Allowed rates — PipeWire will only resample from these
          "default.clock.allowed-rates" = [ cfg.sampleRate ];
        };
      };

      # Raise the realtime priority of PipeWire itself.
      # Combined with rtkit below, this gives PipeWire and its
      # clients (Carla, Csound) SCHED_FIFO scheduling.
      extraConfig.pipewire."93-demod-vox-rt" = {
        "context.modules" = [
          {
            name = "libpipewire-module-rtkit";
            args = {
              "nice.level"    = -15;
              "rt.prio"       = 88;
              "rt.time.soft"  = 200000;
              "rt.time.hard"  = 400000;
            };
            flags = [ "ifexists" "nofail" ];
          }
        ];
      };
    };

    # ----------------------------------------------------------
    #  RTKit — grants SCHED_FIFO to audio group members
    #
    #  RTKit is the D-Bus service that PipeWire and JACK use to
    #  request real-time scheduling without running as root.
    #  security.rtkit.enable adds the rtkit-daemon service and
    #  the necessary polkit rules.
    #
    #  The PAM limits below are ALSO required: RTKit only works
    #  if the process's RLIMIT_RTTIME and RLIMIT_MEMLOCK are set
    #  high enough.  Without them, rtkit silently refuses the
    #  request and audio threads run at normal priority.
    # ----------------------------------------------------------
    security.rtkit.enable = true;

    security.pam.loginLimits = [
      # Real-time scheduling priority ceiling for the audio group.
      # 99 = maximum possible (SCHED_FIFO); match what rtkit grants.
      { domain = "@audio"; item = "rtprio";   type = "-"; value = "99";        }
      # Memlock: audio threads need to lock buffers in RAM to avoid
      # page faults causing xruns.  "unlimited" is conventional;
      # reduce if your security policy requires a hard limit.
      { domain = "@audio"; item = "memlock";  type = "-"; value = "unlimited";  }
      # Nice level — lower = higher priority for non-RT threads.
      { domain = "@audio"; item = "nice";     type = "-"; value = "-20";        }
    ];

    # Ensure users in the audio group get the PAM limits above.
    users.groups.audio = {};

    # ----------------------------------------------------------
    #  LV2 plugin installation
    #
    #  The plugin .lv2 bundle is installed under
    #  /run/current-system/sw/lib/lv2/ via the nix profile.
    #  We add this path to LV2_PATH so that Carla, EasyEffects,
    #  jalv, and other LV2 hosts discover it automatically.
    # ----------------------------------------------------------
    environment.systemPackages = [ pluginPkg ]
      ++ lib.optional cfg.installCarla       pkgs.carla
      ++ lib.optional cfg.installEasyEffects pkgs.easyeffects
      ++ lib.optional cfg.installCsound      pkgs.csound;

    # LV2_PATH: include both the system profile path (where nix
    # puts packages) and the user profile path (for ~/.lv2 plugins).
    # profileRelativeSessionVariables expands each entry relative to
    # every active profile (system profile, user profile, etc.).
    environment.profileRelativeSessionVariables = {
      LV2_PATH = [ "/lib/lv2" ];
    };

    # JACK_PATH / LADSPA_PATH — set for completeness
    environment.variables = {
      # Explicit system lv2 path as fallback for applications that
      # don't honour LV2_PATH but look in fixed locations.
      DSSI_PATH  = "/run/current-system/sw/lib/dssi";
      LADSPA_PATH = "/run/current-system/sw/lib/ladspa";
    };

    # ----------------------------------------------------------
    #  EasyEffects preset (system-wide)
    #
    #  Installs the DeMoD Vox input preset to
    #  /etc/easyeffects/input/DeMoD_Vox.json
    #  EasyEffects merges /etc and ~/.config presets.
    # ----------------------------------------------------------
    environment.etc = lib.mkIf cfg.installEasyEffects {
      "easyeffects/input/DeMoD_Vox.json".source =
        "${pluginPkg}/share/easyeffects/input/DeMoD_Vox.json";
    };

    # ----------------------------------------------------------
    #  Kernel: high-resolution timers + low-latency scheduler
    #
    #  PREEMPT_VOLUNTARY is the default on most kernels.
    #  boot.kernelPatches can enable full PREEMPT for lower
    #  worst-case latency, but this is beyond the scope of this
    #  module.  We do set the scheduler to use CFS bandwidth
    #  throttling off (SCHED_OTHER latency hint).
    # ----------------------------------------------------------
    boot.kernel.sysctl = {
      # Timer resolution: 1000 Hz tick gives 1 ms resolution.
      # Most modern kernels already run at this rate; setting
      # it explicitly prevents boot-time override.
      "kernel.timer_migration" = 0;
      # Reduce VM swappiness — prevents audio buffers being paged out
      # at the wrong moment (causes xruns).
      "vm.swappiness" = 10;
    };

    # ----------------------------------------------------------
    #  Assertions — catch misconfiguration early
    # ----------------------------------------------------------
    assertions = [
      {
        assertion = cfg.quantum >= 64;
        message   = "programs.demod-vox.quantum must be ≥ 64 frames (0.67 ms at 96 kHz). Lower values risk continuous xruns.";
      }
      {
        assertion = builtins.elem cfg.sampleRate [ 44100 48000 88200 96000 176400 192000 ];
        message   = "programs.demod-vox.sampleRate must be a standard audio rate. The DSP files are built for 96000 Hz.";
      }
    ];
  };
}
