"""Synthesis for the promo's music and sound effects: helpers, instruments, and the arrangement the
video is cut to. Everything is made from scratch, so there's nothing to license.

The arrangement is 38 bars at 120 BPM, a bar every two seconds: an intro with a riser (bars 1-2), the
drop (3-15), a breakdown and build (16-17), a second drop (18-28), another breakdown and build (29-30),
the second drop again (31-36), and a final hit that rings out under the end card (37-38).
"""

import os
from functools import lru_cache

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, fftconvolve, sosfilt

SR = 48000
BPM = 120
BEAT = 60 / BPM
BAR = 4 * BEAT
BARS = 38
LENGTH = BARS * BAR
rng = np.random.default_rng(7)

OUT = os.environ.get("PROMO_AUDIO_DIR") or os.path.join(os.path.dirname(__file__), "..", "public", "promo")
os.makedirs(OUT, exist_ok=True)


def hz(midi):
    return 440.0 * 2 ** ((np.asarray(midi) - 69) / 12)


def t_(seconds):
    return np.arange(int(seconds * SR)) / SR


def lowpass(x, cutoff, order=2):
    return sosfilt(butter(order, min(cutoff, SR / 2 - 100), "low", fs=SR, output="sos"), x)


def highpass(x, cutoff, order=2):
    return sosfilt(butter(order, cutoff, "high", fs=SR, output="sos"), x)


def bandpass(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, min(hi, SR / 2 - 100)], "band", fs=SR, output="sos"), x)


def place(track, sound, at, gain=1.0):
    """Mixes a mono or stereo sound into a stereo track at `at` seconds."""
    if sound.ndim == 1:
        sound = np.stack([sound, sound], axis=1)
    i = int(round(at * SR))
    if i >= len(track):
        return
    n = min(len(sound), len(track) - i)
    track[i : i + n] += sound[:n] * gain


def reverb_ir(seconds=1.8, decay=0.45, tone=6000):
    t = t_(seconds)
    ir = rng.standard_normal((len(t), 2)) * np.exp(-t / decay)[:, None]
    ir[:, 0] = lowpass(ir[:, 0], tone)
    ir[:, 1] = lowpass(ir[:, 1], tone)
    return ir / np.sqrt((ir**2).sum(axis=0))


IR = reverb_ir()


def reverb(x, wet):
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    out = np.stack([fftconvolve(x[:, c], IR[:, c])[: len(x)] for c in range(2)], axis=1)
    return x + out * wet


def saw(freq, t, phase=0.0):
    return 2 * ((freq * t + phase) % 1.0) - 1


def adsr(n, a, d, s, r, hold):
    """An envelope of n samples: attack, decay to sustain, hold, release (all seconds)."""
    env = np.zeros(n)
    a_n, d_n, h_n, r_n = (int(v * SR) for v in (a, d, hold, r))
    i = 0
    for seg, start, end in ((a_n, 0, 1), (d_n, 1, s)):
        seg = max(seg, 1)
        m = min(seg, n - i)
        env[i : i + m] = np.linspace(start, end, seg)[:m]
        i += m
    m = min(h_n, n - i)
    env[i : i + m] = s
    i += m
    m = min(max(r_n, 1), n - i)
    env[i : i + m] = np.linspace(s, 0, max(r_n, 1))[:m]
    return env


# ---------------------------------------------------------------- instruments


def kick(gain=1.0):
    t = t_(0.45)
    f = 45 + 110 * np.exp(-t / 0.035)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.16)
    click = highpass(rng.standard_normal(len(t)), 2000) * np.exp(-t / 0.004) * 0.25
    return np.tanh((body + click) * 1.6) * gain


def clap():
    t = t_(0.5)
    noise = bandpass(rng.standard_normal(len(t)), 900, 3200)
    env = np.zeros(len(t))
    for k, offset in enumerate((0, 0.011, 0.023)):
        s = t - offset
        env += np.where(s >= 0, np.exp(-np.clip(s, 0, None) / (0.012 if k < 2 else 0.11)), 0)
    return noise * env * 0.9


def hat(open_=False):
    t = t_(0.35 if open_ else 0.08)
    x = highpass(rng.standard_normal(len(t)), 7500, 4)
    return x * np.exp(-t / (0.09 if open_ else 0.018))


def crash():
    t = t_(2.2)
    x = highpass(rng.standard_normal(len(t)), 4500, 2)
    return x * np.exp(-t / 0.7) * 0.5


def snare():
    t = t_(0.25)
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.05)
    noise = bandpass(rng.standard_normal(len(t)), 1500, 8000) * np.exp(-t / 0.08)
    return tone * 0.4 + noise * 0.6


