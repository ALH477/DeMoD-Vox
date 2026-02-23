// ============================================================
//  DeMoD Vox — Power Armor Voice FX
//  Faust DSP  ·  LV2 / LADSPA for Carla on Linux
//
//  Copyright (c) 2026 ALH477
//  SPDX-License-Identifier: MIT
//  https://github.com/ALH477/DeMoD-Vox
//
// ---- I/O Specification (LOCKED) ----------------------------
//
//   Sample rate  : 96 000 Hz  (hard-coded — host MUST match)
//   Input format : 32-bit float  (standard LV2 audio port)
//   Output depth : 16-bit default · 20-bit · 24-bit selectable
//
//   All processing runs in 32-bit float.  The final stage hard-
//   clips to ±1.0, applies TPDF dither, then truncates to the
//   chosen word length before returning a normalised float.
//
//   A rate-mismatch guard mutes the output if the host SR is
//   not exactly 96 000 Hz — misconfiguration produces silence,
//   not subtly wrong audio.
//
//   Carla setup: Settings → Engine → Sample Rate → 96000
//   BEFORE loading this plugin.
//
// ---- !! LATENCY WARNING !! ---------------------------------
//
//   This plugin introduces a fixed latency of approximately
//   21 ms due to the granular pitch shifter (window = 2048
//   samples at 96 kHz).  This latency is CONSTANT regardless
//   of the pitch shift value, including at 0 semitones.
//
//   In a DAW:
//     • The host cannot automatically compensate — Faust's
//       ef.transpose does not report its latency via the
//       standard LV2 latency port.
//     • If you are tracking voice against a backing track,
//       shift the recorded track forward by ~21 ms to align,
//       OR use your DAW's manual plugin delay compensation.
//     • For zero-shift monitoring with no latency, bypass
//       this plugin entirely and use a separate instance only
//       when rendering the final take.
//
// ---- Signal Chain -------------------------------------------
//
//   IN (32f, 96 kHz)
//     → [Pitch Shift — granular, 0 to −12 semitones]
//     → [HPF] → [LPF] → [Mid Peak EQ]
//     → [Bitcrusher / Downsample]
//     → [Ring Modulator]
//     → [Helmet Echo — short feedback delay]
//     → [Bass Boost — 1st-order low shelf]
//     → [Compressor]
//     → [Output Gain]
//     → [Hard Clip ±1.0]
//     → [TPDF Dither + Word-Length Reduction]
//     → [SR Guard × 1.0 or × 0.0]
//     → OUT (32f LV2, quantised to 16/20/24-bit noise floor)
//
//   Chain ordering rationale — see README.md.
//
// ---- Build & Install ----------------------------------------
//
//   -srate 96000 locks SR at compile time, folding the sr_ok
//   guard to a no-op multiply by 1.0.
//
//   LV2 (recommended for Carla):
//     faust2lv2 -gui -srate 96000 DeMoD_Vox.dsp
//     cp -r DeMoD_Vox.lv2 ~/.lv2/
//
//   LADSPA (fallback):
//     faust2ladspa -srate 96000 DeMoD_Vox.dsp
//     cp DeMoD_Vox.so ~/.ladspa/
//
//   JACK standalone (test):
//     faust2jack -srate 96000 DeMoD_Vox.dsp && ./DeMoD_Vox
//
// ---- Dependencies -------------------------------------------
//   faust >= 2.50
//   stdfaust.lib  (filters, oscillators, delays, effects,
//                  compressors, basics, maths)
//   noises.lib (included via stdfaust — used directly below
//                for two independent TPDF noise generators)
// ============================================================

import("stdfaust.lib");

// ============================================================
//  SAMPLE RATE GUARD
//
//  sr_ok = 1.0 when host SR == 96000, else 0.0.
//  Applied as the very last multiply — mutes on mismatch.
//  Folds to 1.0 at compile time with -srate 96000.
// ============================================================

sr_ok = float(ma.SR == 96000);


