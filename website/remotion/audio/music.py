"""The promo's music: 38 bars of house at 120 BPM on the arrangement in synth.py, so the drop lands on
the first click, a breakdown under drawing and another before the closing run, and the final hit on the end card.

    python3 remotion/audio/music.py   writes music.wav
"""

import numpy as np

from synth import (
    BAR, BEAT, CHORDS, FIRST, OUT, SECTION, STARTS, SR, bass, boom, clap, crash, hat, kick, lowpass, master, place,
    pluck, reverb, riser, snare, supersaw, t_, track,
)


def duck(x, depth=0.7, release=0.11, offsets=(0,)):
    """Sidechain to a four-on-the-floor kick."""
    tt = t_(len(x) / SR) % BEAT
    env = np.ones(len(x))
    for o in offsets:
        env = np.minimum(env, 1 - depth * np.exp(-((tt - o) % BEAT) / release))
    return x * env[:, None] if x.ndim == 2 else x * env



def snare_roll(drums, t0, gain=0.42):
    """Sixteenth then thirty-second notes into the next bar, getting louder."""
    S = snare()
    for k in range(16):
        place(drums, S, t0 + 2 * BEAT + k * BEAT / 8, 0.1 + gain * k / 15)


def impact(fx, t0, gain=1.0):
    place(fx, crash(), t0, 0.5 * gain)
    place(fx, boom(), t0, 0.55 * gain)


def house():
    """Bright house: pumping supersaw chords, offbeat bass, a sixteenth-note arpeggio."""
    drums, pads, arps, low, fx = track(), track(), track(), track(), track()
    K, CL, HC, HO = kick(), clap(), hat(), hat(True)
    for b, (chord, section) in enumerate(zip(CHORDS, SECTION)):
        t0 = b * BAR
        full = section in ("drop", "drop2")
        if full or section == "build":
            for beat in range(4):
                place(drums, K, t0 + beat * BEAT, 0.95)
        if section == "intro":
            for beat in range(4):
                place(drums, lowpass(K, 900), t0 + beat * BEAT, 0.5 + 0.2 * b)
                place(drums, lowpass(HO, 4000), t0 + beat * BEAT + BEAT / 2, 0.05 + 0.04 * b)
        if full:
            for beat in (1, 3):
                place(drums, CL, t0 + beat * BEAT, 0.42)
            for s in range(16):
                place(drums, HC * (0.55 if s % 2 else 0.8), t0 + s * BEAT / 4 + (0.008 if s % 2 else 0), 0.16)
            for beat in range(4):
                place(drums, HO, t0 + beat * BEAT + BEAT / 2, 0.13)
        if b == 1 or section == "break":
            for s in range(8, 16):
                place(drums, HC, t0 + s * BEAT / 4, 0.1)
        if b == 1 or section == "build":
            snare_roll(drums, t0)
        if b in STARTS and section in ("drop", "drop2", "outro"):
            impact(fx, t0)
        if full:
            for beat in range(4):
                place(low, bass(chord["bass"], BEAT / 2 - 0.02), t0 + beat * BEAT + BEAT / 2, 0.5)
                if section == "drop2":
                    place(low, bass(chord["bass"], BEAT / 4), t0 + beat * BEAT, 0.28)
        if section == "break":
            place(low, bass(chord["bass"], BAR - 0.05) * 0.8, t0, 0.45)
            for s in range(16):
                place(drums, HC * (0.5 if s % 2 else 0.8), t0 + s * BEAT / 4, 0.12)
            for beat in (1, 3):
                place(drums, CL, t0 + beat * BEAT, 0.25)
        if section == "build":
            for s in range(8):
                place(low, bass(chord["bass"], BEAT / 2 - 0.02), t0 + s * BEAT / 2, 0.3 + 0.03 * s)
        if section == "outro":
            if b == FIRST["outro"]:
                pad = supersaw(chord["pad"] + [chord["pad"][0] - 12], 2 * BAR + 2, cutoff=3200)
                place(pads, pad * np.exp(-t_(2 * BAR + 2) / 1.6)[:, None], t0, 0.55)
            continue
        cutoff = {"intro": 900 + 1300 * b, "break": 2200, "build": 2000}.get(section, 3000)
        pad = supersaw(chord["pad"], BAR, cutoff=cutoff)
        fade = np.minimum(1, np.minimum(t_(BAR) / 0.01, (BAR - t_(BAR)) / 0.02))[:, None]
        if full or section == "build":
            pad = duck(pad, 0.72)
        place(pads, pad * fade, t0, {"intro": 0.5 + 0.15 * b, "break": 0.6}.get(section, 0.42))
        if section != "intro" or b == 1:
            order = [0, 1, 2, 3, 2, 1, 2, 3, 0, 1, 2, 3, 3, 2, 1, 2]
            for s, idx in enumerate(order):
                if section == "intro" and s < 8:
                    continue
                note = chord["arp"][idx]
                place(arps, pluck(note), t0 + s * BEAT / 4, 0.26)
                if section == "drop2" and s % 2 == 0:
                    place(arps, pluck(note + 12, 0.25, 6000), t0 + s * BEAT / 4, 0.12)
        if section == "build" or b == 1:
            place(fx, riser(BAR), t0, 0.32)
    # A ping-pong echo on the arpeggio: a dotted eighth on the left, a quarter on the right.
    echo = np.zeros_like(arps)
    d1, d2 = int(0.75 * BEAT * SR), int(1.5 * BEAT * SR)
    echo[d1:, 0] += arps[:-d1, 1] * 0.35
    echo[d2:, 1] += arps[:-d2, 0] * 0.25
    arps = arps + echo
    return drums + low + reverb(pads, 0.25) + reverb(arps, 0.3) + reverb(fx, 0.4)


if __name__ == "__main__":
    master(house(), f"{OUT}/music.wav")
    print("wrote music.wav")
