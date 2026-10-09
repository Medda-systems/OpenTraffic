"""50-second, 120 BPM R&B / bass-house promo cue, synthesized locally.

Run: python3 remotion/audio/bass_drop.py (from website/).
Opening drop 0s; evolving build 12-28s; drop two 28s; final drop 42s;
closing hit 48s and a two-second decay. Existing promo assets are untouched.
"""

import json
import subprocess
from functools import lru_cache
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import fftconvolve

from synth import SR, bandpass, highpass, hz, lowpass

BPM = 120
BEAT = 60 / BPM
BAR = BEAT * 4
SECONDS = 50
N = int(SECONDS * SR)
RNG = np.random.default_rng(12042)
DEST = Path(__file__).resolve().parents[2] / "out" / "music-samples"


def time(seconds):
    return np.arange(round(seconds * SR)) / SR


def empty():
    return np.zeros((N, 2), dtype=np.float64)


def put(bus, sound, start, gain=1, pan=0):
    i = round(start * SR)
    n = min(len(sound), len(bus) - i)
    if i < 0 or n <= 0:
        return
    x = sound[:n]
    if x.ndim == 1:
        x = np.stack([x * np.sqrt(1 - pan), x * np.sqrt(1 + pan)], axis=1)
    bus[i:i + n] += x * gain


def envelope(t, attack=.003, decay=.15, release=.03):
    return np.minimum(t / attack, 1) * np.exp(-t / decay) * np.clip((t[-1] - t) / release, 0, 1)


def normalize(x):
    return x / max(np.max(np.abs(x)), 1e-9)


def tight_kick():
    t = time(.32)
    f = 51 + 132 * np.exp(-t / .014) + 27 * np.exp(-t / .055)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / .093)
    punch = np.sin(2 * np.pi * 135 * t) * np.exp(-t / .015) * .28
    click = bandpass(RNG.standard_normal(len(t)), 2100, 9500) * np.exp(-t / .0022) * .20
    x = np.tanh(1.45 * (body + punch)) / 1.45 + click
    return normalize(x * np.minimum(t / .0003, 1) * np.clip((.32 - t) / .025, 0, 1))


def crisp_snare():
    t = time(.23)
    noise = RNG.standard_normal(len(t))
    body = (np.sin(2 * np.pi * 182 * t) + .3 * np.sin(2 * np.pi * 335 * t)) * np.exp(-t / .036)
    wire = bandpass(noise, 1400, 10500) * np.exp(-t / .047)
    snap = bandpass(noise, 2800, 12000) * np.exp(-t / .006)
    clap = np.zeros(len(t))
    for offset in (.008, .017, .028):
        u = np.maximum(t - offset, 0)
        clap += bandpass(RNG.standard_normal(len(t)), 1100, 4300) * np.exp(-u / .027) * (t >= offset)
    return normalize((body * .44 + wire * .8 + snap * .48 + clap * .20) * np.clip((.23 - t) / .03, 0, 1))


def hats(opened=False):
    t = time(.25 if opened else .06)
    metal = sum(np.sin(2 * np.pi * f * t) for f in (6431, 8123, 9237, 11029)) * .13
    x = highpass(RNG.standard_normal(len(t)) * .72 + metal, 6500, 3)
    return normalize(x * envelope(t, .0004, .048 if opened else .009, .012))


@lru_cache(None)
def bass_note(midi, seconds, bright=False):
    """Mono fundamental plus a small stereo harmonic layer, without wide sub."""
    t = time(seconds)
    f = float(hz(midi))
    phase = 2 * np.pi * f * t
    env = np.minimum(t / .005, 1) * (.72 + .28 * np.exp(-t / .07)) * np.clip((seconds - t) / .033, 0, 1)
    sub = np.sin(phase) + .23 * np.sin(2 * phase)
    sides = []
    for detune in (.997, 1.003):
        harmonics = sum(np.sin(phase * k * detune) / k**1.5 for k in range(2, 13 if bright else 8))
        sides.append(sub * .85 + np.tanh(harmonics * 1.9) * (.32 if bright else .23))
    return np.stack(sides, axis=1) * env[:, None]


