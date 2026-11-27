# Audit performance final (2026-11-27)

**Question :** le plugin est-il prêt pour un vrai jeu, après le plan qualité (phases 1 à 5, commits befdad4 à 8472faa) ?

## Méthode

- **Comparaison A/B :** le code d'avant le plan (1946b7e, copié dans le dossier temporaire) contre le code actuel. Mêmes outils, lancés en alternance (nouveau, ancien, nouveau, ancien), car ce PC varie d'environ ×1,5 d'une exécution à l'autre.
- **Machine :** PC portable (Iris Xe), Godot 4.7.2, rendu Mobile, fenêtre hors écran.
- **Téléphone :** il n'était pas branché, donc il n'a pas été mesuré. Un téléphone de milieu de gamme (Tecno, Helio G99) est environ 3× plus lent que ce PC côté CPU.
- **Outils :**
  - `profile_stream_frames`, `profile_memory`, `audit_perf` et `profile_load_steps` (existants) ;
  - `tools/profile_game_api.gd`, nouveau : il mesure l'API de jeu des phases 2 et 3.

## Verdict

**Pour un jeu qui ne modifie pas le terrain en cours de partie, c'est prêt.** Rien n'a régressé : le GPU, la mémoire et le chargement sont identiques, ou un peu meilleurs.

**Pour un jeu qui creuse ou construit en cours de partie, il reste trois saccades à corriger** (constats 1 à 3). Elles gèlent l'image 0,1 à 0,3 s sur PC, donc environ 0,3 à 0,9 s sur téléphone.

## Rien n'a régressé (A/B)

| Mesure | Avant le plan | Maintenant | Lecture |
|---|---|---|---|
| GPU par vue, savane 192 (9 vues) | 2,5 – 5,0 ms | 2,4 – 4,1 ms | égal (bruit ±0,5 ms) |
| Triangles à l'écran | 108 k – 213 k | 108 k – 206 k | −3 à −7 % (herbe lointaine allégée) |
| Draw calls | 69 – 155 | 69 – 155 | identique |
| Travail du chargement (177 étapes) | 743 ms | 749 ms | identique |
| Collision au chargement (36 chunks) | 49 ms | 48 ms | identique |
| Streaming, monde ouvert 10 m/s : moyenne / p99 | 0,41 – 0,43 / 4,0 – 4,2 ms | 0,44 – 0,47 / 4,3 – 4,6 ms | **+8 %**, léger |
| RAM, monde ouvert construit | +21,4 Mo | +22,4 Mo | +1 Mo |
| Mémoire vidéo, monde ouvert construit | 79,7 Mo | 79,9 Mo | +0,3 Mo |
| Temps de construction du monde ouvert | 9,8 s | 9,7 s | identique |

**Deux nuances :**
- **Le chargement complet** paraît plus lent : 2,25 – 2,74 s contre 2,0 – 2,1 s. Mais le travail de chaque étape est le même (749 contre 743 ms). L'écart vient du rythme des images sur ce PC, pas du plugin.
- **Le +8 % du streaming** est le seul écart constant d'une passe à l'autre. Il vient probablement de la seconde MultiMesh de l'herbe lointaine (phase 4b). En échange, l'image affiche moins de triangles.

## Gains de l'éditeur (phase 1, mesurés)

- **Collision après un coup de pinceau :** 1 forme sur 37 est refaite, en **3,6 ms au lieu de 1 501 ms**.
- **Undo :** un trait ne garde que la zone touchée, soit **0,3 à 0,5 %** de la copie complète (4 Ko au lieu de 1 Mo). La végétation en garde 10 %.
- **Herbe lointaine :** 3,7 ms pour toute la carte, +0,9 Mo.

## L'API de jeu (phases 2 et 3)

**Ce qui va bien :**
- **Les questions sont rapides :**
  - `get_height` : 2,6 – 3,3 µs ;
  - `get_normal` : 3,2 – 4,0 µs ;
  - `get_ground_style_name` : 2,4 – 3,3 µs ;
  - `get_intersection` : 50 – 83 µs.

  1 000 PNJ par image coûtent environ 3 ms.
- **Navigation :** un bake de toute la savane prend 0,8 s, et un carré de 128 m sur le monde ouvert 0,22 s. Le runtime le fait sur un fil séparé (`bake_navigation`), donc sans saccade.
- **Heightmap :** export et import en 20 ms sur 192, et en 0,45 s sur 1 024. C'est un outil d'éditeur.

### 1 · [Majeur] · Monde ouvert : chaque `commit_edits` recopie toute la carte pour les questions

- **Ce qui se passe :** après un commit, le premier `get_height` refait la copie des hauteurs, des cases et des styles. C'est une boucle GDScript sur 1 048 576 sommets.
- **Coût :** 90 – 274 ms sur PC, à chaque modification. Le tout premier appel coûte aussi 88 – 103 ms.

```
open world 1024 streamed commit steps (ms): … | query: carve 0.0 + copy 273.7
open world 1024 streamed questions: first call 103.0 ms (+5.7 MB RAM)
```

- **Correction :** mettre à jour la copie seulement dans le rectangle modifié, en place, ce qui prend environ 1 ms. Le runtime ne prête jamais cette copie (`get_query()` en fait une nouvelle), donc c'est sûr. Pour le premier appel, préparer la copie sur un fil séparé à `terrain_ready`.

### 2 · [Majeur] · Monde ouvert : le lit des rivières est recalculé pour un trou loin de l'eau