// ============================================================
//  UI PARAMETERS  (grouped by stage → labelled in Carla GUI)
// ============================================================

// ---- Stage 0: Heavy (Pitch + Bass) -------------------------

pitch_st = hslider(
    "v:0-Heavy/1-Pitch Shift [unit:semitones][tooltip:-12=one octave down. 0=no shift (21 ms latency still applies)]",
    0, -12, 0, 1);

bass_db = hslider(
    "v:0-Heavy/2-Bass Boost [unit:dB][tooltip:Low shelf gain. 0=flat passthrough]",
    0, 0, 18, 0.5);

bass_freq = hslider(
    "v:0-Heavy/3-Bass Freq [unit:Hz][tooltip:Shelf -3 dB point. 80-150 Hz = sub weight]",
    120, 40, 400, 5);

// ---- Stage 1: EQ -------------------------------------------

hpf_freq = hslider(
    "v:1-EQ/1-HPF Freq [unit:Hz][tooltip:Cut below this to remove mud. Default 100 Hz]",
    100, 20, 500, 1);

lpf_freq = hslider(
    "v:1-EQ/2-LPF Freq [unit:Hz][tooltip:Vox-unit bandwidth ceiling. Default 4500 Hz]",
    4500, 1000, 12000, 10);

mid_db = hslider(
    "v:1-EQ/3-Mid Boost [unit:dB][tooltip:Presence peak gain. Default 6 dB]",
    6, 0, 18, 0.5);

mid_freq = hslider(
    "v:1-EQ/4-Mid Freq [unit:Hz]",
    2000, 500, 5000, 10);

mid_bw = hslider(
    "v:1-EQ/5-Mid BW [unit:Hz][tooltip:Peak bandwidth. Wider = gentler. Default 800 Hz]",
    800, 100, 4000, 10);

// ---- Stage 2: Bitcrusher -----------------------------------

bit_depth = hslider(
    "v:2-Bitcrusher/1-Bit Depth [tooltip:Word length. Lower = more grit. Default 8]",
    8, 2, 16, 1);

ds_amt = hslider(
    "v:2-Bitcrusher/2-Downsample [tooltip:Sample-rate divisor. Default 2]",
    2, 1, 8, 1) : int;

crush_mix = hslider(
    "v:2-Bitcrusher/3-Mix [tooltip:0=dry  1=fully crushed. Default 0.6]",
    0.6, 0, 1, 0.01);

// ---- Stage 3: Ring Modulator --------------------------------

ring_freq = hslider(
    "v:3-RingMod/1-Carrier Freq [unit:Hz][tooltip:60-300 Hz for metallic character]",
    60, 1, 800, 1);

ring_mix = hslider(
    "v:3-RingMod/2-Mix [tooltip:0=dry  1=fully ring-modulated. Default 0.35]",
    0.35, 0, 1, 0.01);

// ---- Stage 4: Helmet Echo ----------------------------------

echo_ms = hslider(
    "v:4-Helmet Echo/1-Delay [unit:ms][tooltip:8-15 ms = helmet interior. Min 1 ms]",
    10, 1, 60, 0.5);

echo_mix = hslider(
    "v:4-Helmet Echo/2-Mix",
    0.22, 0, 1, 0.01);

echo_fb = hslider(
    "v:4-Helmet Echo/3-Feedback [tooltip:Keep below 0.5 to avoid runaway]",
    0.15, 0, 0.7, 0.01);

// ---- Stage 5: Compressor -----------------------------------

c_thresh = hslider(
    "v:5-Compressor/1-Threshold [unit:dB]",
    -18, -40, 0, 0.5);

c_ratio = hslider(
    "v:5-Compressor/2-Ratio [tooltip:8:1 is aggressive. Higher = harder limiting]",
    8, 1, 20, 0.5);

c_attack = hslider(
    "v:5-Compressor/3-Attack [unit:ms]",
    5, 0.1, 80, 0.1) / 1000.0;