@lru_cache(None)
def piano_note(midi, seconds):
    t = time(seconds)
    f = float(hz(midi))
    phase = 2 * np.pi * f * t
    fm = (.75 + 1.6 * np.exp(-t / .085)) * np.sin(phase * 2)
    tone = np.sin(phase + fm) * .75 + np.sin(phase * 2) * .16 * np.exp(-t / .16)
    tine = np.sin(phase * 7) * .075 * np.exp(-t / .024)
    return (tone + tine) * envelope(t, .004, .62, .055)


def chord(notes, seconds=.9):
    x = np.zeros((round((seconds + .04) * SR), 2))
    for k, midi in enumerate(notes):
        put(x, piano_note(midi, seconds), k * .006, .6 / np.sqrt(len(notes)), (k / (len(notes) - 1) - .5) * .45)
    return x


@lru_cache(None)
def hook_note(midi, seconds=.32):
    t = time(seconds)
    f = float(hz(midi))
    # A rounded, pitched pluck rather than a noisy raw saw oscillator.
    phase = 2 * np.pi * f * t
    x = sum(np.sin(phase * k) / k**1.35 * np.exp(-t * k / .19) for k in range(1, 10))
    return x * envelope(t, .002, .23, .04)


def echo(x, gain=.22):
    out = x.copy()
    for k in range(1, 5):
        d = round(.375 * SR * k)
        y = np.stack([highpass(lowpass(x[:, c], 4500), 350) for c in range(2)], axis=1)
        out[d:] += y[:-d, ::-1 if k % 2 else 1] * gain**k
    return out


def room(x, wet=.12):
    t = time(.65)
    ir = RNG.standard_normal((len(t), 2)) * np.exp(-t / .12)[:, None]
    for c in range(2):
        ir[:, c] = bandpass(ir[:, c], 600, 7000)
        ir[:, c] /= np.sqrt(np.sum(ir[:, c]**2))
    return x + np.stack([fftconvolve(x[:, c], ir[:, c])[:N] for c in range(2)], axis=1) * wet


def sweep(seconds, rising=True):
    t = time(seconds)
    p = t / seconds
    noise = RNG.standard_normal(len(t))
    x = np.zeros(len(t))
    centers = np.geomspace(500, 10000, 12)
    progress = p if rising else 1 - p
    for j, center in enumerate(centers):
        weight = np.maximum(0, 1 - np.abs(progress * 11 - j))
        x += bandpass(noise, center * .7, min(center * 1.3, 18000)) * weight
    return normalize(x) * (p**1.8 if rising else np.exp(-t / .55)) * np.minimum(t / .004, 1)


def sidechain(bus, kick_times, depth=.85):
    env = np.ones(N)
    tt = time(.23)
    shape = 1 - depth * np.exp(-tt / .064)
    for start in kick_times:
        i = round(start * SR)
        n = min(len(tt), N - i)
        env[i:i + n] = np.minimum(env[i:i + n], shape[:n])
    return bus * env[:, None]


