#!/usr/bin/env python3
"""Mesure au micro l'écart de calage entre enceintes, à partir de `audiocap --clicks --record-input`.

  scripts/measure-clicks.py mesure.wav               # lit mesure.json à côté
  scripts/measure-clicks.py mesure.wav --meta autre.json --detail
  scripts/measure-clicks.py mesure.wav --json         # résultat en JSON sur stdout
  scripts/measure-clicks.py telephone.wav --sans-datation   # enregistrement d'un autre appareil
  scripts/measure-clicks.py --self-test               # vérifie l'analyse sur des WAV synthétiques

Python 3.8 ou plus, **bibliothèque standard seule** : rien à installer, pas de venv (le Python de
Homebrew refuse toute installation pip globale, PEP 668). Une minute d'enregistrement s'analyse en
quelques secondes.

Ce que fait l'analyse
---------------------
1. **Filtre adapté** à la salve émise (5 ms à 3 kHz en fenêtre de Hann, paramètres lus dans le
   JSON) : une corrélation avec la salve elle-même, en quadrature. C'est un passe-bande d'environ
   400 Hz centré sur 3 kHz, et son module est l'**enveloppe** : maximale, sans lobe secondaire,
   quand la salve reçue est alignée sur le gabarit, quelle que soit sa phase après l'enceinte et la
   pièce. Calculée en O(N) par trois sommes glissantes (la fenêtre de Hann est une somme de trois
   exponentielles complexes), sans numpy.
2. **Seuil adaptatif** : un multiple (`--seuil-bruit`, 5 par défaut) de la médiane de l'enveloppe,
   relevée seconde par seconde, donc du bruit de fond local ; et, autour de chaque salve, une part
   (`--seuil-relatif`) de la plus forte de ses voisines.
3. **Datation** : maximum local de l'enveloppe, affiné par une parabole sur trois points, soit une
   résolution bien meilleure que 0,1 ms (une trame à 48 kHz = 0,021 ms). La position d'échantillon
   devient un instant hôte par les ancrages du JSON (interpolation linéaire), puis un écart à
   l'instant attendu de la salve la plus proche.
4. **Repère** : la doublure qui suit une salve sur cinq, 250 ms plus tard, est reconnue et écartée,
   et elle dit quelles salves sont les multiples de 5 : l'ambiguïté de 2 s est levée (modulo 10 s).
5. **Groupes** : les écarts se regroupent, un groupe par enceinte quand plusieurs jouent ensemble
   (salves distinctes dès 5 ms d'écart, la durée d'une salve). Moyenne, écart-type, nombre, niveau
   relatif et dérive de chacun, puis écarts entre groupes.

Ce qui est mesuré
-----------------
Écart = arrivée au micro − instant de restitution de la salve selon l'horloge commune, le même pour
toutes les sorties (une sortie réglée avec un délai manuel de d ms est attendue d ms plus tard : le
compte rendu rappelle ces délais, sans pouvoir dire quel groupe est quelle enceinte). L'écart
contient la propagation (2,9 ms par mètre), le traitement interne de l'enceinte et la latence
d'entrée du micro : sa valeur absolue n'est pas le défaut de calage. Ce sont les **écarts entre
groupes** qu'on compare au seuil de 20 à 30 ms.

Limites : deux enceintes à moins de 5 ms l'une de l'autre (la durée d'une salve) se fondent en un
groupe, au calage alors déjà satisfaisant. Une réflexion forte et stable sur un mur peut former son
propre groupe quelques ms après celui de l'enceinte : le premier groupe d'une enceinte est son son
direct. Pour savoir quel groupe est quelle enceinte : une mesure par enceinte seule, ou un délai
manuel connu (`--delay2 40`) qui déplace son groupe d'autant.

Sans JSON (`--sans-datation`, enregistrement fait au téléphone par exemple), rien ne relie
l'enregistrement à l'horloge commune : les écarts absolus sont arbitraires, mais les écarts entre
groupes restent justes, la période des salves suffisant à les regrouper.

Codes de retour : 0 analyse faite, 1 aucune salve trouvée, 2 usage ou fichier invalide,
3 auto-test en échec.
"""

import argparse
import bisect
import cmath
import json
import math
import os
import random
import struct
import sys
import tempfile
import wave
from array import array
from itertools import accumulate, repeat
from operator import add, mul, sub

EXIT_OK, EXIT_NOTHING, EXIT_INVALID, EXIT_SELFTEST = 0, 1, 2, 3

WAVE_FORMAT_PCM = 0x0001
WAVE_FORMAT_IEEE_FLOAT = 0x0003
WAVE_FORMAT_EXTENSIBLE = 0xFFFE


class InvalidInput(Exception):
    pass


# --------------------------------------------------------------------------------------------
# Lecture du WAV
# --------------------------------------------------------------------------------------------