- **Ce qui se passe :** `RiverMesher.any_river_near` teste le rectangle qui englobe toute la rivière. Sur 1 024 cases, les rivières serpentent, donc ce rectangle couvre presque toute la carte. 3 trous sur 4 relancent `compute_carve`, qui refait toute la carte sur le fil principal, même quand rien ne change.
- **Coût :** 105 – 138 ms, avec « +0 chunks » changés.

```
open world 1024 streamed commit steps (ms): river near true 0.1 | river carve 106.5 (+0 chunks) | …
```

- **Correction :** tester la distance aux segments de la rivière, pas le rectangle englobant. Quand la rivière est vraiment touchée, recalculer seulement son réseau, ou le faire sur un fil séparé comme le reste du streaming.

### 3 · [Majeur] · Terrain construit entier : un trou près d'une route refait toutes les routes dans l'image

**Coût de `commit_edits` avec les réglages par défaut du runtime** (sol entier, végétation différée) :

| Cas | Coût |
|---|---|
| Trou sans route | 30 – 63 ms (2 chunks, collision, mares) |
| Trou sur une route | 112 – 142 ms, dont 69 – 78 ms pour le maillage des routes |

```
savanna 192 runtime defaults commit steps (ms): … roads near true | … | roads mesh 78.1 | …
```

- **Correction :** reprendre le chemin du streaming, où les routes sont recoupées sur un fil séparé (`_start_edit_roads`). Ou ne refaire que les morceaux de route proches du rectangle.
- **Remarque :** le premier trou paie aussi les mares (23 ms, une seule fois).

### 4 · [Note] · `export_edits` grossit avec l'écart entre les trous

- **Ce qui se passe :** l'export garde un seul rectangle qui englobe toutes les modifications. Cinq petits trous éparpillés sur le monde ouvert pèsent donc **724 Ko**, et 45 Ko sur la savane.
- **Correction :** un rectangle par bloc touché (par exemple 32 × 32). La sauvegarde suivrait alors la surface réellement modifiée.

## Non vérifié

- **Le téléphone :** les phases 1 à 4 n'y ont pas été mesurées, en particulier le shader du sol texturé (phases 1a et 4a). Sur Mali, c'est le remplissage des pixels qui coûte. Il faut lancer la série `final` de `phone_bench` quand le Tecno est branché.
- **Le sol texturé sur PC :** cet audit a mesuré la savane non texturée. `check_splat_reads` prouve seulement que l'image ne change pas.

## Ordre conseillé

1. Constat 1 (copie des questions) : petit, et le plus gros gain sur le monde ouvert.
2. Constat 2 (test des rivières) : petit, il supprime 105 – 138 ms sur la plupart des trous.
3. Constat 3 (routes sur un fil séparé) : moyen.
4. Le bench du téléphone.
5. Constat 4 (taille de la sauvegarde) : seulement si le jeu sauvegarde beaucoup de modifications.

## Appliqué (2026-11-27) : constats 1 à 3

Mesuré avec `tools/profile_game_api.gd` sur le même PC, avant et après.

| Cas | Avant | Après |
|---|---|---|
| Première question (`get_height`), monde ouvert | 88 – 103 ms, +5,7 Mo | **0,1 ms**, +0 Mo |
| Question après un commit, monde ouvert | 90 – 274 ms | **0,1 ms** |
| `commit_edits`, monde ouvert, trou loin de l'eau | 110 – 214 ms | **1,2 – 1,5 ms** |
| `commit_edits`, savane entière (défauts), trou sur une route | 112 – 142 ms | **32 – 62 ms**, puis une image de 13 – 25 ms quand les routes arrivent |
| `commit_edits`, savane entière (défauts), trou sans route | 30 – 63 ms | inchangé (bruit ±1,5×) |

**Ce qui a changé dans le plugin :**
1. **Questions sans recopie** (`core/terrain_query.gd`) :
   - les hauteurs, les cases et les styles sont copiés avec `duplicate()`, où Godot ne copie la mémoire qu'à la prochaine écriture du terrain ;
   - le creusement des rivières est partagé, car le builder le remplace mais ne l'écrit jamais ;
   - la hauteur dessinée (hauteur − creusement + décalage) est calculée à chaque réponse ;
   - la plage de hauteurs est cherchée au premier `get_height_range()`.
2. **Rivière proche par segments** (`RiverMesher.any_river_near`, Liang-Barsky sur la zone agrandie de la portée des berges + une case). Sur 90 trous du monde ouvert, 60 sont jugés loin, contre 14 avec le rectangle englobant. Aucun trou jugé loin n'a changé le lit. 21 trous proches l'ont changé, et passent bien par le recalcul. Le test prend 0,25 ms.
3. **Routes sur un fil séparé, sol construit entier** (`_start_edit_roads` / `_step_edit_roads`, version non découpée). `_process` reste actif le temps du calcul, et `is_streaming_idle` vaut false pendant ce temps.

**Contrôles :**
- nouveau `check_river_near.gd`, ajouté à `run_checks` ;
- `run_checks` : tout passe, empreintes comprises, smoke 193/0, typage 0. Restent les 2 échecs habituels : la scène locale `savanna_128` et l'ordre du brouillard.

**Reste :**
- un trou **sur** une rivière recalcule toujours son lit (environ 105 ms sur 1 024 cases) ;
- sur une savane construite entière, la reconstruction des chunks prend environ 15 ms par chunk ;
- le constat 4 (taille de la sauvegarde) et le bench du téléphone.
