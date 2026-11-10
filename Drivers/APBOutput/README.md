# APBOutput — sortie virtuelle de calage vidéo

Un AudioServerPlugIn (pilote Core Audio en espace utilisateur, chargé par `coreaudiod`) qui ajoute au Mac
une sortie nommée **« AirPlay Personal Bridge »**. Elle se présente comme une sortie 48 kHz stéréo
float32, **jette tout ce qu'on lui envoie**, et annonce dans `kAudioDevicePropertyLatency` le retard réel
de la diffusion vers les enceintes (~0,45 s depuis le 2026-11-10, ~2,3 s avant).

## Pourquoi

Pendant une diffusion, les applications jouent sur une sortie du Mac qui annonce quelques millisecondes
de latence, alors que le son sort des enceintes ~0,45 s plus tard. Les lecteurs vidéo calent l'image sur
la latence annoncée : l'image part donc ~0,45 s avant le son. Chromium (donc Dia) retarde l'image de
`kAudioUnitProperty_Latency` + `kAudioDevicePropertyLatency` + `kAudioStreamPropertyLatency`, **sans** le
safety offset. Un agrégat Core Audio ne sait pas annoncer cette latence (il la range dans le safety
offset) : d'où un pilote. Détails et mesures : `CLAUDE.md`, « Retard de bout en bout et vidéo », et l'ADR
014 du vault.

Rien de ce qui part sur le fil ne dépend du pilote : le son réel est capté par le Process Tap de l'app,
en amont de toute sortie. Le pilote ne change que ce que les applications du Mac croient.

## Ce qu'il expose

| Élément | Valeur |
|---|---|
| UID du périphérique | `fr.baptiste.airplaypersonalbridge.output` |
| Format | 48 000 Hz, 2 canaux, float32 entrelacé |
| `kAudioDevicePropertyLatency` (sortie) | la valeur réglée, 0 tant que rien n'est écrit |
| Latence du flux, safety offset | 0 |
| Propriété personnalisée `'apbL'` | latence en trames, `CFNumber`, lecture et écriture, 0 à 480 000 (10 s) |
| Volume, sourdine | contrôles de l'élément principal : les touches du Mac y ont prise |

La latence se règle **à chaud** par la propriété `'apbL'`, écrite par l'app ou par
`swift run audiocap --video-latency auto`. Le pilote la garde d'une relance de `coreaudiod` à l'autre
grâce au stockage de l'hôte : dans le bac à sable de `coreaudiod`, il ne lit aucun fichier de
l'utilisateur. La valeur à écrire se calcule à un seul endroit : `VideoSyncLatency`
(`Sources/AudioCore/VirtualOutputDevice.swift`), délai de restitution + résidu mesuré au micro.

Une application lit la latence **à l'ouverture de son flux** : une page déjà ouverte doit être rechargée.

## Compiler, installer, désinstaller

```bash
Drivers/APBOutput/build.sh          # sans sudo : compile (arm64 + x86_64) et signe
sudo scripts/install-driver.sh      # copie, règle sudoers, relance de coreaudiod
sudo scripts/uninstall-driver.sh    # retire le pilote et la règle, relance coreaudiod
```

La relance de `coreaudiod` **coupe tout le son du Mac une à deux secondes**, et fait reconstruire la
capture de l'app si elle tourne.

`install-driver.sh` pose aussi `/etc/sudoers.d/airplay-bridge` (root:wheel, 0440), vérifiée par
`visudo -cf` avant d'être mise en place :

```
<utilisateur> ALL=(root) NOPASSWD: /usr/bin/killall coreaudiod
```

L'app s'en sert en quittant (`/usr/bin/sudo -n /usr/bin/killall coreaudiod`). Sans la règle, elle
journalise l'échec et quitte quand même.

Signature : uniquement par `scripts/setup-signing.sh --codesign` (appelé par `build.sh`). Un appel direct
à `codesign` ouvrirait une fenêtre de trousseau.

## Vérifier

```bash
swift run audiocap --video-sync                       # pilote présent ? latence réglée ? sortie par défaut ?
VIRTUAL_OUTPUT_TESTS=1 swift test --filter VirtualOutputIntegration
/usr/bin/log show --last 5m --predicate 'subsystem == "fr.baptiste.airplaypersonalbridge.output"'
```

## Temps réel

Les règles du CDC (sections 12 et 13) valent dans l'IO du pilote : `GetZeroTimeStamp`,
`WillDoIOOperation`, `BeginIOOperation`, `DoIOOperation` et `EndIOOperation` n'allouent rien, ne
prennent aucun verrou et ne journalisent rien. L'horloge y est une fonction pure de l'heure hôte et
d'une ancre atomique posée au premier `StartIO`. Le verrou du pilote ne protège que les propriétés.

Écrit d'après `AudioServerPlugIn.h` et l'exemple d'Apple « Creating an Audio Server Driver Plug-in ».
Rien n'est repris de BlackHole (GPL).
