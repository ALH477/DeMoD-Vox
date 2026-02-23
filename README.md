# DeMoD Vox

**Power armor voice FX — LV2 (Faust) + Csound instrument for Linux.**

Transforms a microphone input into a sealed-helmet, vox-unit voice. Granular pitch shifting, bass shelf boost, bitcrusher, ring modulator, helmet echo, compressor, and TPDF-dithered output to 16/20/24-bit at a locked 96 kHz sample rate.

Packaged as a Nix flake with NixOS and Home Manager modules for one-command setup with Carla and EasyEffects over PipeWire/JACK.

---

## ⚠ Latency

Total round-trip latency (plugin processing + hardware buffer):

| Source | Frames | Time @ 96 kHz |
|---|---|---|
| Pitch shifter (Faust `ef.transpose`, window=2048) | 2048 | **~21 ms** |
| Pitch shifter (Csound PVS, ifftsize=2048) | 2048 | **~21 ms** |
| PipeWire hardware buffer (default quantum=256) | 256 | ~2.7 ms |
| **Total (typical)** | | **~24 ms** |

Latency is **constant at all semitone values, including 0** — the pitch engine always runs. In a DAW, compensate by advancing the recorded output forward by ~21 ms, or use manual plugin delay compensation.

---

## I/O Specification (Locked)

| Property | Value |
|---|---|
| **Sample rate** | **96 000 Hz** — host must match |
| **Input** | 32-bit float (LV2 audio port) |
| **Output depth** | 16-bit default · 20-bit · 24-bit selectable |
| **Channels** | Mono in → Mono out |

---

## Signal Chain

```
IN (32f, 96 kHz)
  → [Pitch Shift]          0 to −12 semitones  (21 ms latency)
  → [HPF] → [LPF] → [Mid Peak EQ]
  → [Bitcrusher / Downsample]
  → [Ring Modulator]
  → [Helmet Echo]
  → [Bass Boost]           1st-order low shelf
  → [Compressor]
  → [Output Gain]
  → [Hard Clip ±1.0]
  → [TPDF Dither + Word-Length Reduction (16/20/24-bit)]
  → [SR Guard × 1.0 or × 0.0]
  → OUT
```

---

## Files

```
DeMoD-Vox/
├── flake.nix                        Nix flake — packages, modules, devShell
├── modules/
│   ├── nixos.nix                    NixOS module  (system-wide)
│   └── home-manager.nix             Home Manager module (per-user)
├── easyeffects/
│   └── DeMoD_Vox_input.json         EasyEffects input preset
├── DeMoD_Vox.dsp                    Faust source → LV2 / LADSPA
├── DeMoD_Vox.csd                    Csound source → standalone / csound-lv2
├── LICENSE                          MIT
└── README.md
```

---

## Quick Start — NixOS + Home Manager

### 1. Add the flake input

In your system `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    demod-vox.url   = "github:ALH477/DeMoD-Vox";
  };

  outputs = { self, nixpkgs, home-manager, demod-vox, ... }: {
    nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix
        demod-vox.nixosModules.default
        home-manager.nixosModules.home-manager
        {
          home-manager.users.youruser = {
            imports = [ demod-vox.homeManagerModules.default ];
          };
        }
      ];
    };
  };
}
```

### 2. Enable in `configuration.nix`

```nix
# System-wide: PipeWire at 96 kHz + JACK + RT priorities + Carla
programs.demod-vox = {
  enable              = true;
  quantum             = 256;      # 2.67 ms @ 96 kHz
  installCarla        = true;
  installEasyEffects  = true;
};
```

### 3. Enable in your Home Manager config

```nix
# Per-user: LV2_PATH, EasyEffects preset, optional Carla session
programs.demod-vox = {
  enable                    = true;
  installEasyEffectsPreset  = true;
  installCarlaSession       = true;   # pre-loads plugin in Carla
  installCarla              = true;
};
```

### 4. Rebuild

