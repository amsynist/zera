# Synthesised sound effects for the Zera scene (no samples needed). Usage: sfx.py out.wav dur [json timeline]
import numpy as np, wave, sys, json
out, dur = sys.argv[1], float(sys.argv[2])
TL = dict(l1s=0.25, l1e=1.85, wind=2.0, slam=2.45, done=3.5, shades=4.45)
if len(sys.argv) > 3: TL.update(json.loads(sys.argv[3]))
sr = 48000; n = int(dur * sr); mix = np.zeros(n); rs = np.random.RandomState(3)
def add(t0, sig, g=1.0):
    i = int(t0 * sr)
    if i >= n or i < 0: return
    sig = sig[: n - i]; mix[i:i + len(sig)] += sig * g
def env(d, a=0.005, k=6): t = np.arange(int(d * sr)) / sr; return t, np.minimum(t / a, 1) * np.exp(-k * t / d)
def tone(f, d, k=6, a=0.004): t, e = env(d, a, k); return np.sin(2 * np.pi * f * t) * e
def sweep(f0, f1, d, k=3): t, e = env(d, 0.01, k); ph = 2 * np.pi * (f0 * t + (f1 - f0) * t * t / (2 * d)); return np.sin(ph) * e
def mixs(*a):
    m = max(len(x) for x in a); o = np.zeros(m)
    for x in a: o[:len(x)] += x
    return o
def hp_noise(d, k=8, hp=0.85):
    t, e = env(d, 0.002, k); x = rs.randn(len(t)); y = np.empty_like(x); p = 0.0; px = 0.0
    for i in range(len(x)): p = hp * (p + x[i] - px); px = x[i]; y[i] = p
    return y * e
tap = lambda: mixs(tone(1900, 0.05, 9) * 0.5, hp_noise(0.03, 10) * 0.25)
add(0.0, sweep(500, 1100, 0.14, 4), 0.22)                                  # pop-in
tapT = TL['l1s'] + 0.55 * (TL['l1e'] - TL['l1s'])
add(tapT, tap(), 0.5); add(tapT + 0.22, tap(), 0.4)                         # marker taps
add(TL['wind'] + 0.12, sweep(260, 880, 0.3, 2.5), 0.3)                      # jump whoosh
s = TL['slam']
add(s, mixs(tone(62, 0.5, 7) * 1.0, tone(124, 0.25, 9) * 0.5, hp_noise(0.12, 9, 0.5) * 0.5), 0.85)  # slam
cd = TL['done'] - s
t = np.arange(int(cd * sr)) / sr                                           # alarm + riser while deploying
klax = 0.6 * np.sign(np.sin(2 * np.pi * (520 + 120 * (np.sin(2 * np.pi * 3.2 * t) > 0)) * t)) * 0.5 + np.sin(2 * np.pi * 260 * t) * 0.5
klax *= (0.5 + 0.5 * np.sin(2 * np.pi * 3.2 * t - 1.2)) * np.minimum(t / 0.1, 1) * np.minimum((cd - t) / 0.04, 1)
add(s + 0.08, klax[: int((cd - 0.08) * sr)], 0.10)
add(s + 0.1, np.sin(2 * np.pi * (180 * t + (900 - 180) * t * t / (2 * cd))) * (t / cd) ** 2 * np.minimum((cd - t) / 0.03, 1), 0.16)
d = TL['done']
for i, f in enumerate([1046.5, 1318.5, 1568.0, 2093.0]): add(d + 0.02 + i * 0.075, mixs(tone(f, 0.9, 5), 0.3 * tone(2 * f, 0.5, 7)), 0.20)   # success chime
add(d + 0.46, mixs(hp_noise(0.35, 6, 0.9) * 0.6, tone(180, 0.12, 8) * 0.8), 0.5)   # confetti pop
sh = TL['shades'] + 0.32
add(sh, mixs(tone(95, 0.2, 8) * 0.8, tone(2637, 0.7, 5) * 0.35, tone(3951, 0.5, 6) * 0.2), 0.55)  # shades land + sparkle
mix = np.tanh(mix * 1.1) * 0.8
st = np.stack([mix, mix], 1); w = wave.open(out, 'w'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes((st * 32767).astype(np.int16).tobytes()); w.close()
print('wrote', out, round(float(np.abs(mix).max()), 2))