c_release = hslider(
    "v:5-Compressor/4-Release [unit:ms]",
    60, 10, 500, 1.0) / 1000.0;

// ---- Stage 6: Output + Word-Length Reduction ---------------

out_db = hslider(
    "v:6-Output/1-Gain [unit:dB][tooltip:Acts as compressor makeup gain. Note: +24 dB can clip — watch meter]",
    6, -12, 24, 0.5);

out_bits = hslider(
    "v:6-Output/2-Bit Depth [tooltip:16=CD/broadcast  20=DAT  24=mastering. Step of 4]",
    16, 16, 24, 4) : int;


// ============================================================
//  DSP IMPLEMENTATION
// ============================================================

// ---- Stage 0a: Pitch Shift ---------------------------------
//
//  ef.transpose(window, xfade, semitones)
//    window = 2048 samples  →  ~21 ms latency at 96 kHz
//    xfade  =  256 samples  →  grain overlap crossfade
//
//  Formants are NOT preserved (kkeepform equivalent = off).
//  Vocal formants shift down with the pitch, producing an
//  inhuman "armored giant" character rather than a natural
//  voice pitched down.
//
//  LATENCY NOTE: 21 ms is constant at all semitone values,
//  including 0.  The granular engine always runs.  See the
//  latency warning in the file header for DAW compensation.

pitch_shift = ef.transpose(2048, 256, pitch_st);


// ---- Stage 1: EQ -------------------------------------------

hpf    = fi.highpass(2, hpf_freq);
lpf    = fi.lowpass(2, lpf_freq);
mid_eq = fi.peak_eq(mid_db, mid_freq, mid_bw);

eq_chain = hpf : lpf : mid_eq;


// ---- Stage 2: Bitcrusher -----------------------------------

// quantise(b, x): round x to nearest b-bit signed step.
//   step size = 1 / 2^(b-1),  range = [-1, +1)
quantise(b, x) = floor(x * steps + 0.5) / steps
    with { steps = pow(2.0, b - 1.0); };

// Sample-and-hold: pass one sample every ds_amt samples.
ds_counter = (+(1) ~ _) % ds_amt;
ds_trigger  = ds_counter == 0;
downsample(x) = ba.sAndH(ds_trigger, x);

bitcrusher(x) = (1.0 - wet) * x + wet * crushed
    with {
        crushed = downsample(quantise(bit_depth, x));
        wet     = crush_mix;
    };


// ---- Stage 3: Ring Modulator --------------------------------

// Phase-reset sine carrier — starts at 0 on plugin load.
ring_carrier = os.oscrs(ring_freq);

ring_mod(x) = (1.0 - ring_mix) * x + ring_mix * (x * ring_carrier);


// ---- Stage 4: Helmet Echo ----------------------------------
//
//   x ──┬──────────────────────────────────► (+ echo_mix) → out
//        │                                   ▲
//        └──► [+] ──► fdelay(max, N) ──┬─────┘
//              ▲                       │
//              └───── × echo_fb ───────┘
//
//  de.fdelay with an explicit compile-time max buffer size.
//  echo_ms minimum = 1 ms prevents zero-sample feedback loop.

echo_max_samp = int(60.0 * ma.SR / 1000.0);
echo_samp     = int(echo_ms * ma.SR / 1000.0);

helmet_echo(x) = x + de.fdelay(echo_max_samp, echo_samp, fb_sig) * echo_mix
    with {
        fb_sig = (x + _ * echo_fb) ~ de.fdelay(echo_max_samp, echo_samp);
    };


// ---- Stage 4b: Bass Boost ----------------------------------
//
//  fi.low_shelf(dBgain, freq) — 1st-order low shelving filter.
//
//  Response:
//    DC       →  full bass_db boost (linear gain = 10^(bass_db/20))
//    bass_freq →  −3 dB point of the shelf transition
//    HF       →  0 dB (flat — bass boost only, not broadband)
//
//  At bass_db = 0:  fi.low_shelf(0, f) is unity gain at ALL
//  frequencies — a true transparent passthrough, no coloration.
//
//  Placed after echo, before compressor so the compressor clamps
//  boosted bass transients evenly rather than pumping on them.

