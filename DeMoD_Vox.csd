; ============================================================
;  DeMoD Vox — Power Armor Voice FX  (Csound)
;
;  Copyright (c) 2026 ALH477
;  SPDX-License-Identifier: MIT
;  https://github.com/ALH477/DeMoD-Vox
;
; ---- I/O Specification (LOCKED) ----------------------------
;
;   Sample rate  : 96 000 Hz  (hard-coded — do NOT change)
;   Input format : 32-bit float  (Csound internal)
;   Output depth : 16-bit default · 20-bit · 24-bit selectable
;
;   All processing runs in Csound's internal float.  The final
;   stage hard-clips to ±1.0, applies TPDF dither, then
;   truncates to the chosen word length.
;
; ---- !! LATENCY WARNING !! ---------------------------------
;
;   This instrument introduces approximately 21 ms of latency
;   from the PVS phase-vocoder pitch shifter:
;
;     latency = ifftsize / sr = 2048 / 96000 ≈ 21 ms
;
;   This latency is CONSTANT regardless of pitch setting,
;   including at 0 semitones (no shift).
;
;   In a DAW / Carla patchbay:
;     • Compensate by advancing the recorded output by ~21 ms.
;     • Or use the csound-lv2 wrapper's latency report field
;       if your host supports plugin delay compensation.
;     • For zero-latency monitoring without pitch shift,
;       bypass this instrument and patch audio directly.
;
; ---- Signal Chain -------------------------------------------
;
;   IN (32f, 96 kHz)
;     → [Pitch Shift — PVS phase vocoder, 0 to −12 semitones]
;     → [HPF] → [LPF] → [Mid Peak EQ]
;     → [Bitcrusher / Downsample]
;     → [Ring Modulator]
;     → [Helmet Echo — short feedback delay]
;     → [Bass Boost — 1st-order low shelf via tone + parallel]
;     → [Compressor]
;     → [Output Gain]
;     → [Hard Clip ±1.0]
;     → [TPDF Dither + Word-Length Reduction]
;     → OUT
;
;   Chain ordering rationale — see README.md.
;
; ---- Running ------------------------------------------------
;
;   JACK:
;     csound -+rtaudio=jack -+rtmidi=null \
;             -odac -iadc -b256 -B1024 DeMoD_Vox.csd
;
;   ALSA:
;     csound -+rtaudio=alsa -odac0 -iadc0 \
;             -b512 -B2048 DeMoD_Vox.csd
;
;   In Carla: use csound-lv2 → https://github.com/kunstmusik/csound-lv2
;
; ---- Channel Reference  (chnset / chnget) ------------------
;
;   Channel name   Range               Default  Description
;   ─────────────  ──────────────────  ───────  ──────────────────────────
;   pitch_st       -12 – 0 semitones   0        Down-tune amount
;   bass_db        0   – 18 dB         0        Bass shelf gain
;   bass_freq      40  – 400 Hz        120      Bass shelf -3 dB point
;   hpf_freq       20  – 500 Hz        100      HPF cut frequency
;   lpf_freq       1000– 12000 Hz      4500     LPF cut frequency
;   mid_db         0   – 18 dB         6        Mid peak gain
;   mid_freq       500 – 5000 Hz       2000     Mid peak centre Hz
;   mid_bw         100 – 4000 Hz       800      Mid peak bandwidth
;   bit_depth      2   – 16            8        Crusher word length
;   downsample     1   – 8             2        SR divisor
;   crush_mix      0   – 1             0.6      Crusher wet/dry
;   ring_freq      1   – 800 Hz        60       Ring mod carrier Hz
;   ring_mix       0   – 1             0.35     Ring mod wet/dry
;   echo_ms        1   – 60 ms         10       Echo delay time
;   echo_mix       0   – 1             0.22     Echo wet level
;   echo_fb        0   – 0.7           0.15     Echo feedback
;   comp_thresh    -40 – 0 dBFS        -18      Compressor threshold
;   comp_ratio     1   – 20            8        Compressor ratio
;   comp_attack    0.1 – 80 ms         5        Compressor attack
;   comp_release   10  – 500 ms        60       Compressor release
;   out_gain       -12 – 24 dB         6        Output level / makeup gain
;   out_bits       16 / 20 / 24        16       Output word length
; ============================================================

<CsoundSynthesizer>
<CsOptions>
  -+rtaudio=jack -odac -iadc -b256 -B1024
  -m0d
</CsOptions>

<CsInstruments>

; ---- LOCKED sample rate ------------------------------------
sr     = 96000
ksmps  = 32
nchnls = 1
0dbfs  = 1.0

; ============================================================
;  instr 0 — Startup channel initialisation
; ============================================================

