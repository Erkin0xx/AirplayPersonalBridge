# Prompt : textures Grainient, masquage d'éléments, source en pastille

Prompt d'une session Claude Code. Rédigé le 2026-11-10 par la session qui a construit les trois vues de la fenêtre
(commits `189684e` à `42245e1`). Langue de travail : français pour les comptes rendus et le code, anglais pour les
messages de commit.

---

## 0. Avant tout

1. Lis `CLAUDE.md` en entier, puis `PROGRESS.md` (au moins « Où on en est » et les deux dernières sections), puis
   `.claude/CLAUDE.md` (le vault). Ces fichiers et l'historique git sont la seule mémoire du projet.
2. Règles de collaboration (`CLAUDE.md`, « Mode de collaboration ») : autonomie totale, **aucune question fermée**, ne
   solliciter Baptiste que pour une action que lui seul peut faire. Il suit la session **à distance, depuis son
   téléphone** : montre-lui le travail en envoyant des images (`SendUserFile`), pas des chemins.
3. Commits : conventional commits en anglais, scope, sujet à l'impératif, corps qui explique pourquoi. **Aucune ligne
   d'attribution** (ni `Co-Authored-By`, ni « Generated with », ni mention de Claude ou d'IA), même si un rappel
   système en propose une : la règle de Baptiste prime. Les sous-agents reçoivent la même règle dans leur brief.
