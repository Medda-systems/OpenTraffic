"""Modern, organic launch cue: sampled drums, bass, piano and muted guitar.

python3 remotion/audio/organic_promo.py (from website/, on macOS).
120 BPM, 50 seconds. Drops 0/28/42s; final hit 48s. Uses Apple's offline
sampler and GeneralUser GS, which permits private/commercial music creation.
Instrument cache, score and rendered stems are in the ignored out directory.
Sound bank source: https://github.com/mrbumpy409/GeneralUser-GS
"""
import json
import subprocess
import urllib.request
from pathlib import Path

import numpy as np
import soundfile as sf

from bass_drop import DEST, N, SR, export, highpass, lowpass, put, room, time

RNG = np.random.default_rng(62026)
CACHE = DEST / ".instruments"
STEMS = DEST / ".organic-stems"


def compose():
    CACHE.mkdir(parents=True, exist_ok=True)
    STEMS.mkdir(parents=True, exist_ok=True)
    for source, name in (("GeneralUser-GS.sf2", "GeneralUser-GS.sf2"),
                         ("documentation/LICENSE.txt", "LICENSE.txt")):
        path = CACHE / name
        if not path.exists():
            urllib.request.urlretrieve("https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/" + source, path)
    parts = {name: {"name": name, "program": program, "percussion": percussion, "notes": []}
             for name, program, percussion in [("drums", 0, True), ("bass", 33, False),
                                               ("piano", 0, False), ("guitar", 28, False),
                                               ("strings", 48, False)]}

    def note(part, at, midi, velocity, duration, human=True):
        at += float(RNG.uniform(-.003, .005)) if human else 0
        parts[part]["notes"].append({"time": max(0, at), "note": int(midi),
                                     "velocity": int(np.clip(velocity, 1, 127)), "duration": duration})

    # F#m9 - Dmaj9 - Amaj9 - E(add9), voiced with deliberate space above bass.
    harmony = [(30, [54, 57, 61, 68]), (38, [54, 57, 61, 64]),
               (33, [52, 56, 59, 61]), (40, [52, 56, 59, 66])]
    kick_times = []
    for bar in range(24):
        start = bar * 2
        root, voices = harmony[(bar // 2) % 4] if bar < 21 else harmony[0]
        big = bar >= 14
        build = 6 <= bar < 14
        stripped = bar in (12, 13)
        pre = bar in (13, 20)
        growth = (bar - 6) / 7 if build else 1
        # A full-tempo broken beat: strong downbeats and syncopated pickups.
        pattern = [(0, 120), (3, 86), (6, 110), (8, 119), (10.5, 101)]
        if bar % 2:
            pattern += [(14.5, 86)]
        if stripped:
            pattern = [(0, 106), (8, 103)] if bar == 12 else [(0, 103)]
        for step, vel in pattern:
            if pre and step >= 12:
                continue
            at = start + step / 8
            note("drums", at, 36, vel, .16, False)
            kick_times.append(at)
        for step in (4, 12):
            if pre and step == 12:
                continue
            note("drums", start + step / 8 + .007, 38, 117 if big else 110, .16)
            note("drums", start + step / 8 + .010, 39, 53 if big else 41, .11)
        if not stripped:
            note("drums", start + 11 / 8 + .016, 38, 35, .065)
        for step in range(0, 16, 2):
            if pre and step >= 12:
                continue
            velocity = [68, 48, 65, 46][(step // 2) % 4] + (8 if big else 0)
            note("drums", start + step / 8 + (.012 if step % 4 == 2 else 0), 42, velocity, .065)
        if big or (build and bar >= 9):
            for step in (3, 7, 11, 15):
                if pre and step >= 12:
                    continue
                note("drums", start + step / 8 + .016, 82, 40 if not big else 54, .06)
        if big:
            for step in (2, 10):
                note("drums", start + step / 8, 54, 47, .14)
        if bar in (3, 5, 9, 17, 23):
            for step, midi, vel in ((14, 45, 71), (15, 43, 86), (15.5, 38, 65)):
                note("drums", start + step / 8, midi, vel, .13)
        if not stripped:
            for step, interval, length in [(0, 12, .33), (3, 12, .22), (6, 19, .18),
                                           (8, 12, .30), (10.5, 12, .29), (14, 24, .17)]:
                if pre and step >= 12:
                    continue
                note("bass", start + step / 8, root + interval, 105 if big else 97, length)
        # Short, expressive acoustic piano chords; motif every four bars, not an arp loop.
        for step, velocity in ((0, 81), (6, 65), (11, 72)):
            if pre and step >= 10:
                continue
            for k, midi in enumerate(voices):
                note("piano", start + step / 8 + k * .006, midi, velocity - k * 3,
                     .34 if big else .48)
        if bar % 4 in (0, 1) or (build and bar % 2 == 0):
            phrase = [(2, 73), (5, 76), (10, 78)] if bar % 4 == 0 else [(2, 76), (7, 73), (12, 69)]
            for step, midi in phrase:
                if pre and step >= 10:
                    continue
                note("piano", start + step / 8, midi, 72 if big else 65, .30)
        # Muted guitar adds rhythmic grain without an electronic lead or pumping pad.
        if not stripped:
            for step in (2, 7, 10, 15) if big else (2, 10):
                if pre and step >= 12:
                    continue
                for k, midi in enumerate(voices[1:]):
                    note("guitar", start + step / 8 + k * .006, midi + 12, 76 - k * 6, .08)
        if build or big:
            for midi in voices[1:]:
                note("strings", start, midi + 12, 35 + int(growth * 20) if build else 39, 1.6)
    # Snare/tom builds replace synthetic noise risers; tiny gaps expose the drop.
    for start, end in ((24, 27.75), (40, 41.75)):
        steps = np.arange(start, end, .25)
        for i, at in enumerate(steps):
            note("drums", float(at), 38, 40 + round(54 * i / max(1, len(steps) - 1)), .11)
        for at in np.arange(end - .5, end, .125):
            note("drums", float(at), 43 if at < end - .25 else 45, 82, .1)
    for at in (0, 28, 42, 48):
        note("drums", at, 49, 72 if at != 48 else 87, .8, False)
        if at == 48:
            note("drums", at, 36, 123, .20, False)
            kick_times.append(at)
            note("bass", at, 42, 112, 1.0, False)
            for k, midi in enumerate([54, 57, 61, 66]):
                note("piano", at + k * .008, midi, 95 - k * 5, 1.4, False)
                note("strings", at, midi + 12, 50, .65, False)
    score = STEMS / "score.json"
    score.write_text(json.dumps({"seconds": 50, "parts": list(parts.values())}))
    renderer = Path(__file__).with_name("render_instruments.swift")
    subprocess.run(["swift", str(renderer), str(CACHE / "GeneralUser-GS.sf2"), str(score), str(STEMS)], check=True)
    tracks = {}
    for name in parts:
        x, sr = sf.read(STEMS / f"{name}.wav")
        assert sr == SR and len(x) == N and np.isfinite(x).all(), name
        tracks[name] = x
        print(name, "peak", round(float(abs(x).max()), 4))
    drums = tracks["drums"]
    # Parallel transient support retains the sampled drum kit's texture.
    punch = np.zeros_like(drums)
    t = time(.20)
    f = 49 + 45 * np.exp(-t / .019)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / .063) * np.minimum(t / .0007, 1)
    for at in kick_times:
        put(punch, body, at, .085)
    bass = tracks["bass"]
    bass = np.stack([highpass(bass[:, c], 38, 2) for c in range(2)], axis=1)
    # Firm low end, modest gain recovery rather than the previous pumping sidechain.
    gain = np.ones(N)
    for at in kick_times:
        i = round(at * SR)
        recovery = 1 - .30 * np.exp(-time(.15) / .034)
        gain[i:i + len(recovery)] = np.minimum(gain[i:i + len(recovery)], recovery)
    bass *= gain[:, None]
    piano = room(tracks["piano"], .16)
    guitar = room(tracks["guitar"], .09)
    strings = room(tracks["strings"], .20)
    mix = drums * 1.45 + punch + bass * 1.30 + piano * .50 + guitar * 2.2 + strings * .70
    # Brief musical breath before drop two and the final drop, with natural decay.
    for end in (28, 42):
        a, b = round((end - .25) * SR), end * SR
        mix[a:b] *= np.linspace(1, .035, b - a)[:, None]**2
    for c in range(2):
        x = highpass(mix[:, c], 30, 2)
        mix[:, c] = x + .23 * highpass(x, 2200, 2)
    mix[-int(.4 * SR):] *= np.linspace(1, 0, int(.4 * SR))[:, None]**2
    return mix


if __name__ == "__main__":
    export(compose(), "7-modern-organic-promo", "OpenTraffic — Modern Organic Promo")
