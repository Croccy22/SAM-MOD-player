#!/usr/bin/env python3
"""Compare two renders of the same music (e.g. the engine model against OpenMPT).

Both are cut into segments; each segment is aligned by cross-correlating the
loudness envelopes, then compared by envelope and spectrogram correlation
for each side (left, right). Wrong samples, pitches or missing notes show up
as low correlation in the affected segments.

usage: compare_audio.py test.wav reference.wav [seconds] [--segment 5]
"""

import argparse
import wave

import numpy as np


def load(path):
    with wave.open(path) as w:
        rate, ch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        data = np.frombuffer(w.readframes(w.getnframes()), {2: np.int16, 4: np.int32}[width])
    return rate, data.reshape(-1, ch).T.astype(float)


def frames(x, size, hop):
    n = 1 + (len(x) - size) // hop
    idx = np.arange(size)[None, :] + hop * np.arange(n)[:, None]
    return x[idx]


def envelope(x, rate, ms=10):
    hop = int(rate * ms / 1000)
    return np.sqrt(frames(x, hop, hop).astype(float) ** 2).mean(axis=1)


def spectrogram(x, size=2048, hop=480):
    f = frames(x, size, hop) * np.hanning(size)
    s = np.abs(np.fft.rfft(f, axis=1))[:, :size // 4]      # up to rate/4
    return np.log1p(s)


def corr(a, b):
    a, b = a.ravel() - a.mean(), b.ravel() - b.mean()
    return float((a * b).sum() / np.sqrt((a * a).sum() * (b * b).sum() + 1e-12))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("test")
    ap.add_argument("reference")
    ap.add_argument("seconds", type=float, nargs="?")
    ap.add_argument("--segment", type=float, default=5)
    ap.add_argument("--search", type=float, default=0.25, help="alignment search, seconds")
    ap.add_argument("--mono", action="store_true", help="compare left + right")
    args = ap.parse_args()

    rate, a = load(args.test)
    rate_b, b = load(args.reference)
    assert rate == rate_b
    if args.mono:
        a, b = a.sum(axis=0, keepdims=True).repeat(2, 0), b.sum(axis=0, keepdims=True).repeat(2, 0)
    length = min(a.shape[1], b.shape[1])
    if args.seconds:
        length = min(length, int(args.seconds * rate))

    seg = int(args.segment * rate)
    search = int(args.search * rate)
    hop = rate // 100
    print(f"{'time':>6}  {'shift ms':>8}  {'env L':>6} {'env R':>6}  {'spec L':>6} {'spec R':>6}")
    env_b = envelope(b[0] + b[1], rate)
    worst = 1.0
    for start in range(0, length - seg - search, seg):
        # align on the summed envelope (10 ms steps)
        ea = envelope(a[0, start:start + seg] + a[1, start:start + seg], rate)
        first = start // hop
        best, shift = -2, 0
        for s in range(-search // hop, search // hop + 1):
            if first + s < 0 or first + s + len(ea) > len(env_b):
                continue
            c = corr(ea, env_b[first + s:first + s + len(ea)])
            if c > best:
                best, shift = c, s * hop
        bs = start + shift
        row = []
        for side in (0, 1):
            row.append(corr(envelope(a[side, start:start + seg], rate),
                            envelope(b[side, bs:bs + seg], rate)))
        for side in (0, 1):
            row.append(corr(spectrogram(a[side, start:start + seg]),
                            spectrogram(b[side, bs:bs + seg])))
        worst = min(worst, *row)
        print(f"{start / rate:6.1f}  {shift / rate * 1000:8.0f}  " +
              f"{row[0]:6.3f} {row[1]:6.3f}  {row[2]:6.3f} {row[3]:6.3f}")
    print(f"lowest correlation: {worst:.3f}")


if __name__ == "__main__":
    main()