def read_wav_mono(path):
    """Rend (fréquence, échantillons de la voie 0 en flottants de -1 à 1).

    Suit les blocs RIFF par leurs tailles (le système intercale FLLR, JUNK…), et se fie à la taille
    réelle du fichier quand l'en-tête annonce 0 ou 0xFFFFFFFF (fichier jamais finalisé).
    """
    with open(path, "rb") as handle:
        handle.seek(0, 2)
        file_size = handle.tell()
        handle.seek(0)
        header = handle.read(12)
        if len(header) < 12 or header[:4] != b"RIFF" or header[8:12] != b"WAVE":
            raise InvalidInput("%s : en-tête RIFF/WAVE absent" % path)
        fmt = None
        while True:
            chunk = handle.read(8)
            if len(chunk) < 8:
                raise InvalidInput("%s : bloc %s absent" % (path, "data" if fmt else "fmt"))
            chunk_id, size = chunk[:4], struct.unpack("<I", chunk[4:])[0]
            start = handle.tell()
            if chunk_id == b"fmt ":
                fmt = handle.read(size)
            elif chunk_id == b"data":
                if fmt is None:
                    raise InvalidInput("%s : bloc data avant le bloc fmt" % path)
                available = file_size - start
                data = handle.read(size if 0 < size <= available else available)
                break
            handle.seek(start + size + (size & 1))

    if len(fmt) < 16:
        raise InvalidInput("%s : bloc fmt trop court" % path)
    tag, channels, rate = struct.unpack("<HHI", fmt[:8])
    bits = struct.unpack("<H", fmt[14:16])[0]
    if tag == WAVE_FORMAT_EXTENSIBLE and len(fmt) >= 26:
        tag = struct.unpack("<H", fmt[24:26])[0]
    if channels < 1:
        raise InvalidInput("%s : aucune voie" % path)

    if tag == WAVE_FORMAT_PCM and bits == 16:
        values, scale = array("h"), 1 / 32768.0
    elif tag == WAVE_FORMAT_PCM and bits == 32:
        values, scale = array("i"), 1 / 2147483648.0
    elif tag == WAVE_FORMAT_IEEE_FLOAT and bits == 32:
        values, scale = array("f"), 1.0
    elif tag == WAVE_FORMAT_IEEE_FLOAT and bits == 64:
        values, scale = array("d"), 1.0
    elif tag == WAVE_FORMAT_PCM and bits == 24:
        usable = len(data) - len(data) % (3 * channels)
        mono = array("d", (
            int.from_bytes(data[i : i + 3], "little", signed=True) / 8388608.0
            for i in range(0, usable, 3 * channels)
        ))
        return rate, mono
    else:
        raise InvalidInput("%s : format non pris en charge (code %#x, %d bits)" % (path, tag, bits))
    width = values.itemsize
    usable = len(data) - len(data) % (width * channels)
    values.frombytes(data[:usable])
    if sys.byteorder != "little":
        values.byteswap()
    first = values[0::channels] if channels > 1 else values
    # `array` plutôt que liste : 8 octets par échantillon au lieu d'une trentaine.
    return rate, array("d", (v * scale for v in first))


# --------------------------------------------------------------------------------------------
# Filtre adapté et enveloppe
# --------------------------------------------------------------------------------------------


def matched_envelope(samples, rate, frequency, length, chunk=1 << 16):
    """Module de la corrélation avec une salve de Hann : env[n] pour une salve commençant en n.

    C[n] = Σ_m x[n+m]·h[m]·e^{-jωm}, h[m] = ½ − ½cos(Ωm), Ω = 2π/L. Comme
    h[m]e^{-jωm} = ½e^{-jωm} − ¼e^{-j(ω−Ω)m} − ¼e^{-j(ω+Ω)m}, C est la combinaison de trois sommes
    glissantes de longueur L, chacune obtenue par différence de sommes cumulées. Le calcul se fait
    par tranches, avec des sommes cumulées locales : la précision ne dépend pas de la durée.
    """
    total = len(samples)
    count = total - length + 1
    if count <= 0:
        return array("d")
    omega = 2 * math.pi * frequency / rate
    big = 2 * math.pi / length
    nus = (omega, omega - big, omega + big)
    span = chunk + length
    tables = [[cmath.exp(-1j * nu * t) for t in range(span)] for nu in nus]
    rotate_down = [cmath.exp(-1j * big * q) for q in range(chunk)]
    rotate_up = [cmath.exp(1j * big * q) for q in range(chunk)]

    envelope = array("d")
    start = 0
    while start < count:
        size = min(chunk, count - start)
        piece = samples[start : start + size + length - 1]
        sums = []
        for table in tables:
            prefix = list(accumulate(map(mul, piece, table), initial=0))
            sums.append(list(map(sub, prefix[length : length + size], prefix[:size])))
        centre = map(mul, sums[0], repeat(0.5))
        sides = map(add, map(mul, sums[1], rotate_down), map(mul, sums[2], rotate_up))
        envelope.extend(map(abs, map(sub, centre, map(mul, sides, repeat(0.25)))))
        start += size
    return envelope