def supersaw(midi_notes, seconds, voices=7, detune=0.18, cutoff=2600):
    """Detuned saws, a little different in each ear."""
    t = t_(seconds)
    out = np.zeros((len(t), 2))
    for note in midi_notes:
        f = hz(note)
        for v in range(voices):
            cents = (v - (voices - 1) / 2) / ((voices - 1) / 2) * detune * 100
            fv = f * 2 ** (cents / 1200)
            pan = 0.5 + 0.45 * ((v % 2) * 2 - 1) * (abs(v - voices // 2) / (voices // 2))
            w = saw(fv, t, rng.random())
            out[:, 0] += w * (1 - pan)
            out[:, 1] += w * pan
    out /= voices * len(midi_notes) ** 0.6
    for c in range(2):
        out[:, c] = lowpass(out[:, c], cutoff, 2)
    return out


@lru_cache(maxsize=None)
def pluck(midi, seconds=0.32, bright=4500):
    t = t_(seconds)
    f = hz(midi)
    w = 0.6 * saw(f, t) + 0.4 * np.sign(np.sin(2 * np.pi * f * t))
    # A low-pass that closes quickly is what makes it a pluck (one pole, a coefficient per sample).
    cut = 500 + bright * np.exp(-t / 0.06)
    alpha = 1 - np.exp(-2 * np.pi * cut / SR)
    out = np.empty(len(t))
    y = 0.0
    for i, (x, a) in enumerate(zip(w, alpha)):
        y += a * (x - y)
        out[i] = y
    return out * np.exp(-t / 0.16) * 0.5


def bass(midi, seconds):
    t = t_(seconds)
    f = hz(midi)
    sub = np.sin(2 * np.pi * f * t)
    grit = lowpass(saw(f, t), 420, 2) * 0.55
    env = adsr(len(t), 0.004, 0.08, 0.8, 0.03, seconds - 0.12)
    return np.tanh((sub + grit) * 1.3) * env


def swept_noise(seconds, lo, hi, curve=1.0):
    """Noise through a band that glides from lo to hi Hz: fixed bands, crossfaded."""
    t = t_(seconds)
    p = (t / seconds) ** curve
    x = rng.standard_normal(len(t))
    centers = np.geomspace(lo, hi, 14)
    where = np.log(lo * (hi / lo) ** p)
    out = np.zeros(len(t))
    weights = np.zeros(len(t))
    for c in centers:
        w = np.exp(-((where - np.log(c)) ** 2) / (2 * 0.18**2))
        out += bandpass(x, c * 0.75, c * 1.33, 1) * w
        weights += w
    return out / np.maximum(weights, 1e-6)


def riser(seconds):
    t = t_(seconds)
    p = t / seconds
    out = swept_noise(seconds, 300, 9000, 2)
    sweep = np.sin(2 * np.pi * np.cumsum(200 + 1600 * p**2) / SR) * 0.25
    return (out + sweep) * p**1.6


def boom():
    t = t_(2.5)
    f = 38 + 40 * np.exp(-t / 0.15)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.8)


# ---------------------------------------------------------------- the arrangement

# Two breathers: a break and build before the agent's part, and again before the closing run.
SECTION = ["intro"] * 2 + ["drop"] * 13 + ["break", "build"] + ["drop2"] * 11 + ["break", "build"] + ["drop2"] * 6 + ["outro"] * 2
assert len(SECTION) == BARS
FIRST = {name: SECTION.index(name) for name in ("drop", "break", "build", "drop2", "outro")}
# Bars where a section starts (the impacts land on the drops and the outro).
STARTS = {b for b, name in enumerate(SECTION) if b == 0 or SECTION[b - 1] != name}

F_SHARP_M, D, A, E = (
    {"pad": [54, 57, 61, 66], "arp": [66, 69, 73, 78], "bass": 42},
    {"pad": [54, 57, 62, 66], "arp": [66, 69, 74, 78], "bass": 38},
    {"pad": [52, 57, 61, 64], "arp": [64, 69, 73, 76], "bass": 45},
    {"pad": [52, 56, 59, 64], "arp": [64, 68, 71, 76], "bass": 40},
)
CHORDS = (
    [A, E]
    + ([F_SHARP_M, D, A, E] * 4)[:13]
    + [D, E]
    + ([A, E, F_SHARP_M, D] * 3)[:11]
    + [D, E]
    + [A, E, F_SHARP_M, D, F_SHARP_M, E]
    + [A, A]
)
assert len(CHORDS) == BARS


def track():
    """An empty stereo track the length of the arrangement, with room for tails."""
    return np.zeros((int(LENGTH * SR) + SR * 3, 2))


def master(music, path):
    """A gentle squeeze, soft clipping, a fade at the very end, and -1 dBFS peaks."""
    music = music.copy()
    music[:, 0] = highpass(music[:, 0], 28)
    music[:, 1] = highpass(music[:, 1], 28)
    music = np.tanh(music * 1.25) / np.tanh(1.25)
    music = music[: int((LENGTH + 2.5) * SR)]
    tail = int(2.5 * SR)
    music[-tail:] *= np.linspace(1, 0, tail)[:, None] ** 2
    music *= 10 ** (-1 / 20) / np.abs(music).max()
    wavfile.write(path, SR, (music * 32767).astype(np.int16))
