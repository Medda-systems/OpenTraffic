"""The promo's sound effects: clicks, pops, chimes, dings, a sonar ping, typing, whooshes.

    python3 remotion/audio/sfx.py
"""

import os

import numpy as np
from scipy.io import wavfile

from synth import OUT, SR, highpass, hz, reverb, rng, swept_noise, t_


def save(name, x, peak=0.9):
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    x = x * peak / max(np.abs(x).max(), 1e-9)
    wavfile.write(os.path.join(OUT, f"{name}.wav"), SR, (x * 32767).astype(np.int16))


def bell(midi, seconds=1.2, decay=0.35, ratio=3.5, index=2.0):
    t = t_(seconds)
    f = hz(midi)
    mod = np.sin(2 * np.pi * f * ratio * t) * index * np.exp(-t / 0.12)
    return np.sin(2 * np.pi * f * t + mod) * np.exp(-t / decay)


def click_sound():
    t = t_(0.12)
    x = np.zeros(len(t))
    for at, g in ((0.0, 1.0), (0.07, 0.6)):
        s = t - at
        tick = highpass(rng.standard_normal(len(t)), 2500) * np.where(s >= 0, np.exp(-np.clip(s, 0, None) / 0.0025), 0)
        thump = np.sin(2 * np.pi * 1400 * s) * np.where(s >= 0, np.exp(-np.clip(s, 0, None) / 0.006), 0)
        x += (tick * 0.7 + thump * 0.5) * g
    return x


save("click", click_sound(), 0.8)

t = t_(0.09)
save("pop", np.sin(2 * np.pi * np.cumsum(500 + 900 * (t / 0.09) ** 0.5) / SR) * np.exp(-t / 0.03), 0.7)

chime = np.zeros(int(1.6 * SR))
for at, note in ((0, 88), (0.09, 95)):
    s = bell(note, 1.4, 0.4)
    chime[int(at * SR) : int(at * SR) + len(s)] += s[: len(chime) - int(at * SR)]
save("chime", reverb(chime, 0.35), 0.75)

for k, note in enumerate((84, 88, 91, 96)):
    save(f"ding{k + 1}", reverb(bell(note, 1.0, 0.25, 2.0, 1.2), 0.25), 0.6)

success = np.zeros(int(1.4 * SR))
for at, note in ((0, 91), (0.08, 96), (0.16, 100)):
    s = bell(note, 1.1, 0.3, 2.0, 1.5)
    success[int(at * SR) : int(at * SR) + len(s)] += s[: len(success) - int(at * SR)]
save("success", reverb(success, 0.3), 0.7)

t = t_(1.2)
sonar = np.sin(2 * np.pi * 1180 * t) * np.exp(-t / 0.18)
save("ping", reverb(sonar + np.roll(sonar, int(0.22 * SR)) * 0.35, 0.4), 0.55)

for k in range(3):
    t = t_(0.05)
    x = highpass(rng.standard_normal(len(t)), 1800 + 600 * k) * np.exp(-t / 0.006) + np.sin(2 * np.pi * (2600 + 300 * k) * t) * np.exp(-t / 0.004) * 0.4
    save(f"type{k + 1}", x, 0.5)


def whoosh(seconds=0.45, lo=300, hi=5000):
    p = t_(seconds) / seconds
    return swept_noise(seconds, lo, hi) * np.sin(np.pi * p) ** 2


save("whoosh", np.stack([whoosh(), whoosh()], axis=1), 0.5)

t = t_(0.6)
save("join", bell(81, 0.6, 0.12, 1.0, 0.6) * 0.6 + np.sin(2 * np.pi * np.cumsum(700 + 500 * (t / 0.6)) / SR) * np.exp(-t / 0.05) * 0.4, 0.55)

print(f"wrote sound effects to {os.path.abspath(OUT)}")