def local_noise_floor(envelope, rate, block_seconds=1.0, decimation=8):
    """Médiane de l'enveloppe par blocs d'une seconde : le bruit de fond local.

    Les salves n'occupent qu'une fraction de pour cent du temps : elles ne déplacent pas la médiane.
    """
    block = max(1, int(rate * block_seconds))
    floors = []
    for begin in range(0, len(envelope), block):
        values = sorted(envelope[begin : begin + block : decimation])
        floors.append(values[len(values) // 2] if values else 0.0)
    positive = sorted(v for v in floors if v > 0)
    fallback = positive[len(positive) // 2] if positive else 1e-12
    return block, [v if v > 0 else fallback for v in floors]


def find_peaks(envelope, rate, length, noise_factor, relative):
    """Maxima locaux au-dessus du seuil adaptatif, affinés à la sous-trame.

    Rend des tuples (position fractionnaire, valeur de l'enveloppe, plancher de bruit local).
    """
    block, floors = local_noise_floor(envelope, rate)

    def floor_at(index):
        slot = index // block
        # Le plus haut des blocs voisins : un bruit qui monte ne déclenche pas une fausse salve.
        return max(floors[max(0, slot - 1) : slot + 2])

    above = [i for i, value in enumerate(envelope) if value > noise_factor * floors[i // block]]
    guard = max(1, length // 2)
    candidates = []
    run_start = None
    previous = None
    for index in above + [None]:
        if index is not None and previous is not None and index == previous + 1:
            previous = index
            continue
        if run_start is not None:
            # Maxima locaux de la plage, puis suppression des non-maxima à ± une demi-salve.
            low, high = run_start, previous
            maxima = [
                i
                for i in range(low, high + 1)
                if envelope[i] >= envelope[i - 1 if i > 0 else i]
                and envelope[i] >= envelope[i + 1 if i + 1 < len(envelope) else i]
            ]
            kept = []
            for i in sorted(maxima, key=lambda j: -envelope[j]):
                if all(abs(i - j) > guard for j in kept):
                    kept.append(i)
            candidates.extend(kept)
        run_start = previous = index

    peaks = []
    for i in sorted(candidates):
        if not 0 < i < len(envelope) - 1:
            continue
        floor = floor_at(i)
        if envelope[i] <= noise_factor * floor:
            continue
        left, centre, right = envelope[i - 1], envelope[i], envelope[i + 1]
        curvature = left - 2 * centre + right
        delta = 0.5 * (left - right) / curvature if curvature < 0 else 0.0
        peaks.append((i + max(-0.5, min(0.5, delta)), centre, floor))

    # Seuil relatif : une salve beaucoup plus faible que ses voisines immédiates (± 60 ms) est une
    # traîne ou un rebond, pas une enceinte.
    window = 0.060 * rate
    strong = []
    for position, value, floor in peaks:
        neighbours = [v for p, v, _ in peaks if abs(p - position) <= window]
        if value >= relative * max(neighbours):
            strong.append((position, value, floor))
    return strong


# --------------------------------------------------------------------------------------------
# Datation et regroupement
# --------------------------------------------------------------------------------------------


class SampleClock:
    """Instant hôte (ns) d'une position d'échantillon, par les ancrages [trame, instant hôte]."""

    def __init__(self, anchors, rate):
        anchors = sorted((int(f), int(h)) for f, h in anchors)
        if not anchors:
            raise InvalidInput("aucun ancrage dans le JSON : l'enregistrement n'est pas daté")
        self.frames = [f for f, _ in anchors]
        self.hosts = [h for _, h in anchors]
        if len(anchors) >= 2 and self.frames[-1] > self.frames[0]:
            self.slope = (self.hosts[-1] - self.hosts[0]) / (self.frames[-1] - self.frames[0])
        else:
            self.slope = 1e9 / rate
        self.rate = rate

    def host_ns(self, position):
        index = bisect.bisect_right(self.frames, position) - 1
        if index < 0:
            return self.hosts[0] + (position - self.frames[0]) * self.slope
        if index >= len(self.frames) - 1:
            return self.hosts[-1] + (position - self.frames[-1]) * self.slope
        f0, f1 = self.frames[index], self.frames[index + 1]
        h0, h1 = self.hosts[index], self.hosts[index + 1]
        return h0 + (position - f0) * (h1 - h0) / (f1 - f0)

    def ppm(self):
        """Écart de la fréquence réelle du micro à sa valeur nominale, en ppm d'horloge hôte."""
        return (1e9 / self.rate / self.slope - 1) * 1e6


def cluster_circular(values, period, gap):
    """Groupe des valeurs définies modulo `period` : coupe là où l'écart dépasse `gap`.

    Rend des listes d'indices dans `values`.
    """
    if not values:
        return []
    order = sorted(range(len(values)), key=lambda i: values[i])
    groups = [[order[0]]]
    for previous, current in zip(order, order[1:]):
        if values[current] - values[previous] > gap:
            groups.append([])
        groups[-1].append(current)
    # Un groupe à cheval sur ±période/2 apparaît coupé en deux aux extrémités.
    if len(groups) > 1 and values[order[0]] + period - values[order[-1]] <= gap:
        groups[0] = groups.pop() + groups[0]
    return groups


def mean(values):
    return sum(values) / len(values)


def stdev(values):
    if len(values) < 2:
        return 0.0
    centre = mean(values)
    return math.sqrt(sum((v - centre) ** 2 for v in values) / (len(values) - 1))


def slope_per_minute(times, values):
    if len(times) < 3:
        return None
    t0, v0 = mean(times), mean(values)
    denominator = sum((t - t0) ** 2 for t in times)
    if denominator == 0:
        return None
    return sum((t - t0) * (v - v0) for t, v in zip(times, values)) / denominator * 60


def analyse(samples, rate, meta, noise_factor=5.0, relative=0.1, group_gap_ms=2.0, marker_tol_ms=1.0):
    """Rend le résultat de l'analyse, sous forme de dictionnaire."""
    source = meta.get("source") or {}
    recording = meta.get("enregistrement") or {}
    common = meta.get("horloge_commune")
    if common is None:
        raise InvalidInput("JSON sans horloge_commune : la diffusion n'a pas démarré")
    capture_rate = float(common.get("frequence_capture_hz") or source.get("frequence_hz") or 48000)
    period_frames = int(source.get("periode_trames") or 96000)
    burst_frames = int(source.get("salve_trames") or 240)
    burst_frequency = float(source.get("salve_frequence_hz") or 3000)
    marker_every = int(source.get("repere_toutes_les") or 5)
    marker_frames = int(source.get("repere_decalage_trames") or 12000)
    if source.get("type") not in (None, "clics"):
        raise InvalidInput("source « %s » : seule une mesure --clicks s'analyse" % source.get("type"))

    warnings = []
    declared_rate = recording.get("frequence_hz")
    if declared_rate and abs(float(declared_rate) - rate) > 0.5:
        warnings.append("le WAV est à %d Hz, le JSON annonce %s Hz" % (rate, declared_rate))
    if recording.get("trames_perdues"):
        warnings.append("%d trames perdues à l'enregistrement" % recording["trames_perdues"])
    # L'origine publiée en tête vaut pour toute la mesure, sauf report de l'horloge commune en
    # cours de route : les valeurs successives sont alors dans `changements`, chacune avec l'instant
    # où elle a été vue. Elles se distinguent par leur instant Unix, pas par leur conversion en
    # instant hôte, faite à des moments différents.
    changes = sorted(common.get("changements") or [], key=lambda c: int(c["observe_hote_ns"]))
    base_origin = int(common["trame0_restitution_hote_ns"])
    origins = []
    if len({round(float(c["trame0_restitution_unix_s"]), 6) for c in changes}) > 1:
        origins = [(int(c["observe_hote_ns"]), int(c["trame0_restitution_hote_ns"])) for c in changes]
        base_origin = origins[0][1]
        warnings.append(
            "l'horloge commune a été reportée pendant la mesure (trou de capture) : chaque salve est "
            "rapportée à l'origine en vigueur à son arrivée"
        )
    rate_ppm = (meta.get("horloge_hote") or {}).get("ecart_rythme_ppm")
    if meta.get("_sans_datation"):
        warnings.append(
            "enregistrement non daté : écarts absolus arbitraires, seuls les écarts entre groupes "
            "ont un sens"
        )
    if rate_ppm is not None and abs(rate_ppm) > 100:
        warnings.append("l'heure du Mac a sauté pendant la mesure (%.0f ppm) : à refaire" % rate_ppm)

    clock = SampleClock(recording.get("ancrages") or [], rate)
    length = max(8, int(round(burst_frames / capture_rate * rate)))
    envelope = matched_envelope(samples, rate, burst_frequency, length)
    peaks = find_peaks(envelope, rate, length, noise_factor, relative)

    period_ns = period_frames / capture_rate * 1e9
    marker_ns = marker_frames / capture_rate * 1e9
    tolerance_ns = marker_tol_ms * 1e6

    def origin_at(host):
        current = base_origin
        for observed, origin in origins:
            if observed <= host:
                current = origin
        return current

    detections = []
    strongest = max((v for _, v, _ in peaks), default=0.0)
    for position, value, floor in peaks:
        host = clock.host_ns(position)
        origin = origin_at(host)
        k_hat = int(round((host - origin) / period_ns))
        detections.append({
            "position": position,
            "hote_ns": host,
            "origine": origin,
            "k_brut": k_hat,
            "reste_ns": host - origin - k_hat * period_ns,
            "niveau_db": 20 * math.log10(value / strongest) if strongest > 0 else 0.0,
            "snr_db": 20 * math.log10(value / floor) if floor > 0 else None,
            "doublure": False,
            "repere": False,
        })

    # Repère : une salve suivie, `marker_ns` plus tard, d'une autre. La seconde est la doublure.
    times = [d["hote_ns"] for d in detections]
    for index, detection in enumerate(detections):
        target = detection["hote_ns"] + marker_ns
        low = bisect.bisect_left(times, target - tolerance_ns)
        high = bisect.bisect_right(times, target + tolerance_ns)
        partners = [j for j in range(low, high) if j != index]
        if partners:
            best = min(partners, key=lambda j: abs(times[j] - target))
            detection["repere"] = True
            detections[best]["doublure"] = True
    main = [d for d in detections if not d["doublure"]]

    # Salves attendues dans la durée enregistrée.
    first_host = clock.host_ns(0)
    last_host = clock.host_ns(max(0, len(samples) - length))
    k_first = math.ceil((first_host - base_origin) / period_ns)
    k_last = math.floor((last_host - base_origin) / period_ns)
    expected_count = max(0, k_last - k_first + 1)

    groups = []
    clusters = cluster_circular([d["reste_ns"] for d in main], period_ns, group_gap_ms * 1e6)
    for members in clusters:
        items = [main[i] for i in members]
        # Un groupe à cheval sur ±1 s est recollé d'abord : une salve rapportée à la période
        # suivante change aussi d'indice.
        reference = items[0]["reste_ns"]
        for item in items:
            item["reste_recolle_ns"] = item["reste_ns"]
            item["k_recolle"] = item["k_brut"]
            if item["reste_ns"] - reference > period_ns / 2:
                item["reste_recolle_ns"] -= period_ns
                item["k_recolle"] += 1
            elif reference - item["reste_ns"] > period_ns / 2:
                item["reste_recolle_ns"] += period_ns
                item["k_recolle"] -= 1
        # Résidu modulo 5 des salves repères du groupe : il dit de combien de périodes l'écart
        # brut est faux. Une salve repère porte un vrai k multiple de 5.
        residues = {}
        for item in items:
            if item["repere"]:
                residue = item["k_recolle"] % marker_every
                residues[residue] = residues.get(residue, 0) + 1
        shift = 0
        resolved = bool(residues)
        consistent = 0
        if residues:
            residue, consistent = max(residues.items(), key=lambda kv: kv[1])
            shift = residue if residue <= marker_every // 2 else residue - marker_every
        for item in items:
            item["k"] = item["k_recolle"] - shift
            item["ecart_ms"] = (item["reste_recolle_ns"] + shift * period_ns) / 1e6
        offsets_ms = [item["ecart_ms"] for item in items]
        seconds = [(item["hote_ns"] - first_host) / 1e9 for item in items]
        groups.append({
            "ecart_moyen_ms": mean(offsets_ms),
            "ecart_type_ms": stdev(offsets_ms),
            "nombre": len(items),
            "attendues": expected_count,
            "min_ms": min(offsets_ms),
            "max_ms": max(offsets_ms),
            "niveau_db": mean([item["niveau_db"] for item in items]),
            "derive_ms_par_min": slope_per_minute(seconds, offsets_ms),
            "ambiguite_levee": resolved,
            "reperes": sum(residues.values()),
            "reperes_coherents": consistent,
            "_items": items,
            "_shift": shift,
        })

    # Les groupes trop clairsemés (bruit, chocs) sont tenus à part.
    minimum = max(3, int(0.3 * expected_count))
    speakers = sorted((g for g in groups if g["nombre"] >= minimum), key=lambda g: g["ecart_moyen_ms"])
    sparse = sorted((g for g in groups if g["nombre"] < minimum), key=lambda g: g["ecart_moyen_ms"])
    for index, group in enumerate(speakers):
        group["nom"] = chr(ord("A") + index) if index < 26 else "G%d" % index
        for item in group["_items"]:
            item["groupe"] = group["nom"]
        if not group["ambiguite_levee"]:
            warnings.append(
                "groupe %s : aucun repère reconnu, écart connu modulo %.0f s seulement"
                % (group["nom"], period_ns / 1e9)
            )
        elif group["reperes_coherents"] < group["reperes"]:
            warnings.append(
                "groupe %s : repères incohérents (%d sur %d) — deux enceintes à 250 ms d'écart ?"
                % (group["nom"], group["reperes_coherents"], group["reperes"])
            )
    # Une doublure dont la salve repère s'est perdue dans le bruit n'a pas été reconnue : elle
    # forme un groupe clairsemé 250 ms après un vrai groupe, modulo la période.
    period_ms = period_ns / 1e6
    orphans = []
    for group in sparse:
        for speaker in speakers:
            raw = speaker["ecart_moyen_ms"] - speaker["_shift"] * period_ms
            distance = (group["ecart_moyen_ms"] - raw - marker_ns / 1e6) % period_ms
            if min(distance, period_ms - distance) <= marker_tol_ms:
                orphans.append(group)
                for item in group["_items"]:
                    item["doublure"] = True
                break
    sparse = [group for group in sparse if all(group is not orphan for orphan in orphans)]
    for group in sparse:
        for item in group["_items"]:
            item["groupe"] = None

    if speakers:
        reference = speakers[0]["ecart_moyen_ms"]
        for group in speakers:
            group["ecart_au_premier_ms"] = group["ecart_moyen_ms"] - reference
    spread = speakers[-1]["ecart_moyen_ms"] - speakers[0]["ecart_moyen_ms"] if speakers else None

    bursts = []
    for detection in sorted(detections, key=lambda d: d["hote_ns"]):
        bursts.append({
            "instant_s": (detection["hote_ns"] - first_host) / 1e9,
            "position_trame": round(detection["position"], 3),
            "k": detection.get("k", detection["k_brut"]),
            "ecart_ms": detection.get("ecart_ms", detection["reste_ns"] / 1e6),
            "niveau_db": detection["niveau_db"],
            "snr_db": detection["snr_db"],
            "doublure": detection["doublure"],
            "repere": detection["repere"],
            "groupe": detection.get("groupe"),
        })

    def public(group):
        return {key: value for key, value in group.items() if not key.startswith("_")}

    return {
        "frequence_hz": rate,
        "duree_s": len(samples) / rate,
        "micro_ppm": clock.ppm(),
        "horloge_murale_ppm": rate_ppm,
        "salves_attendues_par_enceinte": expected_count,
        "detections": len(detections),
        "doublures": sum(1 for d in detections if d["doublure"]),
        "groupes": [public(g) for g in speakers],
        "groupes_clairsemes": [public(g) for g in sparse],
        "ecart_max_entre_groupes_ms": spread,
        "salves": bursts,
        "sorties": meta.get("sorties") or [],
        "avertissements": warnings,
    }


# --------------------------------------------------------------------------------------------
# Compte rendu
# --------------------------------------------------------------------------------------------


def format_report(result, wav_path, detail=False):
    lines = []
    lines.append(
        "Mesure : %s (%.1f s, %d Hz), %d salves attendues par enceinte"
        % (os.path.basename(wav_path), result["duree_s"], result["frequence_hz"],
           result["salves_attendues_par_enceinte"])
    )
    murale = result["horloge_murale_ppm"]
    lines.append(
        "Horloges : micro %+.1f ppm sur l'horloge hôte, horloge murale %s"
        % (result["micro_ppm"], "%+.2f ppm" % murale if murale is not None else "—")
    )
    lines.append(
        "Détections : %d salves, dont %d doublures de repère"
        % (result["detections"], result["doublures"])
    )
    for output in result["sorties"]:
        lines.append(
            "  sortie %-24s délai manuel %s, latence récepteur %s, %s"
            % (
                output.get("id"),
                "%.1f ms" % output["delai_manuel_ms"] if output.get("delai_manuel_ms") is not None
                else "%.1f ms (demandé)" % output.get("delai_demande_ms", 0),
                "%.2f ms" % output["latence_recepteur_ms"]
                if output.get("latence_recepteur_ms") is not None else "—",
                output.get("etat_final", "?"),
            )
        )
    lines.append("")
    if not result["groupes"]:
        lines.append("Aucun groupe de salves : rien n'a été entendu au-dessus du bruit.")
    else:
        lines.append("Groupes (un par enceinte, ou par arrivée stable) :")
        lines.append("   écart moyen  écart-type     n   niveau    dérive      au 1er   repère")
        for group in result["groupes"]:
            drift = group["derive_ms_par_min"]
            lines.append(
                "  %s %+10.2f ms %8.3f ms %5s %6.1f dB %s %+8.2f ms   %s"
                % (
                    group["nom"],
                    group["ecart_moyen_ms"],
                    group["ecart_type_ms"],
                    "%d/%d" % (group["nombre"], group["attendues"]),
                    group["niveau_db"],
                    "%+6.2f ms/min" % drift if drift is not None else "     —      ",
                    group["ecart_au_premier_ms"],
                    "%d/%d" % (group["reperes_coherents"], group["reperes"])
                    if group["ambiguite_levee"] else "non levé (±2 s)",
                )
            )
        spread = result["ecart_max_entre_groupes_ms"]
        if len(result["groupes"]) > 1:
            verdict = "sous" if spread < 20 else ("entre" if spread <= 30 else "AU-DESSUS de")
            lines.append("")
            lines.append(
                "Écart maximal entre groupes : %.2f ms (%s le seuil de 20 à 30 ms)" % (spread, verdict)
            )
    for group in result["groupes_clairsemes"]:
        lines.append(
            "  (groupe clairsemé à %+.2f ms : %d salves, bruit ou choc probable)"
            % (group["ecart_moyen_ms"], group["nombre"])
        )
    if result["avertissements"]:
        lines.append("")
        for warning in result["avertissements"]:
            lines.append("ATTENTION : " + warning)
    if detail:
        lines.append("")
        lines.append("Salves détectées :")
        lines.append("   instant      k   écart        niveau   SNR      groupe")
        for burst in result["salves"]:
            tag = "doublure" if burst["doublure"] else (burst["groupe"] or "—")
            lines.append(
                "  %8.3f s %4d %+10.3f ms %6.1f dB %5s   %s%s"
                % (
                    burst["instant_s"], burst["k"], burst["ecart_ms"], burst["niveau_db"],
                    "%.0f" % burst["snr_db"] if burst["snr_db"] is not None else "—",
                    tag, " (repère)" if burst["repere"] else "",
                )
            )
    return "\n".join(lines)


# --------------------------------------------------------------------------------------------
# Auto-test sur des enregistrements synthétiques
# --------------------------------------------------------------------------------------------


def synthesize(path, offsets_ms, amplitudes, duration=24.0, noise=0.01, micro_ppm=40.0,
               rate=48000, seed=1):
    """Écrit un WAV et son JSON comme les produirait `audiocap --record-input`.

    Chaque « enceinte » rejoue la salve de `ClickPattern` (et sa doublure de repère) avec son
    écart, en retard fractionnaire exact. Le micro tourne `micro_ppm` trop vite par rapport à
    l'horloge hôte, que seuls les ancrages connaissent. Du bruit blanc gaussien s'ajoute.
    """
    rng = random.Random(seed)
    period_frames, burst_frames, frequency = 96000, 240, 3000.0
    marker_every, marker_frames, capture_rate = 5, 12000, 48000.0
    total = int(duration * rate)
    first_host = 3_600_123_456_789
    ns_per_sample = 1e9 / (rate * (1 + micro_ppm * 1e-6))
    # La trame 0 de capture est attendue un peu avant le début de l'enregistrement : les premières
    # salves tombent avant, la mesure n'en voit qu'une partie.
    origin = first_host - 1_300_000_000
    samples = [rng.gauss(0.0, noise) for _ in range(total)]
    burst_seconds = burst_frames / capture_rate

    def burst(t):
        if not 0 <= t < burst_seconds:
            return 0.0
        window = 0.5 - 0.5 * math.cos(2 * math.pi * t / burst_seconds)
        return window * math.cos(2 * math.pi * frequency * (t - burst_seconds / 2))

    period_ns = period_frames / capture_rate * 1e9
    marker_ns = marker_frames / capture_rate * 1e9
    last_host = first_host + total * ns_per_sample
    k = 0
    while origin + k * period_ns < last_host:
        starts = [origin + k * period_ns]
        if k % marker_every == 0:
            starts.append(starts[0] + marker_ns)
        for start in starts:
            for offset_ms, amplitude in zip(offsets_ms, amplitudes):
                arrival = start + offset_ms * 1e6
                first = int(math.floor((arrival - first_host) / ns_per_sample))
                for index in range(max(0, first), min(total, first + burst_frames + 2)):
                    t = (first_host + index * ns_per_sample - arrival) / 1e9
                    samples[index] += amplitude * 0.1 * burst(t)
        k += 1

    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        pcm = array("h", (max(-32768, min(32767, int(round(v * 32767)))) for v in samples))
        if sys.byteorder != "little":
            pcm.byteswap()
        handle.writeframes(pcm.tobytes())

    anchors = [[f, int(round(first_host + f * ns_per_sample))] for f in range(0, total, 12000)]
    meta = {
        "format": "audiocap-mesure",
        "version": 1,
        "enregistrement": {
            "frequence_hz": rate, "voies": 1, "trames_ecrites": total, "trames_perdues": 0,
            "premier_echantillon_hote_ns": first_host, "premier_echantillon_extrapole": False,
            "ancrages": anchors,
        },
        "horloge_hote": {"base_numer": 125, "base_denom": 3, "ecart_rythme_ppm": 0.0, "releves": []},
        "horloge_commune": {
            "frequence_capture_hz": capture_rate, "delai_restitution_s": 2.0,
            "trame0_restitution_unix_s": 1762000000.0, "trame0_restitution_hote_ns": origin,
            "interruptions_reportees_s": 0, "changements": [],
        },
        "source": {
            "type": "clics", "niveau_dbfs": -20, "frequence_hz": capture_rate,
            "periode_trames": period_frames, "salve_trames": burst_frames,
            "salve_frequence_hz": frequency, "repere_toutes_les": marker_every,
            "repere_decalage_trames": marker_frames,
        },
        "sorties": [],
    }
    with open(os.path.splitext(path)[0] + ".json", "w") as handle:
        json.dump(meta, handle)


def undated_meta(rate):
    """Le JSON minimal d'un enregistrement que rien ne date : grille de 2 s posée sur sa trame 0."""
    return {
        "enregistrement": {"frequence_hz": rate, "ancrages": [[0, 0]]},
        "horloge_commune": {
            "frequence_capture_hz": 48000, "trame0_restitution_hote_ns": 0, "changements": [],
        },
        "source": {"type": "clics"},
        "sorties": [],
        "_sans_datation": True,
    }


def self_test():
    """Rend le code de retour : 0 si l'analyse retrouve tous les écarts à 0,1 ms près."""
    cases = [
        ("une enceinte", [12.345], [1.0], 0.02),
        ("trois enceintes à 0, 7 et 18 ms", [3.21, 10.21, 21.21], [1.0, 0.6, 0.35], 0.01),
        ("une enceinte 2 s en retard (repère)", [2012.5], [1.0], 0.01),
        ("bruit seul : aucun groupe", [], [], 0.02),
    ]
    failures = 0
    with tempfile.TemporaryDirectory(prefix="measure-clicks-") as directory:
        for index, (label, offsets, amplitudes, noise) in enumerate(cases):
            path = os.path.join(directory, "cas%d.wav" % index)
            synthesize(path, offsets, amplitudes, noise=noise, seed=index + 1)
            rate, samples = read_wav_mono(path)
            with open(os.path.splitext(path)[0] + ".json") as handle:
                meta = json.load(handle)
            result = analyse(samples, rate, meta)
            found = [g["ecart_moyen_ms"] for g in result["groupes"]]
            errors = [abs(f - e) for f, e in zip(found, offsets)]
            ok = len(found) == len(offsets) and all(e <= 0.1 for e in errors)
            failures += 0 if ok else 1
            print("%s  %s" % ("OK   " if ok else "ÉCHEC", label))
            print("       attendu : %s" % ", ".join("%+.3f ms" % o for o in offsets))
            print("       trouvé  : %s" % ", ".join(
                "%+.3f ms (σ %.3f, n %d)" % (g["ecart_moyen_ms"], g["ecart_type_ms"], g["nombre"])
                for g in result["groupes"]))
            if errors:
                print("       erreur max : %.4f ms, micro %+.1f ppm retrouvé"
                      % (max(errors), result["micro_ppm"]))
            for warning in result["avertissements"]:
                print("       avertissement : " + warning)
        # Le même enregistrement à trois enceintes, analysé comme s'il venait d'un téléphone : seuls
        # les écarts entre groupes comptent.
        path = os.path.join(directory, "cas1.wav")
        rate, samples = read_wav_mono(path)
        result = analyse(samples, rate, undated_meta(rate))
        found = [g["ecart_au_premier_ms"] for g in result["groupes"]]
        ok = len(found) == 3 and all(abs(f - e) <= 0.1 for f, e in zip(found, [0, 7, 18]))
        failures += 0 if ok else 1
        print("%s  trois enceintes, sans datation" % ("OK   " if ok else "ÉCHEC"))
        print("       écarts au premier attendus : +0.000, +7.000, +18.000 ms")
        print("       trouvés : %s" % ", ".join("%+.3f ms" % f for f in found))
    return EXIT_OK if failures == 0 else EXIT_SELFTEST


# --------------------------------------------------------------------------------------------


def main(argv):
    parser = argparse.ArgumentParser(
        description="Mesure l'écart de calage entre enceintes à partir d'un enregistrement de clics."
    )
    parser.add_argument("wav", nargs="?", help="enregistrement de audiocap --record-input")
    parser.add_argument("--meta", help="JSON de datation (défaut : même nom que le WAV, en .json)")
    parser.add_argument("--json", action="store_true", help="résultat en JSON sur stdout")
    parser.add_argument("--sans-datation", action="store_true",
                        help="enregistrement sans JSON : seuls les écarts entre groupes ont un sens")
    parser.add_argument("--detail", action="store_true", help="liste aussi chaque salve")
    parser.add_argument("--seuil-bruit", type=float, default=5.0,
                        help="seuil, en multiple du bruit de fond local (défaut : 5, soit 14 dB)")
    parser.add_argument("--seuil-relatif", type=float, default=0.1,
                        help="part minimale de la plus forte salve voisine (défaut : 0,1, −20 dB)")
    parser.add_argument("--ecart-groupes", type=float, default=2.0,
                        help="écart en ms au-delà duquel deux salves sont de groupes distincts")
    parser.add_argument("--self-test", action="store_true",
                        help="vérifie l'analyse sur des enregistrements synthétiques")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.wav:
        parser.print_usage(sys.stderr)
        return EXIT_INVALID
    meta_path = args.meta or os.path.splitext(args.wav)[0] + ".json"
    try:
        rate, samples = read_wav_mono(args.wav)
        if args.sans_datation:
            meta = undated_meta(rate)
        else:
            with open(meta_path) as handle:
                meta = json.load(handle)
        result = analyse(
            samples, rate, meta, noise_factor=args.seuil_bruit, relative=args.seuil_relatif,
            group_gap_ms=args.ecart_groupes,
        )
    except (OSError, ValueError, KeyError, InvalidInput) as error:
        print("ERREUR : %s" % error, file=sys.stderr)
        return EXIT_INVALID

    if args.json:
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    else:
        print(format_report(result, args.wav, detail=args.detail))
    return EXIT_OK if result["groupes"] else EXIT_NOTHING


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