instr 0
  chnset 0.0,     "pitch_st"
  chnset 0.0,     "bass_db"
  chnset 120.0,   "bass_freq"
  chnset 100.0,   "hpf_freq"
  chnset 4500.0,  "lpf_freq"
  chnset 6.0,     "mid_db"
  chnset 2000.0,  "mid_freq"
  chnset 800.0,   "mid_bw"
  chnset 8.0,     "bit_depth"
  chnset 2.0,     "downsample"
  chnset 0.6,     "crush_mix"
  chnset 60.0,    "ring_freq"
  chnset 0.35,    "ring_mix"
  chnset 10.0,    "echo_ms"
  chnset 0.22,    "echo_mix"
  chnset 0.15,    "echo_fb"
  chnset -18.0,   "comp_thresh"
  chnset 8.0,     "comp_ratio"
  chnset 5.0,     "comp_attack"
  chnset 60.0,    "comp_release"
  chnset 6.0,     "out_gain"
  chnset 16.0,    "out_bits"
endin

; ============================================================
;  instr 1 — Main FX processor
; ============================================================

instr 1

  k_pitch_st  chnget "pitch_st"
  k_bass_db   chnget "bass_db"
  k_bass_hz   chnget "bass_freq"
  k_hpf_hz    chnget "hpf_freq"
  k_lpf_hz    chnget "lpf_freq"
  k_mid_db    chnget "mid_db"
  k_mid_hz    chnget "mid_freq"
  k_mid_bw    chnget "mid_bw"
  k_bits      chnget "bit_depth"
  k_ds        chnget "downsample"
  k_cmix      chnget "crush_mix"
  k_ring_hz   chnget "ring_freq"
  k_rmix      chnget "ring_mix"
  k_echo_ms   chnget "echo_ms"
  k_emix      chnget "echo_mix"
  k_efb       chnget "echo_fb"
  k_thresh    chnget "comp_thresh"
  k_ratio     chnget "comp_ratio"
  k_att_ms    chnget "comp_attack"
  k_rel_ms    chnget "comp_release"
  k_outdb     chnget "out_gain"
  k_outbits   chnget "out_bits"

  k_echo_ms  = (k_echo_ms < 1 ? 1 : k_echo_ms)
  k_ratio    = (k_ratio < 1 ? 1 : (k_ratio > 20 ? 20 : k_ratio))
  k_outbits  = (k_outbits >= 22 ? 24 : (k_outbits >= 18 ? 20 : 16))

  k_att_s    = k_att_ms  / 1000.0
  k_rel_s    = k_rel_ms  / 1000.0
  k_echo_t   = k_echo_ms / 1000.0

  a_in       inch 1

  ; STAGE 0 — Pitch Shift
  i_fftsize  = 2048
  i_overlap  =  512
  i_winsize  = 2048
  k_scale    = pow(2, k_pitch_st / 12.0)
  f_sig      pvsanal  a_in, i_fftsize, i_overlap, i_winsize, 1
  f_scaled   pvscale  f_sig, k_scale, 0, 1
  a_eq       pvsynth  f_scaled

  ; STAGE 1 — EQ
  a_eq       butterhp a_eq, k_hpf_hz
  a_eq       butterlp a_eq, k_lpf_hz
  a_eq       eqfil    a_eq, k_mid_hz, k_mid_bw, ampdb(k_mid_db)

  ; STAGE 2 — Bitcrusher
  k_ds_int   = int(k_ds)
  k_steps    = pow(2, k_bits - 1)
  a_crush    = floor(a_eq * k_steps + 0.5) / k_steps
  a_phs      phasor sr / k_ds_int
  a_ds       samphold a_crush, a_phs
  a_eq       = (1 - k_cmix) * a_eq + k_cmix * a_ds

  ; STAGE 3 — Ring Modulator
  a_carrier  poscil 1, k_ring_hz
  a_ring     = a_eq * a_carrier
  a_eq       = (1 - k_rmix) * a_eq + k_rmix * a_ring

  ; STAGE 4 — Helmet Echo
  i_max_dly  = 65
  a_delout   init 0
  a_delin    = a_eq + a_delout * k_efb
  a_delout   vdelay a_delin, k_echo_t * 1000, i_max_dly
  a_eq       = a_eq + a_delout * k_emix

  ; STAGE 4b — Bass Boost
  k_bass_lin = ampdb(k_bass_db)
  a_lp       tone a_eq, k_bass_hz
  a_eq       = a_eq + a_lp * (k_bass_lin - 1)

  ; STAGE 5 — Compressor
  a_eq       compress a_eq, a_eq, \
                 k_thresh, k_thresh+3, k_thresh+6, \
                 k_ratio, k_att_s, k_rel_s, 0.01

  ; STAGE 6a — Output gain
  k_gain     = ampdb(k_outdb)
  a_out      = a_eq * k_gain

  ; STAGE 6b — Hard Clip + TPDF Dither + WLR
  k_out_steps = pow(2, k_outbits - 1)
  k_lsb       = 1.0 / k_out_steps
  a_r1        rand k_lsb * 0.5
  a_r2        rand k_lsb * 0.5
  a_dither    = a_r1 - a_r2
  a_out       limit a_out, -1.0, 1.0
  a_out       = floor((a_out + a_dither) * k_out_steps + 0.5) / k_out_steps

               out a_out

endin

</CsInstruments>

<CsScore>
i 0  0  0
i 1  0  86400
e
</CsScore>

</CsoundSynthesizer>
