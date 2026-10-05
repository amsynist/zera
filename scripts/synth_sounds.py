"""Zera's sound kit: every cue synthesised from sines, FM bells and filtered noise.

All notes come from one major-pentatonic set (C D E G A) so any two cues that overlap still
sound in tune. Writes 44.1 kHz 16-bit mono WAVs to Resources/Sounds; the seed is fixed, so reruns give the
same files.
"""
import json, os, wave
import numpy as np
from scipy.signal import butter, sosfilt, fftconvolve

SR = 44100
# Writes straight into the app bundle's sound folder: python3 scripts/synth_sounds.py
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Sounds")
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(7)

N = {"F4": 349.23, "A4": 440.0, "C5": 523.25, "D5": 587.33, "E5": 659.25, "G5": 783.99, "A5": 880.0,
     "C6": 1046.5, "D6": 1174.66, "E6": 1318.51, "G6": 1567.98, "A6": 1760.0, "C7": 2093.0, "E7": 2637.02}


def t_(d): return np.arange(int(SR * d)) / SR


def env(d, a=0.004, decay=8.0, release=0.01):
    t = t_(d)
    e = np.minimum(1, t / max(a, 1e-4)) * np.exp(-decay * np.maximum(0, t - a))
    r = min(int(SR * release), len(t))
    if r: e[-r:] *= np.linspace(1, 0, r)
    return e


def osc(freq, d, shape="sine"):
    t = t_(d)
    if np.ndim(freq):
        f = np.asarray(freq, float)[: len(t)]
        f = np.concatenate([f, np.full(len(t) - len(f), f[-1])])   # hold the last pitch
    else:
        f = np.full(t.shape, float(freq))
    ph = 2 * np.pi * np.cumsum(f) / SR
    if shape == "sine": return np.sin(ph)
    if shape == "tri": return 2 / np.pi * np.arcsin(np.sin(ph))
    if shape == "soft": return np.sin(ph) + 0.18 * np.sin(2 * ph) + 0.06 * np.sin(3 * ph)
    raise ValueError(shape)


def glide(f0, f1, d, curve=1.0):
    u = np.linspace(0, 1, int(SR * d)) ** curve
    return f0 * (f1 / f0) ** u


def bell(f, d=0.6, decay=7.0, bright=1.0):
    """Glassy FM bell: the modulator's index dies away faster than the note."""
    t = t_(d)
    idx = 2.2 * bright * np.exp(-t * 14)
    mod = np.sin(2 * np.pi * f * 3.5 * t) * idx
    return np.sin(2 * np.pi * f * t + mod) * env(d, 0.002, decay)


def pluck(f, d=0.18, decay=22.0):
    t = t_(d)
    return (np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t) * np.exp(-t * 40)) * env(d, 0.002, decay)


def marimba(f, d=0.5):
    t = t_(d)
    return (np.sin(2 * np.pi * f * t) * np.exp(-t * 9) + 0.35 * np.sin(2 * np.pi * f * 4 * t) * np.exp(-t * 45)) * env(d, 0.002, 0, 0.02)


def noise(d): return rng.standard_normal(int(SR * d))


def band(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], btype="band", fs=SR, output="sos"), x)


def lp(x, fc, order=2): return sosfilt(butter(order, fc, btype="low", fs=SR, output="sos"), x)


def hp(x, fc, order=2): return sosfilt(butter(order, fc, btype="high", fs=SR, output="sos"), x)