```bash
sudo nixos-rebuild switch --flake .#mymachine
```

The plugin is now discoverable by Carla and EasyEffects. PipeWire is running at 96 kHz with JACK compatibility and RT priorities.

---

## What the Nix Module Does

### NixOS module (`programs.demod-vox.enable = true`)

| What | How |
|---|---|
| Installs LV2 plugin | `environment.systemPackages` → `/run/current-system/sw/lib/lv2/` |
| Sets `LV2_PATH` | `profileRelativeSessionVariables` → includes system + user profile lv2 dirs |
| PipeWire at 96 kHz | `services.pipewire.extraConfig` → clock rate, quantum, min/max quantum |
| JACK compatibility | `services.pipewire.jack.enable = true` |
| RT priorities | `security.rtkit.enable` + `security.pam.loginLimits` for `@audio` group |
| VM settings | `vm.swappiness = 10`, `kernel.timer_migration = 0` |
| Installs Carla | optional — `installCarla = true` |
| Installs EasyEffects | optional — preset in `/etc/easyeffects/input/` |

### Home Manager module (`programs.demod-vox.enable = true`)

| What | How |
|---|---|
| LV2 to user profile | `home.packages` → `~/.nix-profile/lib/lv2/` |
| `LV2_PATH` session var | `home.sessionVariables` — covers user + system profile paths |
| EasyEffects preset | `xdg.configFile."easyeffects/input/DeMoD_Vox.json"` |
| Carla session | `xdg.configFile."rncbc.org/Carla/DeMoD_Vox.carxs"` |

---

## Manual Build (without Nix)

### Faust → LV2

`-vec -vs 32 -dfs` enables SIMD vectorisation and loop scheduling for lower CPU overhead:

```bash
faust2lv2 -srate 96000 -vec -vs 32 -dfs DeMoD_Vox.dsp
cp -r DeMoD_Vox.lv2 ~/.lv2/

# Verify URI (needed for EasyEffects preset):
cat DeMoD_Vox.lv2/manifest.ttl | grep 'lv2:Plugin'
```

### Faust → LADSPA (fallback)

```bash
faust2ladspa -srate 96000 -vec -vs 32 DeMoD_Vox.dsp
cp DeMoD_Vox.so ~/.ladspa/
```

### Faust → JACK standalone

```bash
faust2jack -srate 96000 -vec -vs 32 DeMoD_Vox.dsp && ./DeMoD_Vox
```

### Csound → JACK (PipeWire compatible)

```bash
csound -+rtaudio=jack -+rtmidi=null \
       -odac -iadc -b256 -B512 \
       DeMoD_Vox.csd
```

At 96 kHz, `-b256` = 2.67 ms per period. PipeWire-JACK handles the connection — no separate `jackd` needed.

### Csound → ALSA

```bash
csound -+rtaudio=alsa -odac0 -iadc0 \
       -b512 -B2048 DeMoD_Vox.csd
```

---

## Using with Carla

1. Start Carla — it connects to PipeWire-JACK automatically.
2. **Add Plugin** → scan LV2 → search **DeMoD Vox**. If it doesn't appear:
   ```bash
   echo $LV2_PATH          # check path is set
   ls $LV2_PATH            # check plugin bundle exists
   cat ~/.lv2/DeMoD_Vox.lv2/manifest.ttl   # check URI
   ```
3. Connect your microphone input to the plugin input port in the Carla patchbay.
4. Connect the plugin output to your monitor / recording output.
5. Adjust parameters in the plugin GUI or via OSC automation.

**Carla sample rate must be 96000.** Set in Carla: **Settings → Configure Carla → Engine → Sample Rate → 96000**.

---

## Using with EasyEffects

EasyEffects applies effects to the system microphone input (or output). DeMoD Vox works as a **microphone (input device) effect**.

