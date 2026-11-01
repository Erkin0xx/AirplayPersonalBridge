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

Code de retour, le plus grave de tous les fichiers analysés :
  0 son capté   1 silence numérique   2 usage, fichier illisible ou WAV invalide
  3 vide (résultat non concluant)
"""

import math
import struct
import sys

EXIT_SOUND, EXIT_SILENCE, EXIT_INVALID, EXIT_EMPTY = 0, 1, 2, 3

WAVE_FORMAT_PCM = 0x0001
WAVE_FORMAT_IEEE_FLOAT = 0x0003
WAVE_FORMAT_EXTENSIBLE = 0xFFFE

# Lecture par blocs : une capture d'une heure pèse plus d'1 Go, à ne pas charger d'un coup.
READ_BLOCK_BYTES = 1 << 20


class InvalidWAV(Exception):
    pass


def read_chunks(handle, file_size):
    """Parcourt les blocs RIFF et rend ceux qui comptent : `fmt ` et la position de `data`.

    Suit les tailles déclarées plutôt que de chercher les marqueurs : le système intercale des
    blocs (FLLR, JUNK, LIST), et les octets « data » peuvent très bien figurer dans l'un d'eux.
    """
    header = handle.read(12)
    if len(header) < 12 or header[:4] != b"RIFF" or header[8:12] != b"WAVE":
        raise InvalidWAV("en-tête RIFF/WAVE absent")

    fmt = None
    while True:
        chunk = handle.read(8)
        if len(chunk) < 8:
            raise InvalidWAV("bloc data absent" if fmt else "bloc fmt absent")
        chunk_id, size = chunk[:4], struct.unpack("<I", chunk[4:])[0]
        start = handle.tell()
        if chunk_id == b"fmt ":
            fmt = handle.read(size)
        elif chunk_id == b"data":
            if fmt is None:
                raise InvalidWAV("bloc data avant le bloc fmt")
            # La taille annoncée peut valoir 0 ou 0xFFFFFFFF sur un fichier écrit en flux et
            # jamais finalisé (capture interrompue) : on se fie alors à la taille réelle.
            available = file_size - start
            return fmt, start, (size if 0 < size <= available else available)
        # Les blocs sont alignés sur 2 octets : une taille impaire est suivie d'un bourrage.
        handle.seek(start + size + (size & 1))


def parse_format(fmt):
    if len(fmt) < 16:
        raise InvalidWAV("bloc fmt trop court")
    tag, channels, sample_rate = struct.unpack("<HHI", fmt[:8])
    bits = struct.unpack("<H", fmt[14:16])[0]
    # EXTENSIBLE range le vrai format dans les 2 premiers octets du GUID, en fin de bloc.
    if tag == WAVE_FORMAT_EXTENSIBLE:
        if len(fmt) < 26:
            raise InvalidWAV("bloc fmt EXTENSIBLE trop court")
        tag = struct.unpack("<H", fmt[24:26])[0]
    return tag, channels, sample_rate, bits


def sample_decoder(tag, bits):
    """Rend (octets par échantillon, conversion d'un bloc vers des valeurs de -1 à 1)."""
    if tag == WAVE_FORMAT_IEEE_FLOAT and bits in (32, 64):
        code, width = ("f", 4) if bits == 32 else ("d", 8)
        return width, lambda block: struct.unpack("<%d%s" % (len(block) // width, code), block)
    if tag == WAVE_FORMAT_PCM and bits in (16, 32):
        code, width = ("h", 2) if bits == 16 else ("i", 4)
        scale = float(2 ** (bits - 1) - 1)
        return width, lambda block: [
            v / scale for v in struct.unpack("<%d%s" % (len(block) // width, code), block)
        ]
    if tag == WAVE_FORMAT_PCM and bits == 24:
        scale = float(2**23 - 1)
        return 3, lambda block: [
            int.from_bytes(block[i : i + 3], "little", signed=True) / scale
            for i in range(0, len(block), 3)
        ]
    raise InvalidWAV("format non pris en charge (code %#x, %d bits)" % (tag, bits))


def analyse(path):
    """Rend (texte du verdict, code de retour)."""
    try:
        with open(path, "rb") as handle:
            handle.seek(0, 2)
            file_size = handle.tell()
            handle.seek(0)
            fmt, data_start, data_size = read_chunks(handle, file_size)
            tag, channels, sample_rate, bits = parse_format(fmt)
            width, decode = sample_decoder(tag, bits)

            handle.seek(data_start)
            remaining = data_size - data_size % width
            count = nonzero = 0
            peak = energy = 0.0
            while remaining > 0:
                block = handle.read(min(remaining, READ_BLOCK_BYTES - READ_BLOCK_BYTES % width))
                if not block:
                    break
                remaining -= len(block)
                block = block[: len(block) - len(block) % width]
                for value in decode(block):
                    count += 1
                    if value:
                        nonzero += 1
                        magnitude = abs(value)
                        if magnitude > peak:
                            peak = magnitude
                        energy += value * value
    except OSError as exc:
        return f"{path}: illisible ({exc})", EXIT_INVALID
    except (InvalidWAV, struct.error) as exc:
        return f"{path}: WAV invalide ({exc})", EXIT_INVALID

    if count == 0:
        return (
            f"{path}\n  VIDE — aucun échantillon écrit. Rien ne jouait pendant la "
            f"capture, ou la capture a échoué. Résultat DRM non concluant.",
            EXIT_EMPTY,
        )

    duration = count / max(1, channels) / max(1, sample_rate)
    verdict = "SON CAPTÉ" if nonzero else "SILENCE NUMÉRIQUE — aucun échantillon non nul"
    rms = math.sqrt(energy / count)
    text = (
        f"{path}\n"
        f"  {verdict}\n"
        f"  format     : {channels} canal/canaux, {sample_rate} Hz, {bits} bits"
        f"{' flottants' if tag == WAVE_FORMAT_IEEE_FLOAT else ''}\n"
        f"  durée      : {duration:.2f} s ({count} échantillons)\n"
        f"  non nuls   : {nonzero} ({100 * nonzero / count:.1f} %)\n"
        f"  crête      : {peak:.4f}"
        + (f" ({20 * math.log10(peak):.1f} dBFS)" if peak else "")
        + f"\n  RMS        : {rms:.4f}"
    )
    return text, (EXIT_SOUND if nonzero else EXIT_SILENCE)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(EXIT_INVALID)
    worst = EXIT_SOUND
    for path in sys.argv[1:]:
        report, code = analyse(path)
        print(report)
        print()
        worst = max(worst, code)
    sys.exit(worst)