def compose():
    drums, low, keys, lead, fx, snare_bus = [empty() for _ in range(6)]
    K, S, HC, HO = tight_kick(), crisp_snare(), hats(), hats(True)
    kicks = []
    # F#m9, Dmaj9, Amaj9, E9; two bars per harmony, rootless keys stay clear of bass.
    harmony = [(30, [57, 61, 64, 68]), (38, [54, 57, 61, 64]),
               (33, [56, 59, 61, 64]), (40, [56, 59, 62, 66])]
    motif = [(0, 73), (3, 76), (6, 78), (10, 76), (14, 73)]
    for bar in range(24):
        start = bar * BAR
        root, notes = harmony[(bar // 2) % 4]
        if bar >= 21:
            root, notes = harmony[0]
        build = 6 <= bar < 14
        lift = np.clip((bar - 6) / 7, 0, 1) if build else 1
        big = bar >= 14
        pre_drop = bar in (13, 20)
        # Bars 13-14 lift the low end out; the restored sub makes drop two hit harder.
        stripped = bar in (12, 13)
        kick_steps = [0, 4, 8, 12]
        if bar % 2 == 1 and not build:
            kick_steps += [14.5]
        if stripped:
            kick_steps = [0, 8] if bar == 12 else [0, 4]
        for step in kick_steps:
            at = start + step * BEAT / 4
            put(drums, K, at, .91 if step % 4 == 0 else .55)
            kicks.append(at)
        for step in (4, 12):
            if pre_drop and step == 12:
                continue
            put(snare_bus, S, start + step * BEAT / 4, .61 if big else .55)
        if not stripped:
            put(snare_bus, S, start + 15 * BEAT / 4 + .015, .07)
        for step in range(16):
            if pre_drop and step >= 12:
                continue
            if build and lift < .3 and step % 2:
                continue
            swing = .016 if step % 2 else 0
            accent = (.12, .046, .092, .056)[step % 4]
            put(drums, HC, start + step * BEAT / 4 + swing,
                accent * (1 + .30 * lift if build else 1.10 if big else 1),
                .28 if step % 2 else -.22)
        if not stripped:
            for step in (2, 6, 10, 14):
                if pre_drop and step >= 12:
                    continue
                put(drums, HO, start + step * BEAT / 4, .072 if big else .052, .12)
        # Syncopated notes answer the kick; fifth/octave pickups add R&B movement.
        bass_pattern = [(0, root, .27), (3, root, .20), (6, root + 12, .18),
                        (8, root, .29), (11, root + 7, .18), (14, root, .20)]
        if big:
            bass_pattern += [(15.5, root + 12, .065)]
        if not stripped:
            for step, note, length in bass_pattern:
                if pre_drop and step >= 12:
                    continue
                put(low, bass_note(note, length, big), start + step * BEAT / 4,
                    .61 if not build else .45 + .13 * lift)
        # Chops in the gaps, rather than a continuous pad masking drum transients.
        for step, velocity in ((2, .44), (7, .30), (10, .39)):
            if pre_drop and step >= 10:
                continue
            put(keys, chord(notes, .68 if big else .90), start + step * BEAT / 4 + .009,
                velocity * (.85 + lift * .25 if build else 1))
        if bar < 6 or big or bar in (8, 10, 12):
            for step, note in motif:
                if pre_drop and step >= 12:
                    continue
                put(lead, hook_note(note), start + step * BEAT / 4 + .006,
                    .10 if not big else .14, -.25 if step < 8 else .25)
                if big and step in (6, 14):
                    put(lead, hook_note(note + 12, .22), start + step * BEAT / 4 + .013, .045, .35)
        if bar in (3, 5, 9, 17, 23):
            for step in (14, 15, 15.5):
                put(snare_bus, S, start + step * BEAT / 4, .10 + (step - 14) * .06)
    # Progressive rolls, a rising pitched layer and a beat of breath before each drop.
    for start, length, level in ((24, 3.5, .16), (40, 1.5, .20)):
        put(fx, sweep(length), start, level)
        for k in range(round(length / (BEAT / 4))):
            at = start + k * BEAT / 4
            gain = .065 + .16 * (k / max(1, length / (BEAT / 4)))**1.8
            put(snare_bus, S, at, gain)
        t = time(length)
        freq = 330 * 2 ** (t / length * 2)
        tone = np.sin(2 * np.pi * np.cumsum(freq) / SR) * (t / length)**2
        put(fx, tone, start, .035)
    for at in (0, 28, 42):
        put(fx, sweep(1.5, False), at, .16)
        put(keys, chord(harmony[0][1], 1.5), at, .38)
    # Mute all melodic/reverb tails during the beat before the big drops.
    lead = echo(lead, .32)
    keys = room(echo(keys, .20), .10)
    for end in (28, 42):
        a, b = round((end - .5) * SR), round(end * SR)
        mute = np.zeros(b - a)
        ramp = round(.018 * SR)
        mute[:ramp] = np.linspace(1, 0, ramp)
        for bus in (drums, low, keys, lead, fx, snare_bus):
            bus[a:b] *= mute[:, None]
    # A resolved last hit, followed only by its decay (never an abruptly cut loop).
    put(drums, K, 48, 1)
    kicks.append(48)
    put(snare_bus, S, 48, .34)
    put(low, bass_note(30, 1.5, True) * np.exp(-time(1.5) / .44)[:, None], 48, .60)
    put(keys, chord([54, 57, 61, 68], 1.95), 48, .62)
    put(lead, hook_note(78, 1.6), 48, .15)
    put(fx, sweep(1.8, False), 48, .17)
    mix = drums + room(snare_bus, .045) + sidechain(low, kicks, .91)
    mix += sidechain(keys, kicks, .38) + sidechain(lead, kicks, .25) + fx
    for c in range(2):
        x = highpass(mix[:, c], 28, 3)
        # The original samples were crowded below 500 Hz. Broad shelves retain
        # weight while exposing the snare snap, tine and cymbal detail.
        sub = lowpass(x, 140, 2)
        body = lowpass(x, 500, 2) - sub
        presence = lowpass(x, 4000, 2) - lowpass(x, 500, 2)
        air = x - lowpass(x, 4000, 2)
        mix[:, c] = .80 * sub + .95 * body + 1.85 * presence + 2.4 * air
    # Very gentle saturation on occasional peaks, preserving the short drum attack.
    mix = np.where(np.abs(mix) < .90, mix, np.sign(mix) * (.90 + .12 * np.tanh((np.abs(mix) - .90) / .12)))
    mix[-round(.18 * SR):] *= np.linspace(1, 0, round(.18 * SR))[:, None]**2
    return mix


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stderr


def export(mix, stem="6-rnb-bass-drop", title="OpenTraffic — R&B Bass Drop"):
    DEST.mkdir(parents=True, exist_ok=True)
    raw = DEST / f".{stem}-raw.wav"
    wav = DEST / f"{stem}.wav"
    mp3 = wav.with_suffix(".mp3")
    wavfile.write(raw, SR, mix.astype(np.float32))
    # Two-pass loudness correction, with a limiter before measurement for peak headroom.
    prep = "alimiter=limit=0.84:level=false:attack=2:release=55:latency=true"
    target = "I=-14:TP=-1.5:LRA=9"
    result = run("ffmpeg", "-hide_banner", "-nostats", "-i", str(raw), "-af",
                 prep + ",loudnorm=" + target + ":print_format=json", "-f", "null", "-")
    stats = json.loads(result[result.rfind("{"):result.rfind("}") + 1])
    measured = ":".join(f"{key}={stats[value]}" for key, value in (
        ("measured_I", "input_i"), ("measured_TP", "input_tp"),
        ("measured_LRA", "input_lra"), ("measured_thresh", "input_thresh"),
        ("offset", "target_offset")))
    run("ffmpeg", "-v", "error", "-y", "-i", str(raw), "-af",
        f"{prep},loudnorm={target}:{measured}:linear=true,aresample={SR}",
        "-c:a", "pcm_s24le", str(wav))
    run("ffmpeg", "-v", "error", "-y", "-i", str(wav), "-c:a", "libmp3lame",
        "-b:a", "320k", "-metadata", f"title={title}",
        "-metadata", "comment=120 BPM; drops 0/28/42s; closing hit 48s", str(mp3))
    raw.unlink()
    print(json.dumps({"bpm": BPM, "seconds": SECONDS, "drops": [0, 28, 42],
                      "closing_hit": 48, "wav": str(wav), "mp3": str(mp3)}, indent=2))


def main():
    export(compose())


if __name__ == "__main__":
    main()
