"""Collect multitrack.sh's cascade into numbered float WAVs and null-test them against the mix."""
import glob
import os
import sys

import numpy as np
import soundfile as sf

OUT = sys.argv[1]
W = os.path.join(OUT, "_work")


def pick(sub, tag):
    hits = [f for f in glob.glob(os.path.join(W, sub, "*")) if f"({tag.lower()})" in os.path.basename(f).lower()]
    if not hits:
        raise SystemExit(f"missing ({tag}) in {sub}: {os.listdir(os.path.join(W, sub))}")
    return hits[0]


mix, sr = sf.read(os.path.join(W, "mix.wav"), dtype="float32", always_2d=True)
N = len(mix)


def load(path):
    y, r = sf.read(path, dtype="float32", always_2d=True)
    assert r == sr, (path, r)
    if y.shape[1] == 1:
        y = np.repeat(y, 2, 1)
    return np.pad(y, ((0, max(0, N - len(y))), (0, 0)))[:N]


def db(x):
    return 20 * np.log10(np.sqrt(np.mean(np.square(x, dtype=np.float64))) + 1e-12)


# `stems -t` keeps true level, so vocals + instrumental should already sum to the mix with
# gains of 1. Fit them anyway: if audio-separator ever re-normalizes again, this catches it
# and corrects every stem cascaded from stage 1.
voc1, inst1 = load(pick("1_rofo", "Vocals")), load(pick("1_rofo", "Instrumental"))
A = np.stack([voc1.ravel(), inst1.ravel()], 1).astype(np.float64)
(g_voc, g_inst), *_ = np.linalg.lstsq(A, mix.ravel().astype(np.float64), rcond=None)
flag = "" if max(abs(g_voc - 1), abs(g_inst - 1)) < 0.01 else "   <- corrected (separator re-normalized)"
print(f"stage-1 gains: vocals x{g_voc:.4f}, instrumental x{g_inst:.4f}{flag}")

other = load(os.path.join(W, "other.wav"))
piano = load(pick("4_6s", "Piano"))
guitar = load(pick("4_6s", "Guitar"))

tracks = [
    ("01 Lead Vocal", g_voc * load(pick("2_karaoke", "Vocals"))),
    ("02 Backing Vocals", g_voc * load(pick("2_karaoke", "Instrumental"))),
    ("03 Kick", g_inst * load(pick("5_drumsep", "kick"))),
    ("04 Snare", g_inst * load(pick("5_drumsep", "snare"))),
    ("05 Toms", g_inst * load(pick("5_drumsep", "toms"))),
    ("06 Hi-Hat", g_inst * load(pick("5_drumsep", "hh"))),
    ("07 Ride", g_inst * load(pick("5_drumsep", "ride"))),
    ("08 Crash", g_inst * load(pick("5_drumsep", "crash"))),
    ("09 Bass", g_inst * load(pick("3_ft", "Bass"))),
    ("10 Keys", g_inst * piano),
    ("11 Guitar", g_inst * guitar),
    # 6s on an "other"-only input doesn't sum to it, so Other is what's left after keys/guitar
    ("12 Other", g_inst * (other - piano - guitar)),
]
residual = mix - sum(t for _, t in tracks)
tracks.append(("13 Residual", residual))

mix_db = db(mix)
print(f"mix RMS {mix_db:6.1f} dBFS   ({N / sr:.1f} s, {sr} Hz)")
for name, y in tracks:
    # float WAV: true-level stems can peak above 1.0 even though the mix doesn't
    sf.write(os.path.join(OUT, f"{name}.wav"), y, sr, subtype="FLOAT")
    print(f"{name:20s} {db(y):6.1f} dBFS  ({db(y) - mix_db:+5.1f} dB vs mix)  peak {np.abs(y).max():.2f}")
print(f"null test: residual is {db(residual) - mix_db:+.1f} dB below the mix")
