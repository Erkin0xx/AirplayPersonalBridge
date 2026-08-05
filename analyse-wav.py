#!/usr/bin/env python3
"""Analyse un .wav produit par audiocap et dit s'il contient du son ou du silence.

Sert au test DRM du jalon 1 : un fichier muet et un fichier plein ont exactement la même
taille, seule l'analyse des échantillons permet de trancher.

Distingue trois cas, à ne surtout pas confondre :
  - SON CAPTÉ     : des échantillons non nuls, la capture fonctionne.
  - SILENCE       : que des zéros, alors que du son jouait -> blocage réel.
  - VIDE          : aucun échantillon écrit -> rien ne jouait, ou la capture a échoué.
                    Ce n'est PAS un résultat de test DRM.

  ./analyse-wav.py fichier.wav [...]
"""

import math
import struct
import sys


def analyse(path):
    try:
        data = open(path, "rb").read()
    except OSError as exc:
        return f"{path}: illisible ({exc})"

    # Lit le bloc `fmt ` plutôt que de supposer stéréo 48 kHz : le mode entrée physique
    # produit souvent du mono, et une hypothèse en dur fausse la durée d'un facteur 2.
    fmt = data.find(b"fmt ")
    if fmt < 0:
        return f"{path}: en-tête WAV invalide (bloc fmt absent)"
    channels = struct.unpack("<H", data[fmt + 10 : fmt + 12])[0]
    sample_rate = struct.unpack("<I", data[fmt + 12 : fmt + 16])[0]

    marker = data.find(b"data")
    if marker < 0:
        return f"{path}: en-tête WAV invalide (bloc data absent)"

    # La taille annoncée peut valoir 0 sur un fichier écrit en flux : on se fie alors à la
    # taille réelle du fichier.
    declared = struct.unpack("<I", data[marker + 4 : marker + 8])[0]
    pcm = data[marker + 8 :]
    if 0 < declared <= len(pcm):
        pcm = pcm[:declared]
    count = len(pcm) // 2
    if count == 0:
        return (f"{path}\n  VIDE — aucun échantillon écrit. Rien ne jouait pendant la "
                f"capture, ou la capture a échoué. Résultat DRM non concluant.")

    samples = struct.unpack("<%dh" % count, pcm[: count * 2])
    peak = max(abs(s) for s in samples)
    nonzero = sum(1 for s in samples if s)
    rms = math.sqrt(sum(s * s for s in samples) / len(samples))

    duration = len(samples) / max(1, channels) / max(1, sample_rate)
    if peak == 0:
        verdict = "SILENCE NUMÉRIQUE — aucun échantillon non nul"
    else:
        verdict = "SON CAPTÉ"

    return (
        f"{path}\n"
        f"  {verdict}\n"
        f"  format     : {channels} canal/canaux, {sample_rate} Hz\n"
        f"  durée      : {duration:.2f} s ({len(samples)} échantillons)\n"
        f"  non nuls   : {nonzero} ({100 * nonzero / len(samples):.1f} %)\n"
        f"  crête      : {peak}/32767"
        + (f" ({20 * math.log10(peak / 32767):.1f} dBFS)" if peak else "")
        + f"\n  RMS        : {rms:.1f}"
    )


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    for path in sys.argv[1:]:
        print(analyse(path))
        print()