bass_boost = fi.low_shelf(bass_db, bass_freq);


// ---- Stage 5: Compressor -----------------------------------
//
//  co.compressor_mono(ratio, thresh, attack, release)
//  No automatic makeup gain — use Stage 6 output gain for that.

compressor = co.compressor_mono(c_ratio, c_thresh, c_attack, c_release);


// ---- Stage 6: Hard Clip + TPDF Dither + WLR ----------------
//
//  HARD CLIP (fix: added this pass)
//  --------------------------------
//  Prevents the word-length reducer from wrapping on signals
//  above ±1.0.  With output gain up to +24 dB, clipping is
//  reachable even after compression.  Hard clip first: any
//  overs are clamped to ±1.0 before quantisation, producing
//  flat-top clipping rather than undefined wrap behaviour.
//
//  TPDF DITHER (fix: two independent LCG generators)
//  -------------------------------------------------
//  Two independently-seeded linear congruential generators
//  produce statistically independent uniform noise streams.
//
//  WHY NOT (no.noise - no.noise)?
//  Faust's compiler may share (CSE) both references to the
//  same no.noise instance, yielding x − x = 0 every sample
//  and completely defeating the dither.  Two separate generator
//  expressions with different multipliers and seeds guarantee
//  independence at both the Faust and compiler level.
//
//  Each generator output is in [-1.0, +1.0].
//  Their difference spans [-2.0, +2.0] with a triangular PDF.
//  Scaling by 0.5 gives ±1.0; multiplying by dither_lsb
//  (= 1 LSB in float units) gives the required ±1 LSB amplitude.
//
//  WORD-LENGTH REDUCTION
//  ----------------------
//  1. Add dither.
//  2. Multiply to integer range (× out_steps).
//  3. Round to nearest integer.
//  4. Divide back to float (÷ out_steps).
//  Result: float signal whose quantisation noise floor = that
//  of the selected bit depth (~6 dB × bit_depth below 0 dBFS).

// Two independent LCG noise generators (different seeds and multipliers).
// Generator A: seed 12345, multiplier 1103515245  (standard glibc LCG)
// Generator B: seed 67890, multiplier 1664525      (Numerical Recipes LCG)
// Both produce uniform outputs in approximately [-1, +1].
noise_a = (+(12345)  ~ *(1103515245)) / 2147483648.0;
noise_b = (+(67890)  ~ *(1664525))    / 2147483648.0;

dither_lsb  = pow(2.0, -(float(out_bits) - 1.0));   // 1 LSB in float units
tpdf        = (noise_a - noise_b) * 0.5 * dither_lsb; // triangular PDF, ±1 LSB
out_steps   = pow(2.0, float(out_bits) - 1.0);

// Hard clip then dither then quantise.
clip(x)      = max(-1.0, min(1.0, x));
wl_reduce(x) = floor((clip(x) + tpdf) * out_steps + 0.5) / out_steps;


// ============================================================
//  FULL MONO PROCESS
//
//  Input:  32-bit float, 96 kHz
//  Output: 32-bit float, hard-clipped to ±1.0 then quantised
//          to the selected bit depth's noise floor.
//          Muted to 0.0 if host SR != 96000.
// ============================================================

process = _
    : pitch_shift            // Stage 0a — granular down-pitch
    : eq_chain               // Stage 1  — HPF, LPF, mid peak
    : bitcrusher             // Stage 2  — codec grit
    : ring_mod               // Stage 3  — metallic sidebands
    : helmet_echo            // Stage 4  — visor acoustics
    : bass_boost             // Stage 4b — low shelf weight
    : compressor             // Stage 5  — tighten & thicken
    : *(ba.db2linear(out_db)) // Stage 6a — output trim / makeup
    : wl_reduce              // Stage 6b — clip, TPDF, WLR
    : *(sr_ok);              //          — SR mismatch guard