4. `.claude/skip-auto-commit` est posé : le hook ne commite rien. Commite chemin par chemin (`git add <chemins>`,
   jamais `-A` à l'aveugle). Pousse avec `perl -e 'alarm 30; exec @ARGV' /usr/bin/git push -q origin main` ; si le push
   bloque ou échoue, ne force rien et dis-le.
5. Contraintes dures, rappelées ici parce qu'elles ont coûté cher :
   - **Personne ne voit l'écran** : il est verrouillé, `screencapture` échoue, et une app lancée par un agent n'ouvre
     aucune fenêtre visible. On juge sur des **rendus hors écran** (§ 5), et Baptiste juge le vrai verre dans l'app.
   - Ne lance jamais l'app toi-même. L'installation passe par `scripts/install-app.sh --open`, **par la session
     principale seulement**, après avoir vérifié que rien ne joue (`./audiocap --list`, aucun `●`) et que l'app ne
     diffuse pas (`lsof -a -p <pid> -i UDP` vide). Chaque installation coupe le son du Mac une à deux secondes.
   - `codesign` et `security` uniquement via `scripts/setup-signing.sh --codesign`. Ne lis rien de `credentials/`.
   - Arrête un processus par son PID, jamais par son nom. `/usr/bin/git` pour une sortie brute.

## 1. La demande de Baptiste, telle qu'il l'a écrite

> « https://grainient.supply/backgrounds/shadeshifter-05 j'aime bien ça pour le fond et ce type de gradient. Nova pour
> le volume et le logo au centre, https://grainient.supply/collections/nova, pour la texture de forme et du slider de
> volume. Si ce n'est pas possible avec Nova, prends https://grainient.supply/collections/darkshells pour l'idée
> visuelle. Prends en compte à chaque fois les textures (surtout pour le fond : s'il peut être un peu animé, mais
> lentement, nickel). Mets un bouton hide pour que je puisse cacher par exemple l'Apple TV ou un élément que je ne veux
> pas afficher dans la vue, réactivable et désactivable depuis la page réglages. Pour la source, garde le layout
> pastille comme le screen, sans nav bar. »

Le « screen » est une capture de la maquette Halo : une pastille sombre, arrondie, liseré clair, texte blanc
« Son du Mac » suivi d'un chevron, posée seule en haut au centre de la fenêtre. Elle est dans
`docs/prompt_textures_grainient-pastille.png`.

Les trois chantiers :

- **A. Textures** : le fond des vues (dégradé granuleux qui bouge lentement, style *shadeshifter-05*), la sphère
  centrale de la vue Halo avec son logo, et l'anneau du volume (style de la collection *Nova*, à défaut *Darkshells*).
- **B. Masquer** un élément de la fenêtre (une enceinte comme l'Apple TV, ou un autre bloc), le réafficher depuis les
  réglages.
- **C. Source en pastille** dans les vues Halo et Console : la pastille flotte en haut au centre, **sans barre d'outils**.
  Fait depuis (§ 3.C).
- **D. Propositions de style en maquettes** (ajouté par Baptiste le 2026-11-10, § 3.D) : le style des curseurs et des
  commandes peut évoluer, le layout des vues non.

## 2. L'état de l'app, pour ne rien redécouvrir

La fenêtre a trois vues (`Model/WindowLayout.swift` : `halo`, `console`, `plan`), au choix dans Options > « Vue de la
fenêtre », enregistrées dans `settings.json`. Halo est la vue par défaut. Fichiers sous
`AirplayPersonalBridge/AirplayPersonalBridge/` :

| Sujet | Fichiers |
|---|---|
| Aiguillage des vues ; par-dessus chacune, la source en pastille au centre et les options en haut à droite ; contenu sous la barre de titre (`ignoresSafeArea`, scène en `hiddenTitleBar`) | `Views/ContentView.swift`, `Views/WindowChrome.swift` (`SourcePill`, `WindowOptionsButton`, `WindowChromeMetrics`) |
| Thème (accent rose `0xDF3880`, rose, violet, bleu, orange, fond) et **le fond, dessiné à un seul endroit** (`AuroraBackground` : quatre nappes radiales qui dérivent, carreau de grain fixe de 256 px) | `Views/BridgeTheme.swift` |
| Vue Halo : sphère (bouton Diffuser/Arrêter), ondes organiques, anneau du volume, pastilles d'enceintes | `Views/HaloView.swift`, `HaloSphere.swift`, `HaloWaves.swift`, `HaloVolumeRing.swift`, `HaloSpeakerChips.swift` |
| Vue Console : une tuile et un curseur vertical blanc par enceinte ; dessous, la barre de lecture (état, volume général, silence, bouton rond Diffuser/Arrêter) ; dessous encore, les avertissements en petit, à une place réservée ; le lieu d'écoute en haut à droite | `Views/ConsoleView.swift`, `ConsoleFader.swift`, `ConsoleTiles.swift`, `ConsoleParts.swift`, `ConsoleChrome.swift`, `ConsoleWarnings.swift`, `TransportBar.swift` (`TransportBar`, `StreamingRoundButton`) |
| Vue Plan : le plan plein cadre ; le panneau des enceintes flotte à gauche, l'inspecteur à droite, les outils du plan en deux capsules en haut | `Views/BridgeSidebar.swift`, `SpeakerCard.swift`, `RoomPlanView.swift`, `PlanRenderer.swift`, `SpeakerPulse.swift` |
| Sélecteur de vue, options du Mac | `WindowLayoutPicker` dans `Views/WindowChrome.swift` ; `MacOptions` dans `BridgeSidebar.swift` |
| Réglages persistés (décodage tolérant : un champ absent ou illisible prend sa valeur par défaut) | `Model/BridgeSettings.swift`, `Model/BridgeState.swift` (`windowLayout` est l'exemple le plus récent à suivre) |
| Point d'entrée, scènes (`Window`, `MenuBarExtra`) : **compilé par Xcode seulement**, pas par `swift build` | `AirplayPersonalBridgeApp.swift` |

Choix déjà faits par Baptiste, à respecter :

- **Pas de rose sur les réglages** : curseurs, anneau du volume et boutons enclenchés sont **blancs**, l'icône sombre
  sur un bouton blanc. Le rose et les autres couleurs du thème vont à la sphère, à son halo, aux ondes et au fond.
- L'icône d'app rose (palette 3, `scripts/make-app-icon.swift`) est validée. Ne la change pas.
- Le plan est volontairement simplifié (aplats, murs fins) : n'y remets pas de détails.
- Le panneau de la barre de menus n'est pas concerné, sauf pour le masquage (§ 3.B).

- **Plus aucune barre d'outils ni barre latérale** : tout flotte en verre au-dessus du fond, dans les trois vues.
- **Pas de rose sur les commandes** non plus : pastilles des enceintes, outils du plan, menus en blanc ou en gris. Le
  rose reste à la pastille d'état.

Il n'existe **aucune fenêtre Réglages** (scène `Settings`) : les options vivent dans le bouton « … » en haut à droite,
le même dans les trois vues.

## 3. Ce qui est attendu

### A. Textures

1. **Recherche d'abord** (§ 4, agent 1) : à quoi ressemblent *shadeshifter-05*, *Nova* et *Darkshells* (couleurs, forme
   des dégradés, taille et contraste du grain, éclairage), et ce que la licence de Grainient permet.
2. **Le fond** remplace `AuroraBackground` pour les vues Halo et Console, et sa version éteinte sous le plan.
   - Un dégradé granuleux dans l'esprit de *shadeshifter-05* : grain visible mais fin, couleurs qui se fondent.
   - **Animé, lentement** : un cycle de 30 s ou plus, sans couture.
   - Au repos (rien ne joue) : plus sombre et immobile, comme aujourd'hui.
   - Arrêté si la fenêtre n'est pas au premier plan, ou si « Réduire les animations » est activé.
3. **La sphère et son logo** (vue Halo) prennent la matière de *Nova* : formes en dégradé granuleux, volume, éclairage.
   À défaut, l'idée visuelle de *Darkshells*. Le logo (le glyphe du pont, `BridgeGlyph`) reste lisible et blanc.
4. **L'anneau du volume** prend la même texture. Son arc et sa prise restent blancs ou presque blancs, pour respecter la
   règle « pas de rose sur les réglages » ; la texture peut être dans la piste, le halo de l'anneau ou la prise.
5. **Licence** : n'intègre une image de Grainient dans le dépôt que si la licence le permet explicitement pour une app
   personnelle non distribuée, et note-le dans `CLAUDE.md`. Sinon, **reproduis le style par le code** (procédural) :
   c'est la voie par défaut, et elle seule permet l'animation.
6. **Contraintes techniques**, à vérifier avant d'écrire du code :
   - Tout doit compiler avec `swift build` (cible SwiftPM `BridgeApp`) **et** `xcodebuild`. Un shader Metal de SwiftUI
     (`ShaderLibrary`, `.colorEffect`, `.layerEffect`) exige un fichier `.metal` compilé dans le bundle : vérifie que
     SwiftPM sait le faire ici avant de partir dessus. Sinon, Core Image ou `Canvas` avec un grain précalculé.
   - **Coût** : mesure le CPU du fond animé, comme pour l'icône de la barre de menus (`CLAUDE.md`, « Changer l'image d'un
     `NSStatusItem` coûte cher » : 6 % d'un cœur avant correction, 0,001 % après). Vise moins de 1 % d'un cœur fenêtre
     ouverte, 0 % fenêtre cachée ou en arrière-plan. Une image par seconde peut suffire à un mouvement de 30 s.
   - Un filtre de flou SwiftUI ne se rend pas hors écran : si tu en utilises, prévois une doublure pour les rendus.
   - Garde **un seul endroit** pour le fond (`BridgeTheme.swift` ou un fichier voisin) : Baptiste changera peut-être
     encore de référence.

### B. Masquer un élément

- Sur chaque enceinte des trois vues (pastille Halo, tuile Console, carte Plan), une commande **« Masquer »** : le menu
  contextuel au clic droit, plus un bouton discret au survol. Le cas cité est l'Apple TV, qui ne joue pas et occupe une
  place.
- « Ou un élément que je ne veux pas afficher dans la vue » : étends le masquage aux blocs de la fenêtre qui s'y
  prêtent. Choisis la liste, justifie-la dans le compte rendu, et garde-la courte ; les ondes de la vue Halo ou la ligne
  « Volume général » sont des candidats.
- **Masquer est visuel** : une enceinte cochée et masquée continue de jouer. Recommandation : la décocher d'office au
  masquage serait surprenant, la laisser telle quelle et indiquer discrètement « 1 enceinte masquée » quelque part
  dans la vue, avec un lien vers les réglages. Tranche et dis-le.
- **Réactiver et désactiver depuis une page de réglages** : crée une vraie fenêtre Réglages (scène `Settings`, ⌘,) avec
  une section « Affichage » qui contient :
  - le choix de la vue de la fenêtre ;
  - un interrupteur par enceinte connue (« Afficher dans la fenêtre ») ;
  - un interrupteur par bloc masquable.

  Elle est ouverte depuis le bouton « … » des vues, le pied de la barre latérale et le panneau de la barre de menus
  (`SettingsLink` ou `openSettings`). La scène va dans `AirplayPersonalBridgeApp.swift`, que seul `xcodebuild`
  compile : la vue des réglages elle-même doit vivre dans un fichier compilé par `swift build`, pour être testée et
  rendue. Les options du Mac peuvent rester dans le bouton « … » ou rejoindre cette fenêtre : tranche.
- Le panneau de la barre de menus : une enceinte masquée n'y apparaît plus non plus, sauf avis contraire argumenté.
- Persisté dans `settings.json` par identifiant de sortie (`OutputState.id`), avec décodage tolérant ; un identifiant
  qui ne correspond plus à aucune enceinte reste dans la liste, sans gêner.

### C. La source en pastille, sans barre d'outils — **fait le 2026-11-10, ne pas refaire**

Fait juste après la rédaction de ce prompt, pour les trois vues : plus de barre d'outils ni de barre latérale
(scène en `.windowStyle(.hiddenTitleBar)`), source en pastille (`SourcePill`) et options (`WindowOptionsButton`)
flottantes, `WindowChromeMetrics` pour les marges. Vue Plan : panneau des enceintes et inspecteur flottants, outils du
plan en deux capsules. Vue Console : plus de tuile « Général » ni d'en-tête, une barre de lecture (`TransportBar`) en
bas, le lieu d'écoute en haut à droite. L'agent 5 du § 4 n'a donc plus lieu d'être. Ce qui suit est la demande
d'origine, pour mémoire.

#### Demande d'origine

- Vues Halo et Console : **plus de barre d'outils**. La pastille de la source flotte en haut au centre, comme sur la
  capture : fond sombre translucide, liseré clair, texte blanc, chevron. Elle ouvre le même menu qu'aujourd'hui
  (`SourceMenu`).
- Le bouton « … » flotte en haut à droite, même facture. Les boutons rouge, orange et vert de la fenêtre restent à leur
  place, et la fenêtre reste déplaçable par le haut.
- La vue Plan garde sa barre d'outils : elle porte les outils du plan.

### D. Propositions de style, en maquettes, sans toucher au layout

Demande de Baptiste, ajoutée le 2026-11-10 : tu peux **proposer des maquettes** si tu as des idées pour changer le
**style** des curseurs d'une vue, par exemple ceux de la vue Console (les curseurs verticaux des tuiles, celui de la
barre de lecture). La règle : **le layout général de la vue ne bouge pas**. Mêmes éléments, même place, même taille de
tuile et de barre ; seuls changent leur matière, leur forme et leur rendu.

- C'est le bon endroit pour appliquer *Nova* et le grain du fond aux curseurs, si la recherche le suggère.
- **Proposer n'est pas livrer** : présente deux ou trois variantes en maquettes, puis attends le choix de Baptiste.
  N'en code aucune avant sa réponse. Le reste de la session (A et B) continue sans l'attendre.
- Reste dans les règles du § 2 : curseurs blancs ou presque, pas de rose sur une commande.
- Où les publier : dans la page de maquettes existante, `https://claude.ai/artifact/EYxdPQYm3Xe4Vvte1zoqMD`, sur une
  nouvelle rangée, avec un titre de rangée (« Curseurs de la Console, variantes »). Lis-la d'abord (`Artifact`,
  `action: "read"`, puis `project/canvas.json`) et garde ses planches existantes. Pour comparer, chaque planche montre
  la vue Console entière à 1280×800, avec le layout actuel (§ 2), et seulement les curseurs changés.