1. Open EasyEffects → **Input** tab.
2. Click **Presets** → **Import** → select the installed `DeMoD_Vox.json`, or use the system/HM module which installs it automatically.
3. Click **Load** to apply.
4. The plugin appears in the effects chain. Enable it with the toggle.

**If the plugin doesn't appear in the effects list:**

```bash
# Check LV2_PATH is set
echo $LV2_PATH

# Check EasyEffects can see the plugin
easyeffects --lv2-dump 2>&1 | grep -i demod

# Verify the URI in the preset matches the built plugin
cat ~/.config/easyeffects/input/DeMoD_Vox.json | grep '"lv2#'
cat ~/.lv2/DeMoD_Vox.lv2/manifest.ttl | grep 'a lv2:Plugin'
# Update the URI in DeMoD_Vox.json if they differ.
```

**EasyEffects needs PipeWire.** It does not work with standalone JACK. The NixOS module configures this correctly.

---

## PipeWire / JACK Manual Configuration

If not using the NixOS module, configure PipeWire manually:

```bash
# /etc/pipewire/pipewire.conf.d/92-demod-vox.conf
context.properties = {
    default.clock.rate        = 96000
    default.clock.quantum     = 256
    default.clock.min-quantum = 256
    default.clock.max-quantum = 1024
    default.clock.allowed-rates = [ 96000 ]
}
```

```bash
systemctl --user restart pipewire pipewire-pulse wireplumber
# Verify:
pw-cli info 0 | grep -E 'rate|quantum'
```

For real-time priorities without the NixOS module:

```bash
# /etc/security/limits.d/99-audio.conf
@audio  -  rtprio   99
@audio  -  memlock  unlimited
@audio  -  nice     -20

# Add yourself to the audio group:
sudo usermod -aG audio $USER
```

---

## Development Shell

```bash
nix develop github:ALH477/DeMoD-Vox

# Or from a local clone:
git clone https://github.com/ALH477/DeMoD-Vox
cd DeMoD-Vox
nix develop
```

The dev shell includes: `faust`, `csound`, `carla`, `easyeffects`, `jalv`, `lv2lint`, `pkg-config`.

```bash
# Quick test with jalv (minimal LV2 host):
faust2lv2 -srate 96000 -vec -vs 32 -dfs DeMoD_Vox.dsp
jalv.gtk https://faustlv2.grame.fr/DeMoD_Vox

# Lint the LV2 bundle:
lv2lint -s lv2 https://faustlv2.grame.fr/DeMoD_Vox

# Run Nix build checks:
nix flake check
```

---

## Nix Module Options Reference

### NixOS (`programs.demod-vox`)

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the module |
| `package` | package | flake default | Override the plugin package |
| `sampleRate` | int | `96000` | PipeWire clock rate |
| `quantum` | int | `256` | PipeWire/JACK buffer size (frames) |
| `installCarla` | bool | `true` | Install Carla |
| `installEasyEffects` | bool | `true` | Install EasyEffects + system preset |
| `installCsound` | bool | `false` | Install Csound + runner script |

### Home Manager (`programs.demod-vox`)

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the module |
| `package` | package | flake default | Override the plugin package |
| `installEasyEffectsPreset` | bool | `true` | Install preset to `~/.config/easyeffects/input/` |
| `installCarla` | bool | `false` | Install Carla to user profile |
| `installEasyEffects` | bool | `false` | Install EasyEffects to user profile |
| `installCsound` | bool | `false` | Install Csound + runner to user profile |
| `installCarlaSession` | bool | `false` | Install Carla rack session with plugin pre-loaded |

---

## Parameter Reference

### Heavy

| Parameter | Range | Default | Notes |
|---|---|---|---|
| Pitch Shift | −12–0 st | 0 | 0 = no shift (21 ms latency still applies) |
| Bass Boost | 0–18 dB | 0 dB | 0 = flat passthrough |
| Bass Freq | 40–400 Hz | 120 Hz | Shelf −3 dB point |

### EQ