def sweep_noise(d, f0, f1, q=0.6):
    """Noise through a band-pass whose centre glides f0 → f1, in short overlapping blocks."""
    x = noise(d)
    n = len(x); out = np.zeros(n); blk = 512
    centres = np.geomspace(f0, f1, n // blk + 1)
    win = np.hanning(blk * 2)
    for i, c in enumerate(centres):
        s = i * blk
        seg = x[max(0, s - blk): s + blk]
        if len(seg) < 32: continue
        y = band(seg, c * (1 - q / 2), min(SR / 2 - 100, c * (1 + q / 2)))
        w = win[: len(y)] if len(y) == len(win) else np.hanning(len(y))
        out[max(0, s - blk): max(0, s - blk) + len(y)] += y * w
    return out


def mix(d, *parts):
    """parts: (signal, start_seconds, gain)"""
    out = np.zeros(int(SR * d))
    for sig, at, g in parts:
        s = int(SR * at)
        e = min(len(out), s + len(sig))
        out[s:e] += sig[: e - s] * g
    return out


_ir = None
def room(x, wet=0.14):
    """A small, soft room so the cues sit in the same space."""
    global _ir
    if _ir is None:
        t = t_(0.45)
        _ir = lp(noise(0.45), 5000) * np.exp(-t * 11)
        _ir /= np.sqrt(np.sum(_ir ** 2))
    tail = fftconvolve(np.concatenate([x, np.zeros(int(SR * 0.3))]), _ir)[: len(x) + int(SR * 0.3)]
    dry = np.concatenate([x, np.zeros(int(SR * 0.3))])
    return dry * (1 - wet) + tail * wet


def finish(x, peak):
    x = room(x)
    # trim trailing silence, short fade
    thr = np.max(np.abs(x)) * 0.002
    idx = np.where(np.abs(x) > thr)[0]
    x = x[: (idx[-1] + int(SR * 0.02)) if len(idx) else len(x)]
    f = int(SR * 0.008); x[-f:] *= np.linspace(1, 0, f)
    return x / (np.max(np.abs(x)) + 1e-9) * peak


SOUNDS = {}
def sound(name, peak):
    def deco(fn):
        SOUNDS[name] = (fn, peak); return fn
    return deco

# ---------------------------------------------------------------- Zera

@sound("zera_tap_1", 0.32)
def _(): return osc(glide(520, 820, 0.12, 0.6), 0.12, "soft") * env(0.12, 0.003, 26)
@sound("zera_tap_2", 0.32)
def _(): return osc(glide(590, 930, 0.12, 0.6), 0.12, "soft") * env(0.12, 0.003, 26)
@sound("zera_tap_3", 0.32)
def _(): return osc(glide(470, 740, 0.12, 0.6), 0.12, "soft") * env(0.12, 0.003, 26)

@sound("zera_huff", 0.36)
def _():
    b1 = osc(glide(460, 330, 0.14), 0.14, "soft") * env(0.14, 0.003, 18)
    b2 = osc(glide(400, 250, 0.18), 0.18, "soft") * env(0.18, 0.003, 14)
    puff = lp(noise(0.22), 900) * env(0.22, 0.03, 12)
    return mix(0.5, (b1, 0, 1), (b2, 0.13, 1), (puff, 0.2, 0.5))

@sound("zera_hello", 0.26)
def _():
    a = osc(glide(N["G5"] * 0.97, N["G5"], 0.07), 0.07, "soft") * env(0.07, 0.004, 30)
    b = osc(glide(N["C6"] * 0.97, N["C6"] * 1.02, 0.1), 0.1, "soft") * env(0.1, 0.004, 22)
    return mix(0.25, (a, 0, 1), (b, 0.075, 1))

@sound("zera_wake", 0.26)
def _():
    d = 0.55
    f = np.concatenate([glide(330, 620, 0.3, 0.8), glide(620, 470, d - 0.3)])
    vib = 1 + 0.012 * np.sin(2 * np.pi * 7 * t_(d))
    return osc(f * vib, d, "soft") * env(d, 0.05, 3.5, 0.08)

@sound("zera_lift", 0.26)
def _():
    d = 0.32
    vib = 1 + 0.02 * np.sin(2 * np.pi * 11 * t_(d))
    return osc(glide(420, 980, d, 0.7) * vib, d, "soft") * env(d, 0.02, 5, 0.05)

@sound("zera_land", 0.4)
def _():
    thud = osc(glide(170, 85, 0.14), 0.14) * env(0.14, 0.002, 22)
    click = hp(noise(0.012), 3000) * env(0.012, 0.0005, 300)
    return mix(0.2, (thud, 0, 1), (click, 0, 0.25))

@sound("caption_pop", 0.14)
def _(): return pluck(N["E6"], 0.07, 60)

# ---------------------------------------------------------------- Island

@sound("island_open", 0.22)
def _():
    sw = sweep_noise(0.24, 500, 3800) * env(0.24, 0.12, 6, 0.05)
    return mix(0.6, (sw, 0, 1), (bell(N["E6"], 0.45, 9, 0.6), 0.16, 0.5))

@sound("island_close", 0.16)
def _(): return sweep_noise(0.2, 3200, 500) * env(0.2, 0.02, 9, 0.05)

@sound("tab_switch", 0.14)
def _():
    return mix(0.06, (pluck(2350, 0.05, 90), 0, 1), (hp(noise(0.01), 4000) * env(0.01, 0.0005, 400), 0, 0.3))

@sound("button_press", 0.16)
def _(): return mix(0.06, (pluck(1500, 0.05, 110), 0, 1), (hp(noise(0.008), 3500) * env(0.008, 0.0005, 500), 0, 0.35))

# ---------------------------------------------------------------- Files and the shelf

@sound("file_hover", 0.16)
def _(): return mix(0.5, (bell(N["A6"], 0.3, 14, 0.5), 0, 1), (bell(N["C7"], 0.3, 14, 0.5), 0.06, 0.8), (bell(N["E7"], 0.3, 14, 0.5), 0.12, 0.6))

@sound("file_catch", 0.34)
def _():
    plop = osc(glide(280, 640, 0.06, 0.5), 0.12) * env(0.12, 0.002, 30)
    return mix(0.6, (plop, 0, 1), (bell(N["C7"], 0.4, 10, 0.7), 0.07, 0.35), (bell(N["E7"], 0.4, 10, 0.7), 0.13, 0.3))

@sound("file_reject", 0.3)
def _():
    b = lp(osc(glide(230, 175, 0.16), 0.16, "tri"), 1200) * env(0.16, 0.003, 16)
    return mix(0.3, (b, 0, 1), (b * 0.6, 0.11, 0.7))

@sound("file_drag_out", 0.16)
def _():
    flick = hp(noise(0.05), 2500) * env(0.05, 0.002, 70)
    return mix(0.12, (flick, 0, 0.7), (pluck(980, 0.08, 45), 0.01, 0.6))

@sound("screenshot", 0.3)
def _():
    c1 = band(noise(0.03), 1500, 6000) * env(0.03, 0.0005, 160)
    c2 = band(noise(0.04), 1000, 5000) * env(0.04, 0.0005, 120)
    return mix(0.55, (c1, 0, 1), (c2, 0.07, 0.8), (bell(N["E7"], 0.35, 12, 0.5), 0.15, 0.25))

@sound("timer_set", 0.24)
def _():
    r = [pluck(1800, 0.03, 160) for _ in range(3)]
    return mix(0.35, (r[0], 0, 0.7), (r[1], 0.045, 0.7), (r[2], 0.09, 0.7), (pluck(N["G6"], 0.2, 18), 0.14, 0.9))

# ---------------------------------------------------------------- Claude Code

@sound("claude_start", 0.24)
def _():
    d = 0.42
    a = osc(N["C5"], d, "soft") * env(d, 0.06, 5, 0.05)
    b = osc(N["G5"], d - 0.12, "soft") * env(d - 0.12, 0.05, 5, 0.05)
    return mix(d, (a, 0, 0.8), (b, 0.12, 0.8))

@sound("claude_approval", 0.42)
def _(): return mix(0.9, (bell(N["E6"], 0.6, 6), 0, 1), (bell(N["A6"], 0.7, 5), 0.16, 0.9))

@sound("claude_approved", 0.32)
def _(): return mix(0.45, (pluck(N["C6"]), 0, 1), (pluck(N["E6"]), 0.06, 1), (pluck(N["G6"], 0.3, 12), 0.12, 1))

@sound("claude_rejected", 0.28)
def _():
    a = osc(N["G5"], 0.16, "tri") * env(0.16, 0.004, 14)
    b = osc(N["D5"], 0.26, "tri") * env(0.26, 0.004, 9)
    return lp(mix(0.4, (a, 0, 1), (b, 0.1, 1)), 2600)

@sound("claude_done", 0.34)
def _():
    run = ["C6", "D6", "E6", "G6", "A6", "C7"]
    parts = [(bell(N[n], 0.5, 9, 0.8), i * 0.045, 0.75) for i, n in enumerate(run)]
    shimmer = hp(noise(0.5), 6000) * env(0.5, 0.15, 6, 0.1)
    parts.append((shimmer, 0.18, 0.06))
    return mix(0.95, *parts)

# ---------------------------------------------------------------- Reminders

@sound("reminder_chime", 0.42)
def _(): return mix(1.5, (bell(N["G5"], 1.1, 3.2), 0, 1), (bell(N["E5"], 1.2, 3.0), 0.32, 0.9))

@sound("reminder_water", 0.38)
def _():
    def drop(f0, f1, d=0.09):
        return osc(glide(f0, f1, d, 0.35), d) * env(d, 0.002, 30)
    return mix(0.5, (drop(520, 1300), 0, 1), (drop(640, 1560), 0.12, 0.8), (drop(460, 1180), 0.26, 0.65))

@sound("reminder_break", 0.28)
def _():
    d = 1.3
    chord = sum(osc(N[n], d, "sine") * (1 + 0.004 * np.sin(2 * np.pi * (4 + i) * t_(d))) for i, n in enumerate(["C5", "E5", "G5"]))
    return chord * env(d, 0.35, 2.4, 0.2)

@sound("reminder_calendar", 0.34)
def _(): return mix(0.75, (marimba(N["A5"], 0.5), 0, 1), (marimba(N["D6"], 0.55), 0.14, 0.9))

@sound("reminder_done", 0.3)
def _(): return mix(0.5, (pluck(2200, 0.03, 140), 0, 0.6), (bell(N["C7"], 0.4, 10, 0.6), 0.04, 1))

# ---------------------------------------------------------------- GitHub

@sound("github_ping", 0.3)
def _(): return bell(N["A6"], 0.55, 7, 0.7)

@sound("github_ci_failed", 0.3)
def _():
    a = lp(osc(N["A4"], 0.18, "tri"), 1400) * env(0.18, 0.004, 12)
    b = lp(osc(N["F4"], 0.3, "tri"), 1200) * env(0.3, 0.004, 8)
    return mix(0.5, (a, 0, 1), (b, 0.16, 1))

@sound("github_ci_passed", 0.3)
def _(): return mix(0.5, (pluck(N["E6"], 0.2, 16), 0, 1), (pluck(N["A6"], 0.3, 11), 0.08, 1))


def write(name, x):
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(f"{OUT}/{name}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())


peaks = {}
for name, (fn, peak) in SOUNDS.items():
    x = finish(fn(), peak)
    write(name, x)
    n = 120
    chunks = np.array_split(np.abs(x), n)
    peaks[name] = {"ms": round(len(x) / SR * 1000), "peaks": [round(float(c.max()) / peak, 3) if len(c) else 0 for c in chunks]}
print(len(SOUNDS), "sounds")
for k, v in peaks.items(): print(f"{k:22s} {v['ms']:5d} ms")