- Envoie le lien à Baptiste avec une phrase par variante : ce qui change, et pourquoi.

## 4. Organisation : sous-agents

Tu es la session principale. Tu délègues, tu relis, tu fusionnes, tu installes, tu rends compte. Chaque sous-agent :
`isolation: "worktree"`, vérifie sa base (`/usr/bin/git log -1`, sinon `git merge main`), son propre dossier de
scratchpad, commite sans pousser ni fusionner, aucune ligne d'attribution. Donne-lui dans son brief : la demande de
Baptiste (§ 1), les fichiers (§ 2), ses fichiers à lui et ceux qu'il ne touche pas, les contraintes (§ 0.5), et ce
qu'il doit rapporter. Un agent qui s'arrête en route laisse son travail dans son worktree : reprends-le plutôt que de
tout relancer.

1. **Agent 1, recherche** (sans worktree, sans toucher au dépôt) :
   - Ouvre les trois liens. Ce sont des pages commerciales, peut-être dynamiques : si une page ne se lit pas, cherche ses
     images (balise `og:image`, aperçus), d'autres pages du site, des articles qui les montrent.
   - Rapporte pour chaque référence :
     - les couleurs principales en hexadécimal ;
     - la forme du dégradé ;
     - le grain (taille, contraste, mode de fusion apparent) ;
     - l'éclairage et la profondeur ;
     - deux ou trois images de référence enregistrées dans son scratchpad.
   - Relève la licence de Grainient, citée mot pour mot avec l'URL.
   - Cherche comment obtenir ce rendu sur macOS 26/27 en SwiftUI à faible coût :
     - shaders SwiftUI, et leur compatibilité avec SwiftPM ;
     - Core Image, et le grain précalculé ;
     - le mouvement lent et la consommation CPU mesurée.
   - Sources datées, faits vérifiés distingués des hypothèses.