| Parameter | Range | Default |
|---|---|---|
| HPF Freq | 20–500 Hz | 100 Hz |
| LPF Freq | 1–12 kHz | 4.5 kHz |
| Mid Boost | 0–18 dB | 6 dB |
| Mid Freq | 500–5000 Hz | 2000 Hz |
| Mid BW | 100–4000 Hz | 800 Hz |

### Bitcrusher

| Parameter | Range | Default |
|---|---|---|
| Bit Depth | 2–16 | 8 |
| Downsample | 1–8× | 2× |
| Mix | 0–1 | 0.6 |

### Ring Modulator

| Parameter | Range | Default |
|---|---|---|
| Carrier Freq | 1–800 Hz | 60 Hz |
| Mix | 0–1 | 0.35 |

### Helmet Echo

| Parameter | Range | Default |
|---|---|---|
| Delay | 1–60 ms | 10 ms |
| Mix | 0–1 | 0.22 |
| Feedback | 0–0.7 | 0.15 |

### Compressor

| Parameter | Range | Default | Notes |
|---|---|---|---|
| Threshold | −40–0 dBFS | −18 dB | |
| Ratio | 1–20:1 | 8:1 | |
| Attack | 0.1–80 ms | 5 ms | |
| Release | 10–500 ms | 60 ms | |

### Output

| Parameter | Range | Default | Notes |
|---|---|---|---|
| Gain | −12–24 dB | +6 dB | Compressor makeup gain; signals above ±1.0 are hard-clipped |
| Bit Depth | 16 / 20 / 24 | 16 | TPDF dither applied at all depths |

---

## Troubleshooting

### Plugin not found by Carla / EasyEffects

```bash
echo $LV2_PATH
ls $(echo $LV2_PATH | tr ':' '\n' | head -1)
# If empty, re-login or: source ~/.nix-profile/etc/profile.d/hm-session-vars.sh
```

### PipeWire not at 96 kHz

```bash
pw-cli info 0 | grep rate
# Should show: clock.rate = 96000
# If not: systemctl --user restart wireplumber pipewire pipewire-pulse
```

### Xruns / audio dropout

Increase quantum: `programs.demod-vox.quantum = 512` (5.3 ms). Check RT priorities:
```bash
chrt -p $(pgrep pipewire)    # should show SCHED_FIFO or SCHED_RR
ulimit -r                    # should be > 0 (rtprio limit)
```

### EasyEffects preset URI mismatch

```bash
# Get the actual URI from the built plugin:
cat ~/.lv2/DeMoD_Vox.lv2/manifest.ttl | grep 'a lv2:Plugin' -A2
# Update DeMoD_Vox_input.json: replace the URI in "plugins_order" and the key name
```

### Csound JACK connection fails

```bash
pw-jack csound -+rtaudio=jack -odac -iadc -b256 -B512 DeMoD_Vox.csd
# pw-jack wraps Csound in the PipeWire JACK layer explicitly
```

---

## Changelog

### Current
- **Nix flake** added: `packages`, `nixosModules.default`, `homeManagerModules.default`, `devShells.default`, `checks`
- **NixOS module**: PipeWire 96 kHz, JACK compat, RTKit, PAM limits, EasyEffects system preset, Carla
- **Home Manager module**: LV2_PATH, EasyEffects preset, Carla session file
- **EasyEffects preset** JSON with three named sub-presets
- **Latency improved**: Faust 85 ms → 21 ms (window 8192→2048); Csound 42 ms → 21 ms (fftsize 4096→2048)
- **Build flags**: `-vec -vs 32 -dfs` added to faust2lv2 call for SIMD vectorisation

### Previous
- Hard clip before WLR; TPDF dither fixed (two independent LCGs); compressor ratio wired; bass shelf corrected
- Pitch shift + bass boost added; latency documented
- SR locked to 96 kHz; TPDF dither + word-length reduction output

---

## License

MIT — see [LICENSE](LICENSE).  
Copyright (c) 2026 ALH477