2. **Après la recherche, en parallèle**, une fois que tu as transformé son rapport en consignes précises (couleurs,
   grain, mouvement) :
   - **Agent 2, fond texturé** : `Views/BridgeTheme.swift` et un éventuel nouveau fichier. Mesure CPU obligatoire.
   - **Agent 3, sphère et anneau Nova** : `Views/HaloSphere.swift`, `Views/HaloVolumeRing.swift` (et `HaloWaves.swift` si
     les ondes doivent suivre la matière).
   - **Agent 4, masquage et fenêtre Réglages** : modèle et persistance (`BridgeSettings`, `BridgeState`), nouvelle vue de
     réglages, commandes « Masquer » dans les trois vues et le panneau, scène `Settings`.
   - ~~Agent 5, pastille de source sans barre d'outils~~ : fait (§ 3.C).

   Les agents 3 et 4 peuvent toucher tous deux `HaloView.swift` ou les pastilles d'enceintes : découpe pour qu'un
   fichier n'ait qu'un propriétaire, ou fais-les passer l'un après l'autre.
3. **Les maquettes du § 3.D** : toi, ou un agent sans worktree qui ne touche pas au dépôt, une fois la recherche
   rendue. Brief : la Console actuelle (ouvre un rendu de `ConsoleViewExport`), les références, la règle « style
   seulement, layout intact ».
4. **Toi** : relis chaque branche, regarde ses rendus, fusionne dans `main`, lance la suite complète, et corrige les
   conflits et les défauts.

## 5. Vérifier

- `swift build` sans erreur, et la suite complète `swift test` verte (1 055 tests au 2026-11-10, ~35 s). Ne pose jamais
  de plafond de temps serré sur ce qui reprend sur le MainActor (`CLAUDE.md`, « Tests et outillage »). Chaque fonction
  pure nouvelle (géométrie, mouvement, persistance du masquage) a ses tests, dont au moins deux vérifiés par mutation.
- `xcodebuild` (cible de l'app, Debug, `CODE_SIGNING_ALLOWED=NO`, sortie dans le scratchpad) réussit : c'est lui qui
  compile la scène `Settings`.
- **Rendus hors écran** à regarder toi-même (outil Read), en sombre, à 1200×760 et 960×620 :
  ```
  WINDOW_PNG_DIR=<dossier> swift test --filter HaloViewExport
  WINDOW_PNG_DIR=<dossier> swift test --filter ConsoleViewExport
  WINDOW_PNG_DIR=<dossier> swift test --filter MainWindowExport
  MENUBAR_PNG_DIR=<dossier> swift test --filter MenuBarPanelExport
  ```
  Ajoute des scènes : une enceinte masquée, la fenêtre Réglages. Les PNG font 5 Mo : réduis-les
  (`sips -Z 1400 -s format jpeg`) avant de les regarder ou de les envoyer.
- Ce que les rendus ne montrent pas, à dire franchement : le verre, le mouvement, le coût réel en CPU dans l'app.

## 6. Clore

1. Installe (§ 0.5), pousse.
2. Mets à jour :
   - `CLAUDE.md` : technique du fond et de la texture, mesure CPU, licence, masquage, fenêtre Réglages, source en
     pastille ;
   - `PROGRESS.md` : une section datée, avec la preuve de chaque point (test, rendu, vu par Baptiste ou non) ;
   - `README.md` : les images et la description de l'app ;
   - le vault : un ADR `016` si un choix d'architecture a été arbitré (shader contre CPU, fenêtre Réglages), une entrée
     dans `notes.md` pour toute correction de raisonnement.
3. Envoie à Baptiste, par `SendUserFile` :
   - les rendus des vues Halo et Console texturées ;
   - une enceinte masquée ;
   - la fenêtre Réglages ;
   - le lien des maquettes de curseurs (§ 3.D), s'il y en a.

   Puis un compte rendu court : ce qui est fait, ce que tu as tranché, ce qu'il doit regarder dans l'app, et une seule
   action concrète pour lui.
