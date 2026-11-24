# Rapport de performance – Lowpoly Terrain Editor (cible mobile)

Mesures du 2026-11-22 avec Godot 4.7.2 sur un portable à GPU intégré Intel Iris Xe,
en fenêtre 1280×720, vsync désactivée.

Où trouver les données :
- mesures après optimisation : `results/*.json` et `results/screenshots/` ;
- mesures d'avant : `results/before_optim/`.

> ⚠️ Ce PC n'est pas un téléphone. Les FPS absolus ne valent pas pour un mobile. Ce qui
> se transpose : les draw calls, les triangles, la mémoire, la taille des fichiers et les
> écarts relatifs. Un GPU de téléphone milieu de gamme est grossièrement 3 à 5× plus lent
> qu'un Iris Xe. **À confirmer sur un vrai appareil.**

## Optimisations appliquées au plugin

1. **Une surface par chunk.** Toutes les faces non texturées d'un chunk (dessus et
   falaises, tous styles confondus) forment une seule surface. La couleur du style est
   portée par les sommets. Les styles texturés gardent leur propre surface.
   Fichiers : `mesh/terrain_mesher.gd` et `mesh/mesh_utils.gd`.
2. **Matériaux partagés.** Les matériaux du terrain sont mis en cache et réutilisés par
   tous les chunks, au lieu d'un `duplicate()` par surface.
   Fichier : `materials/material_factory.gd`.
3. **Option « Mobile Water (no refraction) ».** Une case à cocher dans
   Inspecteur > Terrain Features > Rivers. Toutes les rivières du terrain utilisent alors
   `river_water_mobile.gdshader`, qui ne lit pas l'écran, donc sans copie de l'écran à
   chaque image. Le même shader est choisi automatiquement quand une rivière a
   Refraction Strength = 0. L'option est désactivée par défaut.

**Ce qui ne change pas :** la géométrie et la collision.
- Le harnais de comparaison le confirme sur les 16 étapes de son scénario : faces de
  collision identiques à l'octet près et même nombre de sommets par chunk.
- `tools/image_diff.gd` compare les captures avant et après : moins de 0,1 % de pixels
  différents en général, jusqu'à 3,8 % sur les vues rapprochées. Toutes les différences
  viennent des reflets animés de l'eau (à vérifier en comparant les PNG).
- `tools/check_optimizations.gd` passe ses 16 vérifications : styles texturés, partage
  des matériaux, double face, choix du shader d'eau.
- Le test de fumée dans l'éditeur passe ses 20 étapes.

## Terrains de test

Ils sont générés par `tools/build_terrains.gd` : une carte de pixels d'île procédurale
passe dans le générateur d'image du plugin. Chaque terrain a 3 styles, des collines, des
routes, des rivières et la collision. Le script enregistre aussi une variante
`*_mobilewater.tscn`.

| Taille | Triangles (terrain + routes/rivières) | Surfaces terrain avant → après | Matériaux uniques avant → après | .tscn avant → après |
|---|---|---|---|---|
| 64² | 6 744 | 20 → **4** | 22 → **3** | 1,1 → 1,0 Mo |
| 128² | 24 466 | 65 → **16** | 67 → **3** | 3,9 → 3,6 Mo |
| 256² | 83 954 | 156 → **47** | 159 → **4** | 13,4 → 12,4 Mo |

## Rendu en jeu : test A/B sur le 256²

Le portable change de fréquence d'un run à l'autre, ce qui fausse une comparaison avec
les mesures précédentes. J'ai donc fait un test A/B :
- `tools/make_split_variant.gd` reconstruit, depuis la même scène, l'ancien découpage
  (156 surfaces, un matériau dupliqué par surface) ;
- les deux variantes sont lancées en alternance, plusieurs fois de suite, dans le même
  état de la machine ;
- chaque run est une orbite caméra de 6 s.

| Renderer, 256² | Draw calls | CPU rendu ms | GPU ms | FPS |
|---|---|---|---|---|
| Compatibility, ombres | 296 → **97** | 3,9–4,2 → **2,8–3,0** | 4,3–4,6 → 3,9–4,1 | 185–196 → **218–225** |
| Compatibility, sans ombres | 160 → **51** | 1,7–1,8 → **0,9–1,0** | 1,6 → 1,4–1,6 | 393–431 → **478–533** |
| Mobile, ombres | 91 ¹ | 0,84–0,91 → **0,50–0,64** | 3,3 → 3,2–3,5 (égal) | 247–254 → 243–263 |

Effet de l'option **Mobile Water**, mesuré par runs séparés (sur le Mobile, comparer
plutôt à l'A/B ci-dessus) :

| Renderer, 256² | Sans Mobile Water | Avec Mobile Water |
|---|---|---|
| Mobile, ombres | GPU 3,8 ms, CPU 0,67 ms, VRAM 101 Mo | GPU **3,1 ms**, CPU **0,48 ms**, VRAM **89 Mo** |
| Mobile, sans ombres | GPU 1,61 ms, 450 FPS | GPU **1,30 ms**, **537 FPS** |
| Compatibility, sans ombres | CPU 1,2 ms, 423 FPS | CPU 1,05 ms, 466 FPS |

¹ Le renderer Mobile compte ici des objets, pas des surfaces. Le gain réel se lit dans
le « CPU rendu ».

**Ce qu'on en retient :**
- **Fusion des surfaces :** les draw calls sont divisés par 3. Le CPU de rendu baisse
  d'environ 30 % avec ombres et de 45 % sans, pour un GPU inchangé. C'est le CPU qui
  limite les téléphones d'entrée de gamme en Compatibility.
- **Mobile Water :** environ −0,3 ms de GPU et −12 Mo de VRAM, car il n'y a plus de
  tampon de copie de l'écran. Le gain sera plus grand sur un GPU mobile à tuiles. L'eau
  est un peu moins lumineuse, car elle ne reprend plus le fond par réfraction
  (`mobile_128_mobilewater_close.png`).
- **Ombres :** elles restent le premier coût GPU (3 à 4 ms, contre 1,3 à 1,6 ms sans).
  Le plugin n'y peut rien : c'est un réglage du projet.

## Chargement de la scène (`tools/load_test.gd`, après optimisation)

| Taille | .tscn texte | .scn binaire compressé |
|---|---|---|
| 256² | 12,4 Mo, 1 490 ms | 1,1 Mo, 240 ms |
| 128² | 3,6 Mo, 423 ms | 0,38 Mo, 55 ms |

L'export Godot convertit les ressources texte en binaire par défaut (option « Convert
Text Resources to Binary »). Il faut garder cette option activée.

## Côté éditeur : gel en fin de trait (corrigé)

Quand on relâchait un trait qui touche une route ou une rivière, le plugin reconstruisait
tout le mesh des routes et rivières. En 256², cela figeait l'éditeur environ 2 s. Le
détail est mesuré par `tools/profile_features.gd`.

| Étape (256²) | Avant | Après |
|---|---|---|
| Regroupement des routes/rivières qui se touchent | 111 ms | **6 ms** |
| Surface des routes | 261 ms | **115 ms** |
| Eau de la plus grande rivière | 1 386 ms | **58 ms** |
| `FeatureMesher.build` total | 1 767 ms | **208 ms** |
| **Fin d'un trait (gel)** | **2 185 ms** | **326 ms** |

Les deux colonnes ont été mesurées dans la même session, à quelques minutes
d'intervalle. Sous une charge du PC plus élevée, les runs suivants donnent 410 à 620 ms,
contre 1 600 à 2 200 ms avant.

**Ce qui a changé :**
- **Eau** (`mesh/river_mesher.gd`) : chaque case du rectangle englobant toute la rivière
  était testée contre chacun de ses ~130 segments, soit environ 1,8 million de calculs de
  distance. Le code ne teste plus que les cases proches de chaque segment, puis les ajoute
  dans le même ordre qu'avant.
- **Routes et berges** (`mesh/road_mesher.gd`, `river_mesher.gd`) : les données du
  terrain sont lues une seule fois au lieu d'une dizaine de `get_meta()` par point, et
  chaque coin partagé n'est calculé qu'une fois. Les variantes `*_in()` de
  `core/terrain_sampler.gd` donnent exactement le même résultat.
- **Regroupement** : `GridMath.polylines_within_distance()` saute les paires de segments
  dont les boîtes englobantes sont trop éloignées.

**Le résultat est identique à l'octet près :**
- le harnais de comparaison donne 64 éléments sur 64 identiques à l'original
  (routes, rivières, aperçu, collision, données) ;
- `tools/compare_feature_mesh.gd` reconstruit le mesh des 3 scènes enregistrées avec
  l'ancien code : positions, normales et UV sont identiques.

Il reste environ 0,3 s en 256². La moitié vient de la collision, qui est reconstruite en
entier ; l'autre moitié vient des routes.

Temps complets de `tools/build_terrains.gd` après correction (PC chargé) :

| Étape | 64² | 128² | 256² |
|---|---|---|---|
| `rebuild_all` complet | 95 ms | 372 ms | 1 228 ms (avant : 2 221 à 3 525 ms) |
| … dont routes + rivières | 26 ms | 152 ms | 226 ms (avant : 1 505 à 1 976 ms) |
| Pinceau, par échantillon | 44 ms | 28 ms | 42 ms |
| Fin d'un trait sur une route/rivière | 41 ms | 163 ms | 491 à 623 ms |

## Rendu du terrain : ombrage cuit (transitions, pente, AO)

Nouveau module `mesh/terrain_shading.gd`. Tout est calculé sur le CPU pendant la
construction du chunk, puis écrit dans les couleurs de sommets de la surface déjà fusionnée.
Au rendu, on garde le même shader, les mêmes draw calls et aucune texture. Cette approche
est classique en low-poly mobile.

| Effet | Ce que ça change | Réglage (Inspecteur > Rendering) | Défaut |
|---|---|---|---|
| Transition entre styles | Les couleurs des styles voisins sont floutées puis lues au centre de chaque face. Fini les bords en escalier. | Style Blend (cells) | 1 |
| Bruit de bordure | La frontière entre styles est décalée par un bruit doux, ce qui la rend organique. | Blend Border Noise | 0,6 |
| Teinte de pente | Les faces raides prennent la couleur de côté du style (herbe → terre ou roche). Fini les « dents » vertes au pied des montagnes. | Slope Tint / Start / Full | 0,75 / 30° / 50° |
| AO cuite | Les creux et les pieds de falaise sont assombris, les crêtes légèrement éclaircies. | Baked Ambient Occlusion | 0,5 |
| Variation par face | Légère variation de luminosité et de chaleur par triangle, pour casser les aplats. | Face Color Variation | 0,05 |
| Falaises | Elles sont plus sombres vers la base. | Cliff Bottom Darkening | 0,35 |
| Lèvre d'herbe | Une bande de la couleur du dessus en haut des murs (2 triangles de plus par quad de mur). | Cliff Top Lip | 0,2 |

Ces effets ne s'appliquent qu'aux styles sans texture. Les styles texturés ne sont pas
modifiés et ne « déteignent » pas sur leurs voisins.

**Vérifications :**
- **Tout à 0 :** les chunks sont identiques à l'octet près à ceux d'avant (64, 128 et 256),
  vérifié avec `tools/compare_chunks.gd --zero`.
- **Pas de couture entre chunks :** une cellule reçoit la même couleur quelle que soit la
  région construite (`tools/check_shading_seams.gd` répond CONSISTENT).
  La reconstruction partielle après un coup de pinceau élargit sa zone de
  `TerrainShading.influence_margin()`, soit Style Blend + 3 cellules.
- **Smoke test éditeur :** 20/20.

**Coût au rendu (256², A/B alterné, `scenes/terrain_256_flat.tscn` = sans ombrage) :**

| | Draw calls | Triangles | VRAM | fps (3 paires, Mobile) |
|---|---|---|---|---|
| Sans ombrage | 91 | 186 k | 100,8 Mo | 185 / 248 / 274 |
| Avec ombrage | 91 | 191 k (+2,7 %, la lèvre) | 101,0 Mo | 238 / 251 / 273 |

L'écart est dans le bruit de la machine, et c'est pareil en Compatibility (97 draw calls
dans les deux cas). Mettre **Cliff Top Lip** à 0 supprime les 2,7 % de triangles en plus.

**Coût dans l'éditeur :**
- **Préparation de l'ombrage :** environ 2,4 ms par chunk.
- **Reconstruction complète du 256² :** environ 0,55 s → 0,85 s (meilleur de 3).
- **Un coup de pinceau :** il reconstruit 1 à 4 chunks, soit environ +2,5 ms par chunk.
  Ça reste fluide.

Une première version, avec un appel de fonction par face, coûtait 3,5 fois plus. Tout le
calcul des faces se fait maintenant dans une seule boucle à variables locales, et le bruit
n'est calculé qu'une fois par sommet.

Captures avant/après (haut = avant, bas = après) : `results/shading/avant_apres_*.png`.
Les captures d'avant sont archivées dans `results/before_shading/`.

## Détails : touffes d'herbe et rochers (MultiMesh)

Nouveau module `mesh/detail_scatter.gd`. Chaque chunk reçoit deux enfants
`MultiMeshInstance3D`, `_DetailsGrass` et `_DetailsRocks`, construits en même temps que lui.

**Choix pour le mobile :**
- **Meshes minuscules et opaques :**
  - une touffe fait 5 brins, soit 10 triangles (chaque brin dans les deux sens, car un
    matériau double face inverse la normale des faces arrière et les rend noires) ;
  - un rocher fait 12 triangles à facettes ;
  - aucune texture, pas d'alpha, donc pas d'overdraw.
- **Couleurs :** une couleur par instance, prise dans la couleur cuite du sol. Les
  touffes ont la couleur de l'herbe sous elles, un peu plus saturée. Les rochers prennent
  la couleur de côté du style, à moitié désaturée.
- **Ombres :** les détails ne projettent pas d'ombre.
- **Culling :** `visibility_range_end` vaut 70 par défaut. Seuls les chunks proches
  dessinent leurs détails, avec 1 draw call par type et par chunk visible.
- **Placement déterministe :** il dépend d'un hachage des coordonnées globales de
  cellule. La reconstruction d'un chunk ne déplace donc pas les détails des autres.
- **Règles de placement :**
  - l'herbe pousse sur le sol vert et peu pentu (moins de 18 à 34°) ;
  - les rochers préfèrent les pentes et les bords de falaise ;
  - les routes, les lits de rivière et les styles texturés restent dégagés.

Depuis les biomes (section suivante), herbe et rochers sont les deux couches du biome
« Temperate » par défaut. Les réglages par type ont été remplacés par les couches du biome
et un multiplicateur global (Inspecteur > **Biome & Details**).

**Volume sur le 256² :**
- 8 558 touffes et 827 rochers ;
- 91 nœuds MultiMesh ;
- scène `.tscn` de 12,8 → 14,1 Mo, temps de chargement inchangé.

**Coût au rendu (256², A/B alterné dans la même scène, `--details=0` les retire) :**

| Vue | Renderer | Draw calls | Triangles max | GPU (3 paires, sans → avec) |
|---|---|---|---|---|
| Vue d'ensemble (orbite haute) | Mobile | 91 → 91 | identiques | détails cachés par la distance, coût nul |
| Au sol (`--orbit=ground`, pire cas) | Mobile | 31 → 46 | 198 k → 216 k | 5,15→3,86* · 3,78→3,84 · 3,47→3,80 ms |
| Au sol | Compatibility | 70 → 85 | 198 k → 216 k | 4,80→4,65 · 4,62→4,72 · 4,37→4,77 ms |

\* La 1re mesure « sans » est du bruit (machine qui chauffe).

Au sol, le coût réel est d'environ +0,1 à 0,3 ms de GPU et +15 draw calls. On peut le
réduire avec Draw Distance (40 suffit souvent sur téléphone) ou la densité.

**Coût dans l'éditeur :**
- **Par chunk :** environ 1,9 ms (`tools/profile_details.gd`). La première version
  coûtait 6 ms ; je l'ai réduite en rasterisant les routes dans un masque par chunk au lieu
  de tester chaque segment pour chaque cellule.
- **Reconstruction complète du 256² :** environ +0,12 s.

Captures : `results/shading/mobile_128_ground.png` et `mobile_256_ground.png` (vue à
hauteur d'homme, nouvelle vue `ground` du banc), ainsi que
`avant_apres_128_close_details.png` (avant tout ce travail, puis ombrage + détails).

## Biomes : terrains personnalisables sans code (phase 1)

But : faire du plugin une base pour des terrains variés (savane sénégalaise, etc.), réglable
par jeu, sans toucher au code. Tout passe par trois ressources (`.tres`) dans
`addons/lowpoly_terrain_editor/biomes/` :

| Ressource | Rôle |
|---|---|
| `LowpolyTerrainBiome` | regroupe des styles de sol, des valeurs d'ombrage cuit et une liste de couches de détails |
| `LowpolyDetailLayer` | une sorte de détail : mesh (intégré ou le vôtre), densité, règles, forme, couleur, distance |
| `LowpolyGroundStyle` | un sol nommé (couleurs/textures dessus et côté), chargé dans le pinceau en un clic |

**Règles d'une couche :**
- pente min/max avec fondu ;
- plage d'altitude ;
- filtre de sol : tous, verdâtre, proche d'une couleur, ou styles de la palette ;
- éviter routes et rivières, ignorer les styles texturés ;
- bonus sur les pentes et les bords de falaise ;
- **groupement en taches** : taille et couverture, par un bruit de valeur haché ;
- marge dans la cellule.

**Forme d'une instance :** taille min/max avec biais vers les petits, étirement vertical et
horizontal, inclinaison, enfoncement.

**Couleur d'une instance :** sol cuit sous l'instance, couleur de côté du style, ou fixe.
S'y ajoutent teinte, luminosité ± aléa, désaturation et éclaircissement.

**Meshes intégrés :** touffe, rocher, touffe sèche (8 brins), cailloux (3 pierres). Une
couche peut aussi prendre n'importe quel `Mesh`, avec ou sans ses propres matériaux.

**Dans l'éditeur :**
- le sélecteur de biome applique ses valeurs d'ombrage au terrain ;
- **Create Editable Biome** intègre une copie du Tempéré dans la scène ;
- **Re-apply Biome Shading** recopie les valeurs d'ombrage du biome ;
- un bouton par style de sol le charge dans le pinceau ;
- trois multiplicateurs globaux : densité, taille, distance d'affichage.

Modifier une couche dans l'Inspecteur redisperse les détails 250 ms après la dernière
modification, sans reconstruire les meshes du terrain. Ça marche aussi pendant que le biome
est ouvert dans l'Inspecteur. Sans biome, le terrain utilise le **Tempéré** intégré (aussi
fourni en `presets/temperate.tres`), qui reproduit l'herbe et les rochers d'avant.

**Coût :**
- **Rendu :** identique à avant, soit 1 MultiMesh par couche et par chunk visible.
  A/B Mobile au sol sur le 256² : 31 → 46 draw calls, GPU 3,78/3,56 → 3,91/3,93 ms.
  C'est le même écart qu'avec l'ancien module.
- **Éditeur :** environ 1,7 ms par chunk pour les 2 couches du Tempéré, contre 1,9 ms
  avec l'ancien code figé. Ce chiffre tient compte des optimisations de la phase 2 (voir
  plus bas).
- **Volume :** 8 634 touffes et 836 rochers sur le 256², contre 8 558 et 827 avant.
  La position des instances change (nouveau tirage par couche), pas leur nombre.

**Vérifications :**
- `tools/check_biomes.gd` (14 contrôles, 24 depuis la phase 2) :
  - déterminisme ;
  - multiplicateur de densité (×0,5 → 0,50) ;
  - remplacement des couches et nettoyage des anciens nœuds ;
  - groupement ;
  - couleur fixe ;
  - filtres de pente et de styles ;
  - `changed` propagé ;
  - désactivation ;
  - biome intégré sauvé puis rechargé avec la scène ;
  - preset.
- **Test de fumée en éditeur :** 26/26. Il couvre création du biome, édition en direct,
  bouton de style de sol, `set_biome` et désactivation.
- **Non-régression :** `check_optimizations`, `check_shading_seams` et
  `compare_chunks --zero` restent OK.

**Migration :** les anciennes clés `_lte_detail_grass_density` et `_lte_detail_rock_density`
sont supprimées à l'ouverture du terrain et remplacées par `_lte_detail_density`
(multiplicateur, 1,0 par défaut).

Captures : `results/biomes/temperate_mobile_256_ground.png` et
`avant_apres_biome_ground.png` (ancien module en haut, biome Tempéré en bas).

## Savane sénégalaise (phase 2)

Nouveau preset `biomes/presets/senegal_savanna.tres` (code : `TerrainBiome.make_senegal_savanna()`).
Il représente la savane sahélo-soudanienne en saison sèche.

**Sols (6 styles, boutons de pinceau) :**

| Style | Rôle |
|---|---|
| Dry Grass | paille, sol de base |
| Laterite | terre rouge, plateaux et plaques |
| Green Savanna | creux plus humides |
| Sand | sable |
| Dry Clay | argile sèche, prévue pour les mares asséchées de la phase 3 |
| Burnt Ground | brûlis |

**Couches (9) :**

| Couche | Mesh | Règles principales |
|---|---|---|
| Dry Grass | touffe sèche, 8 brins | en taches, sur le sol paille, distance 50 |
| Green Grass | touffe | sur la savane verte, distance 50 |
| Laterite Gravel | cailloux | sur la latérite, couleur du sol assombrie, distance 50 |
| Rocks | rocher | pentes et bords de falaise |
| Shrubs | **arbuste** (nouveau) | en taches, distance 120 |
| Acacias | **acacia en parasol** (nouveau) | 3,5 à 6 m, en bosquets, ombres, distance 300 |
| Baobabs | **baobab de saison sèche** (nouveau) | 5 à 7,5 m, isolés, ombres, distance 400 |
| Termite Mounds | **termitière cathédrale** (nouveau) | teinte latérite, en groupes, distance 160 |
| Zebu Skulls | **crâne de zébu**, cornes en lyre (nouveau) | rares, inclinés, distance 45 |

**Les nouveaux meshes :**
- ils étaient générés par code dans `mesh/detail_meshes.gd` (`ShapeBuilder` : segments à
  facettes et blobs bosselés, faces orientées vers l'extérieur). Ils sont depuis
  modélisés dans Blender, voir « Éléments du décor refaits dans Blender » ;
- ils font de 100 à 400 triangles ;
- ils portent leurs propres couleurs (écorce, feuilles, os) et s'utilisent en couleur
  `FIXED` ; la termitière est grise et prend la teinte de la couche ;
- planche de prévisualisation : `tools/preview_props.gd` → `results/biomes/props.png`.

**Scène de démonstration :** `tools/build_savanna.gd` produit `scenes/savanna_128.tscn` et
`savanna_256.tscn`. On y trouve :
- une plaine d'herbe sèche ;
- des plateaux de latérite surélevés et des plaques plates de latérite ;
- des creux plus verts et des zones brûlées ;
- une piste rouge.

Captures : `results/biomes/savanna_256_hero.png`, `savanna_256_ground.png` et
`savanna_256_ground_close.png`.

**Volume sur le 256² :**
- environ 49 000 instances : 38 000 touffes sèches, 5 000 touffes vertes, 3 100 cailloux,
  1 300 rochers, 1 000 arbustes, 200 acacias, 117 termitières, 47 baobabs et 78 crânes ;
- 505 nœuds MultiMesh ;
- `.tscn` de 27,6 Mo, parce que les buffers d'instances sont enregistrés dans la scène.

**Coût au rendu (256², A/B alterné, `--details=0`) :**

| Vue | Renderer | Draw calls | Triangles max | GPU (sans → avec) | CPU rendu |
|---|---|---|---|---|---|
| Vue d'ensemble | Mobile | 120 → 276 | 273 k → 369 k | 4,14→4,31 · 3,92→3,97 ms | 0,6 → 0,9 ms |
| Au sol (pire cas) | Mobile | 42 → 130 | 196 k → 337 k | 3,80→4,99 · 4,06→4,40 ms | 0,5 → 0,8 ms |
| Au sol | Compatibility | 83 → 221 | 196 k → 337 k | 4,28→5,74 ms | 2,9 → 4,7 ms |

Une savane dense coûte nettement plus que le Tempéré : environ +0,4 à 1,2 ms de GPU au sol
sur Iris Xe, et +90 à 150 draw calls. Le renderer Compatibility est le plus sensible, car
il paie chaque draw call sur le CPU (+1,5 ms). Les arbres comptent double : visibles de
loin, et dessinés une seconde fois dans la passe d'ombre.

**Leviers pour un téléphone d'entrée de gamme :**
- **Density Multiplier** à 0,5 : divise par deux les touffes, le gros des triangles ;
- **Cast Shadows** décoché sur Acacias et Baobabs : supprime leur passe d'ombre ;
- distance d'affichage des arbres réduite de 300–400 à environ 150.

Pendant ces mesures, un lancement Compatibility s'est terminé par un segfault à la
fermeture, après l'écriture des résultats. Il ne s'est pas reproduit sur 8 relances ; il
n'est pas attribué au plugin.

**Optimisation du placement (constatée sur la savane) :** la première version prenait
29 ms par chunk, soit 1,9 s pour le 256². Elle est descendue à 11,6 ms par chunk
(0,74 s), et le Tempéré à 1,7 ms par chunk :
1. **Bruit de groupement :** il était recalculé en GDScript, avec 8 hachages par cellule
   et par couche. C'est maintenant un `FastNoiseLite` natif.
2. **Ordre des tests :** le tirage aléatoire de la cellule se fait avant les règles. Une
   couche clairsemée (arbres, termitières) écarte ainsi la plupart des cellules avant de
   lire la pente, la couleur ou le bruit.
3. **Boucle par instance en ligne :** un seul hachage 64 bits, remixé pour obtenir plus de
   bits, et aucun appel de fonction GDScript.

**Scène de 27,6 Mo :** un `.scn` binaire est bien plus petit. Mieux encore, on peut
régénérer les détails au chargement au lieu de les enregistrer, puisque le placement est
déterministe. C'est prévu en phase 4 (génération à l'exécution).

## Mares asséchées (phase 3)

**Outil Waterhole** (barre d'outils 3D) : un clic pose une mare asséchée de la taille du
pinceau (*Size*). Pour l'effacer, cliquer dedans avec *Erase*. Undo/Redo et l'export JSON
du niveau sont pris en charge. Réglages : Inspector > *Terrain Features* > *Dried
Waterholes* (profondeur, part du fond plat, irrégularité du contour, largeur et bourrelet
du bord, taille des plaques, largeur des fissures, relèvement des bords, couleurs d'argile
et de fissure). Le bouton *Apply to Existing Waterholes* applique les réglages aux mares
déjà posées.

**Non destructif :** une mare n'est qu'une petite donnée (`_lte_waterholes` : centre,
rayon, graine, style). Les hauteurs et les styles de cellule ne sont pas touchés. Tout le
reste en est dérivé, comme le lit des rivières :

| Effet | Où |
|---|---|
| Cuvette + bourrelet de terre autour | creusement par sommet (`WaterholeMesher.add_carve`, même tableau que les rivières) |
| Argile sur la berge, couleur sombre de fissure au fond, fondu sur le bord | couleurs cuites par `TerrainShading` (zéro coût au rendu) |
| Plaques de boue craquelée | `WaterholeMesher.build` : 1 mesh opaque par mare, matériau partagé du terrain, sans ombre portée |
| Zones *bassin* / *bord* | `DetailScatter`, nouveau réglage de couche *Waterhole Zone* |

Effacer une mare redonne exactement le terrain d'avant, au sommet près (vérifié).

**Les plaques :** ce sont les cellules d'un diagramme de Voronoï à grille perturbée.
Chaque bord est rentré d'une demi-fissure, avec une largeur qui varie d'un bord à l'autre
(fissures fines à côté de fissures larges). Environ 45 % des plaques sont recoupées par
une fissure secondaire plus fine, ce qui donne des formes et des tailles irrégulières.
Chaque plaque a les bords relevés (*curl*), une légère inclinaison aléatoire et une
couleur propre (certaines blanchies par le soleil). Une jupe latérale descend dans le sol.
Le contour de la mare est irrégulier : trois harmoniques tirées de la graine.

**Zones pour les couches de détails** (`LowpolyDetailLayer.waterhole_zone`) :
- *Outside Basin* (par défaut) : partout sauf dans les cuvettes. Herbe, rochers et arbres
  ne poussent donc plus dans les mares.
- *Rim Only* : seulement sur le bord.
- *Basin Only* : seulement sur la boue craquelée.
- *Away* : ni sur le bord, ni dans la cuvette.
- *Anywhere* : partout.

Le preset Savane gagne 4 couches, toutes vides tant qu'il n'y a pas de mare (donc sans
coût) :
- roseaux secs ;
- crânes de zébu sur le bord ;
- **arbres morts** (nouveau mesh, 98 triangles) ;
- quelques os dans la cuvette.

Les biomes ont aussi un groupe *Waterholes* (couleurs d'argile et de fissure). Ces
couleurs sont copiées dans les réglages du terrain quand on applique le biome.

**Coût** (mesuré) :

| Mesure | Valeur |
|---|---|
| Plaques, rayon 6 / 12 / 24 | 1 431 / 6 075 / 25 317 triangles, construits en 7 / 32 / 140 ms |
| Pose d'une mare dans l'éditeur (creusement + chunks touchés + plaques) | ~75 ms |
| Creusement avec 20 mares | 13 ms |
| Savane 256² démo (6 mares) | 11 838 triangles de plaques, +9 draw calls (276 → 285) en vue d'ensemble, +6 à 7 au sol |

GPU au rendu, Mobile, A/B en alternance (`bench.gd --waterholes=0`, Iris Xe) :

| Vue | Sans mares | Avec mares |
|---|---|---|
| Vue d'ensemble | 3,83 · 4,26 ms | 5,04 · 3,79 ms |
| Au sol | 4,36 · 4,37 ms | 4,12 · 4,50 ms |

L'écart reste dans le bruit de la machine. Le coût réel tient en environ 3 % de triangles
en plus et 1 draw call par mare visible.

Le nombre de triangles croît avec (rayon / taille de plaque)². Pour une très grande mare
sur mobile, augmenter *Plate Size* (par exemple 1,5 au lieu de 0,9 divise les triangles
par environ 2,8).

Captures : `results/waterholes/waterhole_0_oblique.png`, `_ground.png`, `_close.png`,
`_top.png`. Planche des meshes avec l'arbre mort : `results/biomes/props.png`.

Contrôles : `tools/check_waterholes.gd` (28 contrôles). Il vérifie notamment :
- les hauteurs restent intactes et la profondeur au centre est la bonne ;
- toutes les faces des plaques sont orientées correctement et aucun sommet ne passe sous
  le sol ;
- les plaques restent dans la cuvette et leur génération est déterministe ;
- les couleurs ne dépendent pas de la région construite (pas de couture) ;
- chaque couche respecte sa zone ;
- *Apply*, l'export JSON, la gomme (terrain identique après effacement) et l'Undo
  fonctionnent.

Le test éditeur passe à 33 étapes (outil, clic, Undo/Redo, gomme).
`compare_chunks` sur la savane 256 donne IDENTICAL après rechargement de la scène :
centre et rayon sont arrondis au millième pour survivre à la sauvegarde texte.

## Outils de jeu : cartes générées, runtime, collision des arbres (phase 4)

**Générer une carte entière.** Inspector > *Map Generator & Runtime* : choisir une recette
(`LowpolyMapRecipe`) et une graine, puis cliquer *Generate Map*. L'Undo restaure le terrain
d'avant. La recette décrit la carte ; la graine choisit la variante. Même recette + même
graine = même carte, dans l'éditeur comme en jeu. Une recette règle :
- la taille, la taille de cellule et le contour (carré ou île irrégulière) ;
- le relief doux ;
- les plateaux : style, part de la carte, hauteur, taille, pente des bords ;
- les bas-fonds : mêmes réglages ;
- les taches de sol : style, part, taille, style sur lequel elles se posent ;
- les pistes : nombre, largeur, couleur, sinuosité ;
- les mares asséchées : nombre pour 10 000 cellules, rayon min / max ;
- la collision du sol (activée par défaut).

Presets :
- `generation/presets/senegal_savanna_map.tres` : 192², plateaux de latérite, bas-fonds
  verts, taches brûlées, sableuses et de latérite, 2 pistes rouges, mares ;
- `temperate_island_map.tres` : île 128².

La recette fait référence à un biome. Ses styles se désignent par leur nom (« Laterite »).
La carte reste éditable à la main ensuite.

La part demandée est tenue quelle que soit la graine (seuil par percentile) :
- plateaux : 11,5 % pour 12 % demandés ;
- bas-fonds : 10,4 % pour 12 %.

Les mares sont posées sur du plat, hors plateau, loin des pistes et des autres mares.

**Graine des détails** (`_lte_detail_seed`, *Detail Seed*) : même sol, autre placement des
arbres, herbes et objets. *Generate Map* la règle sur la graine de la carte. À 0, le
placement ne change pas : `compare_chunks` reste IDENTICAL sur toutes les scènes.

**Collision des arbres.** Les couches de détails ont un nouveau groupe *Collision* :
- `collision_radius` : rayon, en part de la largeur du mesh (0 = pas de collision) ;
- `collision_height` : hauteur, en part de la hauteur du mesh.

Réglages de la savane, calés sur le rayon réel des troncs :

| Couche | `collision_radius` |
|---|---|
| Acacias | 0,045 |
| Baobabs | 0,22 |
| Termitières | 0,4 |
| Arbres morts | 0,065 |

Herbes, rochers et buissons restent traversables.

Chaque instance reçoit un cylindre, lu dans le MultiMesh, donc exactement là où l'arbre est
dessiné. Il n'y a pas un nœud par arbre :
- 1 StaticBody3D par chunk ;
- des *shape owners* au lieu de nœuds ;
- des formes partagées (rayon arrondi à 5 cm, hauteur à 25 cm).

Ces cylindres sont construits en jeu seulement et jamais sauvegardés.

| Mesure (savane 192², graine 42) | Valeur |
|---|---|
| Cylindres | 186 (acacias, baobabs, termitières, arbres morts) pour 70 formes partagées |
| Temps de construction | 1,8 ms |
| Test de marche (`demo/runtime_demo.tscn -- --walk-test`) | capsule de 0,35 m arrêtée à 1,95 m du centre d'un baobab de rayon 1,6 m : BLOCKED |

**Nœud runtime `LowpolyTerrainRuntime`.** Le plugin ajoute un enfant
`_LowpolyTerrainRuntime` au terrain dès qu'il est utile : une couche a une collision, ou un
mode runtime est choisi. Au lancement du jeu, ce nœud construit ce que la scène ne contient
pas :
- une nouvelle carte depuis sa recette, si *Generate Map* est coché (graine fixe,
  aléatoire, ou `build(seed)` depuis le code) ;
- les détails ou les meshes non sauvegardés ;
- la collision des arbres.

Le travail est découpé en petits pas : 1 chunk, 1 mare, ou 1 forme de collision du sol par
chunk. Les pas s'exécutent dans un budget par frame (`frame_budget_ms`, 6 ms par défaut),
chunks les plus proches de la caméra d'abord.

Signaux :
- `terrain_ready` : le sol et sa collision sont prêts, on peut faire apparaître le joueur ;
- `progress(done, total)` : pour un écran de chargement ;
- `finished(stats)` : `worst_step_ms` y donne la durée du pas le plus long.

**Ce que la scène sauvegarde** (réglage *Runtime Build*, mesures sur PC avec un budget de
4 ms) :

| Mode | `.tscn` savane 192² | Construction au chargement |
|---|---|---|
| Tout sauvegarder (défaut) | 19,5 Mo | collision des arbres seulement |
| Détails au runtime | 14,9 Mo | 633 ms sur 36 frames, pire frame 34 ms |
| Tout au runtime | 2,1 Mo | 1,65 s sur 93 frames, pire frame 85 ms (mesh des pistes) |
| Carte générée en jeu (`demo/runtime_demo.tscn`) | — | génération 105 ms, puis construction ≈ 2,2 s, pire pas ~100 ms |

Les tailles de scène incluent la collision concave du sol, que les recettes activent.

Sur mobile, compter 3 à 4 fois ces temps. Afficher un écran de chargement jusqu'à
`finished`, ou au moins jusqu'à `terrain_ready`. Le pas le plus long restant est le mesh des
routes et rivières : ~85 ms, en un seul bloc. La première frame rendue compile aussi les
shaders : ~300 ms dans la démo.

**Rendu d'une carte générée** (Mobile, Iris Xe) : `scenes/savanna_map_192.tscn` comparée à
la savane 256² faite à la main.

| Vue | Carte 192² générée | Savane 256² |
|---|---|---|
| Vue d'ensemble | 210 draw calls, 3,67 ms GPU | 285 draw calls, 4,55 ms GPU |
| Au sol | 96 draw calls, 4,37 ms GPU | 136 draw calls, 3,99 ms GPU |

Le coût est du même ordre : une carte générée n'est pas plus lourde qu'une carte peinte.

Dans l'éditeur, une carte 192² se génère en 105 ms. La construction complète prend ensuite
~1,4 à 1,9 s (36 chunks, avec détails et plaques des mares).

Captures :
- `results/runtime/runtime_demo_overview.png` : carte de graine 2026 ;
- `results/runtime/runtime_demo_baobab.png` : joueur bloqué par un baobab.

Contrôles :
- `tools/check_maps.gd` vérifie :
  - le déterminisme, la couverture et le contour d'île ;
  - la graine des détails ;
  - la collision : un cylindre par arbre, un rayon qui touche le tronc, rien dans le vide ;
  - la taille de scène des 3 modes ;
  - la construction progressive en jeu : `terrain_ready` arrive avant `finished`, et un
    rayon vertical touche le sol ;
  - qu'une carte générée en jeu est identique à celle de l'éditeur pour la même graine ;
  - `build(seed)`.
- Le test éditeur compte 41 étapes : section Inspector, *Generate Map*, ajout du nœud
  runtime, propriétaires des nœuds selon le mode, Undo.

## Polish du rendu de la savane

Captures avant / après : `results/polish/before_*.png`, `final_*.png` et
`compare_*.png` (avant en haut, après en bas), carte `scenes/savanna_map_192.tscn`
(graine 2026), renderer Mobile, 1280x720.

**Défauts de départ :**
- troncs presque noirs et bleutés ;
- baobabs gris ardoise ;
- canopées d'acacia vert vif, dessous très sombre ;
- ombres bleues partout ;
- bords de pistes en escalier ;
- zones brûlées en taches grises floues.

**Cause principale :** l'ambiance venait surtout du ciel bleu du banc (lumière ambiante
100 % ciel), pas des couleurs des meshes. Changer seulement les couleurs ne se voyait
presque pas.

**Corrections :**
- **Éclairage recommandé par biome** (groupe *Lighting* de `LowpolyTerrainBiome`) :
  `environment`, `sun_color`, `sun_energy`, `sun_elevation`. La savane a un ciel pâle et
  brumeux, une ambiance chaude (45 % ciel), un léger voile de poussière (fog 0,0012),
  le tonemap AgX et le soleil à 46°. Le bouton **Apply Biome Lighting** (section Biome)
  le pose sur la scène : il crée `BiomeEnvironment` et `BiomeSun` s'ils manquent. Il est
  annulable. Coût mobile : pas de SSAO, glow ni SSR (fog et ajustement seulement).
  *(Remplacé depuis : voir « Lumière façon jeux low poly » plus bas.)*
- **Couleurs des props** (`detail_meshes.gd`) : écorce et baobab plus chauds et plus
  clairs, feuillage olive moins saturé.
- **Carte générée** : les pentes des plateaux et des bas-fonds prennent le style du
  plateau ou du bas-fond dès 30 % de la hauteur (`SLOPE_STYLE_SHARE`). Les zones brûlées
  sont plus rares et plus grandes (0,035 / 26).
- **Pistes sans escalier** (`road_mesher.gd`) : une distance signée au bord de la route est
  calculée aux coins de la grille fine. Les quads entièrement dans la route restent
  entiers. Les quads coupés par le bord sont découpés le long du bord (marching
  squares). Chaque point de bord est calculé depuis le coin bas de son arête, donc deux
  quads voisins ont exactement le même point (pas de fissure).

**Coût des pistes** (`profile_features.gd`, terrain_256, 8 218 cellules, médiane de 4
passes alternées) :

| Version | Surface des routes | Triangles des routes |
|---|---|---|
| Ancienne (escalier) | ~108 ms | 16 436 |
| Marching squares, 1re version (dictionnaires) | ~177 ms | 17 504 |
| Marching squares, grille dense (finale) | ~100 ms | 17 504 |

La version finale stocke le champ de distance, les hauteurs des coins et la liste des
cellules dans des tableaux packés au lieu de dictionnaires. Elle est un peu plus rapide
que l'ancienne pour +6,5 % de triangles. Le plus long pas du runtime (mesh des routes)
reste à ~90 ms. Sur la carte 192, il y a 14 207 triangles contre 13 446 avant.

**Vérifications :**
- `compare_chunks` : IDENTICAL sur terrain_256, terrain_256_flat `--zero` et
  savanna_256 (le terrain ne change pas).
- `compare_feature_mesh` : DIFFERENT, c'est voulu (nouveau bord de piste). Pour s'en
  resservir comme test de non-régression, il faut ressauver les scènes de référence avec
  `build_terrains.gd`.
- `check_maps`, `check_biomes`, `check_waterholes` : OK. `check_shading_seams` :
  CONSISTENT.
- Le test éditeur compte maintenant 44 étapes (bouton, application et Undo de
  l'éclairage de biome). Toutes passent.
- Coût GPU de l'éclairage de biome sur le banc : non mesuré (le banc garde sa propre
  lumière pour rester comparable).

## Test dans l'éditeur (fenêtre réelle)

Parcours d'un utilisateur dans l'éditeur Godot (Forward+, Iris Xe) : *New Terrain*, recette
savane, graine 2026, *Generate Map*, *Apply Biome Lighting*, gros plans, sauvegarde,
réouverture.

- *Generate Map* : 2,0 à 2,4 s (génération + construction + Undo), sans erreur.
- L'éclairage de biome s'affiche dans la vue 3D de l'éditeur. La mare craquelée, les pistes
  et les props ont le même rendu que dans les captures du jeu.
- **Corrigé :** juste après *Generate Map*, le bouton *Apply Biome Lighting* n'était que
  dans la section *Biome & Details*, repliée par défaut. On voyait donc la carte avec la
  lumière d'aperçu de l'éditeur sans trouver le bouton. Il est maintenant aussi dans la
  section *Map Generator & Runtime*, sous *Generate Map*.
- **Taille de la scène :** la carte 192 en mode *Save everything* fait 20 Mo en `.tscn`.
  La sauvegarde prend 1,9 s et la réouverture ~5 s dans l'éditeur (2,5 s de chargement
  seul). En `.scn` (binaire compressé), la même scène fait **4 Mo** et se charge en
  **0,2 s**. Une astuce dans l'Inspector le rappelle.

**Inspector bloqué à moitié hors de l'écran (corrigé)** : la barre d'outils du plugin
dans le menu 3D était une seule rangée de 1 307 px de large minimum. Le menu 3D de Godot
ne pouvait donc pas descendre sous ~1 315 px. Sur un écran 1080p à 125 %, il ne restait pas
assez de place : le dock Inspector débordait de la fenêtre et ne se redimensionnait plus.
La barre passe maintenant à la ligne (`HFlowContainer`, 700 px minimum). Le menu 3D revient
au minimum de Godot (709 px). En 1920 px la barre tient sur une ligne, en plus étroit elle
passe sur deux.

**Avertissement « MeshInstance3D requires a Mesh » (corrigé)** : après le tracé d'une
route ou d'une rivière, le nœud d'aperçu `_GeneratedTerrainFeaturePreview` restait dans la
scène, vide, et il était sauvegardé. L'aperçu n'est plus possédé par la scène (donc plus
sauvegardé) et il est supprimé à la fin du tracé. Les scènes qui en contiennent un sont
nettoyées à la sélection du terrain. Un relevé sans fenêtre, après création, peinture,
gomme, route, *Generate Map* et éclairage, ne trouve plus aucun nœud vide.

**Doublons d'UID au démarrage (corrigé)** : `results/` contenait des captures copiées
d'un dossier à l'autre avec leurs `.import`, donc avec le même UID. `results/` a maintenant
un `.gdignore` : Godot n'importe plus ces sorties de test, que les outils lisent
directement sur le disque.

**Largeur minimale de l'Inspector** : le panneau du plugin exigeait 368 px, contre 146 px
pour l'Inspector de Godot seul. Godot ne raccourcit jamais un texte par défaut, donc les
libellés, cases à cocher et boutons longs gardaient toute leur largeur. Le menu *Runtime
Build* prenait aussi la largeur de son choix le plus long. Maintenant les textes se
coupent avec « … », le texte complet reste en infobulle, et les champs numériques font
90 px. Le panneau descend à **184 px**, et à 216 px avec toutes les sous-sections
ouvertes.

**Barre d'outils en icônes + anneau de pinceau** : les 13 boutons texte sont devenus des
icônes (SVG intégrés, à l'échelle de l'éditeur, clairs ou sombres selon le thème), avec
le nom en infobulle. La barre reste sur une seule ligne, sous celle de Godot dans le menu 3D. Elle ne se
replie plus en plusieurs rangées. Elle fait ~750 px à l'échelle 100 % (935 px à 125 %)
contre 1 307 px avec le texte. Le statut prend la place libre au bout de la ligne. Au survol de la vue 3D, un anneau posé sur le sol suit la souris : couleur
et symbole par outil, anneau intérieur à mi-rayon (50 % de force), largeur de la piste
ou de la rivière, mare avec ses fissures, orange quand la gomme est sur une route ou une
rivière. `[` et `]` changent la taille du pinceau. Le point visé tombe maintenant sur le
relief sous le curseur (rayon contre la grille de hauteurs) et plus sur le plan zéro du
terrain : sur un plateau ou dans une vallée, le pinceau était décalé de plusieurs mètres.
Le dessin passe par `_forward_3d_draw_over_viewport` : rien n'est ajouté à la scène.

**Erreurs « No path can be resolved » sur Apply Biome Lighting (corrigé)** : les réglages
du nouveau WorldEnvironment / DirectionalLight3D étaient enregistrés dans l'historique
avant que le nœud soit dans l'arbre. Ils sont maintenant posés avant l'ajout.

## Fluidité de l'édition (gomme, pinceaux, Undo)

Banc d'essai dans l'éditeur (sans fenêtre) : carte savane 192 m, traits passés par le
vrai chemin d'entrée du plugin (`_forward_3d_gui_input`). Les chronos varient d'environ ×1,5
d'un lancement à l'autre (PC partagé) ; les ordres de grandeur sont stables.

| Action | Avant | Après |
|---|---|---|
| Gomme r3, par mouvement de souris | 71 ms | 15–25 ms |
| Gomme r6, par mouvement | 165 ms | 17–42 ms |
| Raise / Paint r3, par mouvement | 67–84 ms | 14–30 ms |
| Gomme sur une route, par mouvement | ~2 s (`rebuild_all`) | 45–60 ms |
| Fin d'un trait de pinceau | 240–330 ms | quelques ms, puis ~10 ms par image pendant 2 à 6 images |
| Undo / Redo d'un trait | 1,8–2,2 s | 0,1–0,2 s, puis la zone se termine en quelques images |
| Re-sélection du terrain | ~2 s | < 1 ms (s'il est déjà construit) |
| Maillage des 36 chunks | 1 369 ms | 526–745 ms (résultat identique au bit près) |

Causes et corrections :
- **Gomme sur route ou rivière** : chaque mouvement reconstruisait tout le terrain. Maintenant,
  seules les données changent ; le maillage des routes est refait une fois par image, et le
  sol et les détails de la zone effacée le sont à la fin du trait.
- **Pinceaux** : chaque mouvement reconstruisait les chunks touchés *avec* leur herbe et leurs
  arbres, plus les chunks voisins atteints par le flou des couleurs. Maintenant, un mouvement
  ne fait que modifier les données. Les maillages des chunks sous le pinceau sont refaits une
  fois par image, sans détails. Les détails et les voisins sont refaits après le trait,
  ~10 ms par image.
- **Collision de toute la carte** (~150 ms) : elle était refaite à chaque fin de trait.
  Maintenant, elle l'est après ~1,2 s de pause, et toujours avant une sauvegarde ou un
  lancement du jeu (`_apply_changes`).
- **Undo** : il reconstruisait tout. Maintenant, il ne refait que la zone du trait (ou toute
  la carte si la grille a changé de taille). Le smoke test vérifie que le résultat est
  identique au bit près, herbe et arbres compris.
- **Test « le trait touche une route »** : il utilisait le rectangle englobant de toute la
  route, donc répondait presque toujours oui. Le test se fait maintenant segment par segment.
- **Mailleur** : les métadonnées sont lues hors de la boucle, chaque sommet est calculé une
  fois au lieu de 4, et les voisins (falaises) sont pré-calculés. Il est 2,2× plus rapide et
  son empreinte SHA-256 est identique. Ça accélère aussi la génération et l'ouverture des
  scènes.
- **Traits rapides** : des tampons intermédiaires (tous les 0,35 × rayon) remplissent les
  trous entre deux positions de souris éloignées.

Compromis : pendant un trait, l'herbe et les arbres des chunks touchés gardent leur ancienne
place. Ils se mettent à jour juste après le relâchement.

Ergonomie (audit UI / UX, détails dans `AUDIT_UX.md`) :
- Ctrl inverse l'outil, Shift lisse ;
- `[` `]` règlent la taille (la largeur avec Route / Rivière), `-` `=` règlent la force ;
- Échap quitte l'outil ;
- Alt et les boutons droit / milieu restent à la caméra ;
- un clic dans le ciel ne désélectionne plus le terrain.

## Taille des scènes : données du terrain compressées

Godot affichait souvent « The text-based scene … is large on disk ». Dans un `.tscn`,
les hauteurs, le masque et les styles de cases étaient écrits nombre par nombre en
texte.

Maintenant :
- à l'enregistrement, ces tableaux sont compressés en un seul bloc Zstandard ;
- au chargement, ils sont décompressés avant toute lecture ;
- en mémoire, rien ne change pour le reste de l'addon.

Le nœud `_LowpolyTerrainRuntime` s'en charge. Il est désormais ajouté à chaque terrain
de la scène. Les scènes au format précédent s'ouvrent toujours telles quelles.

| Scène | Données du terrain avant | Après |
|---|---|---|
| `bench.tscn` (terrains 256 + 128) | 936 Ko | 22 Ko |
| Carte de savane générée (193) | ~1 Mo | 3 Ko |

L'enregistrement prend quelques millisecondes de plus, et le chargement aussi. Le smoke
test vérifie trois choses :
- le fichier contient le bloc compressé ;
- les tableaux sont rétablis en mémoire après l'enregistrement ;
- une scène rechargée retrouve exactement les mêmes données.

Sur une carte générée, l'essentiel du `.tscn` venait ensuite des éléments générés
enregistrés : maillages 9,6 Mo, collision 5,4 Mo, détails 4,3 Mo, routes 1,6 Mo.
C'est pourquoi **les nouveaux terrains sont maintenant en « Everything at runtime » par
défaut** : la scène ne garde que les données.

| Carte de savane 193 × 193 | Taille du `.tscn` |
|---|---|
| Save everything | 19 Mo |
| Everything at runtime (nouveau défaut) | 160 Ko |

Ce que ça coûte :
- **Ouverture dans l'éditeur** : le nœud runtime reconstruit le terrain. L'addon ne le
  reconstruit pas une deuxième fois quand on le sélectionne (vérifié par le smoke test).
- **En jeu** : le terrain se reconstruit de façon progressive, environ 1,6 s pour cette
  carte en headless. Le signal `terrain_ready` indique quand le sol et sa collision
  sont prêts.

Les terrains créés avant gardent « Save everything » ; on peut le changer dans
l'Inspector, section Map Generator / Runtime > Runtime Build. Le smoke test vérifie
aussi qu'une scène chargée comme en jeu, hors éditeur, retrouve tout : 36 chunks,
détails et routes.

## Sol lisse : plus de motif de triangles

Chaque triangle du sol avait sa propre couleur (variation, ombrage et pente calculés au
centre du triangle) et sa propre normale. On voyait donc un quadrillage de triangles,
même sur le plat.

Avec **Smooth Ground**, activé par défaut (Inspector > Rendering) :
- la couleur cuite et la normale sont calculées par sommet ;
- les triangles qui se touchent partagent ces valeurs, et le GPU les fond ensemble.

Les falaises, routes et rivières gardent leurs facettes. Pour revenir au rendu à
facettes, il suffit de décocher l'option.

| | Facettes | Smooth Ground |
|---|---|---|
| Sommets / triangles | identiques | identiques |
| Coût GPU | — | identique (aucun shader en plus) |
| Construction, 36 chunks (savane 193) | 530 ms | 482 ms |

La construction est même un peu plus rapide : on calcule une couleur par sommet (33 × 33
par chunk) au lieu d'une par triangle (2 × 32 × 32). La normale d'un sommet n'utilise
que les arêtes de cases actives, pour qu'un bord de falaise ne penche pas vers le vide.
Le smoke test passe 74 vérifications sur 74, dont les Undo identiques au bit près.

## Éléments du décor refaits dans Blender

Les accessoires dispersés par le biome sont maintenant modélisés dans Blender (via le
MCP Blender), à partir de photos de référence de la savane sénégalaise :
- **Acacia parasol** (*Vachellia tortilis*) : tronc fin, branches fourchues, canopée
  plate en plusieurs plateaux.
- **Baobab** en saison sèche : tronc en bouteille, branches nues étalées comme des
  racines, fruits (pain de singe) suspendus.
- **Termitière** (*Macrotermes*) : flèche principale côtelée, deux flèches secondaires.
- **Crâne de zébu Gobra** : orbites saillantes, cornes en lyre.
- **Arbre mort** : tronc tordu, racines, moignon cassé.
- **Buisson** sahélien, **rocher** facetté, **latérite**, **touffes d'herbe**.

Le modèle Blender est reproductible :
- `tools/blender/lte_props.py` reconstruit chaque élément par code ;
- `tools/blender/glb_to_gdscript.py` convertit l'export GLB en
  `mesh/detail_mesh_data.gd`, de simples tableaux de sommets, triangles et palette.

Le rendu ne change pas : facettes plates, couleurs par sommet, assombries près du sol.
Aucune texture et aucun matériau en plus.

| Triangles par instance | Avant | Après |
|---|---|---|
| Herbe sèche (×22 650) | 16 | 14 |
| Herbe verte (×4 400) | 10 | 12 |
| Latérite (×1 200) | 36 | 48 |
| Rocher (×820) | 12 | 40 |
| Buisson (×460) | 104 | 98 |
| Acacia (×86) | 170 | 249 |
| Baobab (×37) | 406 | 411 |
| Termitière (×49) | 205 | 260 |
| Crâne (×47) | 158 | 236 |
| Arbre mort (×2) | 98 | 212 |
| **Total, carte de savane 193** | **≈ 555 000** | **≈ 567 000 (+2 %)** |

Les herbes restent à un triangle par brin, car ce sont elles qui comptent : 27 000
touffes sur la carte. Le détail en plus va aux accessoires, qui sont peu nombreux.
Chaque maillage se construit en moins de 2 ms, une seule fois, puis reste en cache. Les
rayons de collision des arbres et des termitières restent valables (tronc ≈ rayon ×
largeur du maillage). Le smoke test passe 74 vérifications sur 74.

Correction des fourches : sur l'acacia et l'arbre mort, le tronc s'arrêtait ouvert pile à
la fourche, et les branches partaient de ce plan avec moins de côtés. On voyait le ciel
à travers la jonction, comme si la couronne flottait. Maintenant, le tronc dépasse un peu
la fourche et se ferme en nœud, et chaque branche part de l'intérieur du tronc. Cela
ajoute 15 triangles par arbre. Captures : `results/forks/`.

## Explorer la carte en vue FPS

`explore/explore.tscn` (ouvrir puis F6) : la savane (recette `senegal_savanna_map.tres`, graine 2026) est générée au lancement par `LowpolyTerrainRuntime`. Un joueur capsule en vue à la première personne (`player/fps_player.tscn`, classe `FpsPlayer`) est posé au centre dès que la collision du sol existe (`terrain_ready`).

Commandes : souris pour regarder (clic pour capturer, Échap pour libérer), ZQSD / WASD / flèches (touches physiques, donc AZERTY et QWERTY), Maj pour courir, Espace pour sauter, V pour voler (Espace monte, C ou Ctrl descend), R pour une nouvelle carte aléatoire. Les arbres et les termitières bloquent le joueur ; l'herbe ne le bloque pas. La capsule est sur le calque 2, que la caméra ne rend pas.

| Test (sans fenêtre) | Résultat |
|---|---|
| Sol prêt | 0,9 s après le lancement, joueur posé à 1 cm du sol |
| Marche 2,5 s | 12,4 m (≈ 5 m/s), toujours au sol |
| Saut | +0,73 m, retour au sol |
| Vol 1 s | +16,5 m |

Captures depuis la caméra du joueur : `results/explore/explore_0.png` à `explore_2.png`.

## Lumière façon jeux low poly

Question : pourquoi le rendu en jeu est terne alors que les jeux low poly sont jolis ?
Les articles consultés sont d'accord : la géométrie reste simple, mais la lumière et
les couleurs sont très soignées ([Game Developer](https://gamedeveloper.com/design/how-to-make-low-poly-look-good),
[80.lv, Lonely Mountains](https://80.lv/articles/level-game-production-lonely-mountains-downhill),
[Unity](https://unity.com/blog/how-to-create-atmospheric-environments-on-a-budget),
[80.lv, Athonite](https://80.lv/articles/simple-stylized-environment-scale-and-mood/)).
Les recettes communes : soleil chaud contre ombres froides, ciel en dégradé, contraste
élevé, saturation maîtrisée, brume qui sépare les plans.

Test A/B sur `scenes/savanna_128.tscn` (mêmes modèles, seule la lumière change) :
`results/look_ab/a_*.png` (avant), `b_*.png` (test) et `final_*.png` (réglage retenu).

Nouvel éclairage de la savane, repris dans `savanna_128.tscn`. Il était d'abord dans le
biome du plugin (`make_savanna_environment()` et bouton *Apply Biome Lighting*). Il est
maintenant dans le **projet**, comme l'horizon, car la lumière dépend du jeu. On le
trouve dans `world/savanna_environment.tres` (ciel, ambiance, brume, couleurs) et dans
`world/savanna_sky.tscn` (cet environnement et le soleil, à glisser dans une scène) :

| Réglage | Avant | Après |
|---|---|---|
| Ciel (haut / horizon) | bleu pâle / beige | bleu franc / beige poussière |
| Disque du soleil | 30° | 6°, bord doux |
| Ambiance | chaude, 45 % ciel | gris froid, 50 % ciel, énergie 0,85 |
| Tonemap | AgX, exposition 1,05 | ACES, exposition 1,0 |
| Contraste / saturation | 1,0 / 1,03 | 1,12 / 1,12 |
| Glow | non | oui, doux (intensité 0,35, seuil 1,1) |
| Brume | 0,0012 | 0,0022, perspective aérienne 0,5 |
| Soleil | 46°, (1, 0,92, 0,8), 1,25 | 32°, (1, 0,86, 0,68), 1,55 |

Tout reste compatible avec le rendu Mobile (pas de SSAO, SSR, SDFGI ni brouillard
volumétrique ; le glow est le seul effet ajouté). La scène d'exploration utilisait en
plus une brume beige qui recouvrait tout le ciel ; c'était la cause principale de
l'aspect laiteux.

Restent à faire, par ordre d'impact : un horizon (fait, voir la section suivante), du
vent dans l'herbe et les feuillages, de l'herbe plus dense ou un sol coloré en taches,
un léger facettage du sol, des ombres de contact sous les arbres. Les stries visibles
sur la route avec plus de contraste sont aussi à corriger.

## Horizon : la carte ne s'arrête plus dans le vide

Nœud `MapHorizon` (`world/map_horizon.gd`), enfant du terrain. Il fait partie du **projet**
et non du plugin : l'aspect du bord d'une carte dépend du jeu.
- FPS : un paysage lointain comme celui-ci.
- Vue du dessus : on bloque la caméra dans la carte et on met un sol uni dessous.
- Île : de l'eau tout autour.

Au départ, l'horizon était dans le plugin, avec un bouton *Add Horizon*. Il a été sorti
du plugin pour que celui-ci reste simple. Ce que fait le nœud :

- **Sol prolongé** : des anneaux partent du bord à la hauteur du terrain (un anneau
  passe 1,5 m sous le bord pour ne laisser aucune fente), puis s'aplatissent sur 40 m
  vers la hauteur médiane du bord, avec de légères ondulations. Le dernier anneau
  plonge à 700 m, où la brume le cache. Les anneaux lointains ont moins de segments :
  des triangles longs et fins faisaient des stries.
- **Couleur** : celle du bord, lue dans les couleurs de sommets des chunks du terrain
  (ombrage cuit compris), qui passe à la teinte d'herbe sèche du biome à la luminosité
  réelle du terrain, avec des taches de latérite et de vert.
- **Collines** : 10 plateaux de latérite à sommet plat (les « cuirasses » du Sénégal)
  ou collines rondes, entre ~200 et 500 m.
- **Arbres** : 80 acacias et baobabs (mêmes modèles que la carte) jusqu'à 90 m hors
  du bord, en deux MultiMesh.
- **Murs** : en jeu seulement, 4 murs invisibles sur le bord. Testé : la capsule
  s'arrête à 35 cm du bord.

Coût : un maillage d'environ 3 100 triangles (sol + collines, un seul appel de
dessin, le matériau du terrain, sans ombre projetée) + les arbres (~22 000 triangles)
en MultiMesh découpés en 4 × 4 zones, pour que seules les zones vues (et proches, pour
les ombres) soient dessinées. Voir « Mesures par vue » plus bas. Rien
n'est sauvegardé dans la scène : il est reconstruit au chargement, après une carte
générée en jeu (`terrain_ready`) et avec son bouton *Rebuild*.

Captures : `results/horizon/h_*.png`.

## Vent dans l'herbe et les arbres

L'herbe, les buissons, les acacias et les baobabs bougent maintenant au vent, dans
l'éditeur comme en jeu (la carte et les arbres de l'horizon). Les rochers, termitières,
crânes et os ne bougent pas.

- **Shader** `materials/detail_wind.gdshader` : même rendu que l'ancien matériau des
  détails (couleur des sommets × couleur d'instance, sRGB, mat, sans reflet). Seuls
  les sommets bougent. Le pied reste planté et la plante plie de plus en plus vers le
  haut. Des rafales lentes traversent la carte dans le sens du vent, chaque plante a sa
  propre phase, et un petit frisson rapide s'ajoute.
- **Profils** (`MaterialFactory.WIND_PROFILES`) : herbe (plie le plus), buisson, arbre
  (seule la couronne bouge, le tronc reste fixe), baobab (bouge à peine). Il y a
  4 matériaux partagés au total.
- **Réglage** depuis le code : `MaterialFactory.set_wind(direction, force)`. Une force
  de 0 donne le calme, 1 le réglage par défaut, 2 un vent fort.
- **Scènes déjà construites** (savanna_128) : leurs détails gardaient l'ancien matériau.
  Au chargement, `_LowpolyTerrainRuntime` leur donne le bon matériau, sans reconstruire.

Vérifié :

| Test | Résultat |
|---|---|
| Deux images à 0,4 s d'écart, eau cachée | 1,3 % des pixels changent, uniquement l'herbe, les arbres et les baobabs (`diff_a_t0_b_t1.png`) |
| Vent à 0 comparé à l'ancien matériau | 0 pixel différent : le rendu est identique |
| Perf, Mobile, 1280×720, 4 × 300 images | 5,62 ms par image avec le vent, 5,75 ms sans (dans le bruit) |
| Smoke test | 74/74 |

Coût : environ 20 opérations de plus par sommet, sans texture.

Captures : `results/wind/`.

## Mesures par vue : FPS et vue du dessus (vent, horizon)

Mesures sur savanna_128, renderer Mobile, 1280×720, sans vsync, sur un Intel Iris Xe
(PC, pas un téléphone). Médiane de 3 × 240 images. Trois caméras :
- **fps** : à hauteur d'homme ;
- **dessus centre** : à 45 m au-dessus du centre, incliné comme un jeu de stratégie ;
- **dessus bord** : la même caméra placée au bord de la carte.

La première mesure a révélé un gaspillage dans l'horizon. Le soleil fait ses ombres
en 4 cascades, et le sol de l'horizon comme l'anneau d'arbres (un seul MultiMesh)
couvraient les 4. Ils étaient donc redessinés 4 fois de plus, même là où aucune ombre
n'est visible. Corrections :
- le sol de l'horizon ne projette plus d'ombre ;
- les arbres sont découpés en 4 × 4 zones.

L'image ne change pas.

| Vue | Coût GPU de l'horizon avant | après | Triangles ajoutés avant | après |
|---|---|---|---|---|
| fps | +0,67 ms | +0,04 ms | +127 000 | +17 600 |
| dessus centre | +0,72 ms | +0,25 ms | +127 000 | +27 400 |
| dessus bord | +1,29 ms | +0,80 ms | +127 000 | +27 200 |

Au bord, le reste du coût vient des pixels : sans horizon, la moitié de l'écran est du
vide, qui ne coûte rien à dessiner. Avec n'importe quel sol à cet endroit, ce coût
serait là aussi.

Après correction (GPU ms par image, médiane) :

| Vue | Complet | Sans vent | Sans horizon | Horizon léger¹ | Ni vent ni horizon |
|---|---|---|---|---|---|
| fps | 3,87 | 3,96 | 3,83 | 3,88 | 3,70 |
| dessus centre | 3,84 | 3,67 | 3,59 | 3,64 | 3,52 |
| dessus bord | 3,61 | 3,42 | 2,81 | 3,31 | 2,96 |

¹ 0 arbre, 0 colline, rayon 250 m.

Le vent ne se mesure pas : les écarts sont de ±0,2 ms et vont dans les deux sens.

**Vue du dessus** : l'horizon y est plus utile qu'en FPS. Sans lui, la carte flotte
dans le vide, et les bords se voient en permanence (`results/perf_vues/dessus_bord_*`).
Les collines lointaines et le rayon de 700 m ne servent pas en vue du dessus, mais
coûtent peu. Pour un jeu vu du dessus, on peut mettre `hills` à 0, `radius` à environ
250 et moins de `trees`.

## Pinceau Végétation (2026-11-23)

- Donnée : 1 octet par case (`_lte_cell_vegetation`), absente tant qu'on n'a pas peint. Carte non peinte = placement identique à avant (vérifié : même hash des détails).
- En jeu : aucun coût propre. Une zone peinte « plus » contient jusqu'à 4 fois plus d'herbe et d'arbres, donc plus d'instances à dessiner à cet endroit. Une clairière en contient moins.
- Dans l'éditeur, un coup de pinceau re-disperse seulement les détails des morceaux touchés, une fois par image. Le sol et la collision ne sont pas reconstruits.
- Ordre de grandeur : re-disperser toute la carte 128 prend 0,44 s (test hors écran). Le pinceau ne touche que 1 à 4 morceaux de 32×32 cases.
- Version permissive (maximum par couche ×4 à ×25, règles assouplies) :
  - carte non peinte : placement identique au hash près (12 121 instances, 0,42 s pour toute la carte) ;
  - cas extrême, toute la carte peinte au maximum sur toutes les couches : 186 814 instances, 1,13 s pour toute la carte ;
  - une forêt d'acacias peinte sur 3 disques de 10 m passe de 7 à 117 arbres.

  À surveiller sur mobile : une grande zone d'herbe ou de roseaux peinte au maximum (×4 sur des couches denses).

## Physique

150 sphères `RigidBody3D` sur la collision concave (78 k triangles) prennent 1,5 à 5 ms
par frame de physique, quelle que soit la taille du terrain. Pas de problème.

## Défauts visuels repérés (non corrigés)

- **Routes sur les pentes raides :** sur les pentes fortes, le terrain traverse la route
  par endroits (`mobile_128_close.png`).
- **Compatibility surexposé :** avec le même `Environment`, ce renderer rend l'image
  surexposée (`gl_compatibility_256_hero.png`). Il faut régler l'éclairage à part. Ce
  n'est pas lié au plugin.

## Recommandations restantes pour le mobile

1. **Réglages du projet :**
   - renderer Mobile, ou Compatibility pour l'entrée de gamme ;
   - ombres désactivées, ou 1 à 2 cascades avec une distance courte ;
   - cocher **Mobile Water**.
2. **Textures :** pour garder 1 surface par chunk avec des styles texturés, il faudrait
   un atlas de textures. C'est hors de portée pour l'instant.
3. **Éditeur :** le gel en fin de trait est descendu à environ 0,3 s. Pour aller plus loin, il
   faudrait mettre à jour la collision par chunk au lieu de la reconstruire en entier.

## Relancer les mesures

Les commandes se lancent depuis `test_project/` (`G` = chemin de l'exe Godot) :

```
"$G" --headless --path . --script res://tools/build_terrains.gd        # scenes/ + build_report.json
"$G" --headless --path . --script res://tools/check_optimizations.gd   # vérifications (code de sortie 1 si échec)
"$G" --headless --path . --script res://tools/load_test.gd             # taille / temps de chargement
"$G" --path . --rendering-method mobile res://bench/bench.tscn -- --terrain=res://scenes/terrain_256.tscn
"$G" --headless --path . --script res://tools/image_diff.gd            # captures before_optim vs actuelles
"$G" --headless --path . --script res://tools/profile_features.gd      # détail du gel en fin de trait
"$G" --headless --path . --script res://tools/compare_feature_mesh.gd  # mesh routes/rivières identique à celui de la scène ?
"$G" --headless --path . --script res://tools/make_split_variant.gd    # scenes/terrain_256_split.tscn (ancien découpage, pour A/B)
"$G" --headless --path . --script res://tools/compare_chunks.gd -- --terrain=res://scenes/terrain_256_flat.tscn --zero   # ombrage à 0 = chunks d'avant ?
"$G" --headless --path . --script res://tools/compare_chunks.gd -- --time   # temps de construction avec / sans ombrage
"$G" --headless --path . --script res://tools/check_shading_seams.gd   # pas de couture entre chunks
"$G" --headless --path . --script res://tools/before_after.gd -- --before=a.png --after=b.png --out=c.png
```

`"$G" --headless --path . --script res://tools/profile_details.gd` mesure le temps de
placement des détails, `tools/build_savanna.gd` construit les scènes de savane (avec
mares), `tools/check_waterholes.gd` vérifie les mares,
`"$G" --path . --rendering-method mobile --script res://tools/shoot_waterholes.gd -- --hole=0`
photographie une mare,
`"$G" --path . --rendering-method mobile --script res://tools/preview_props.gd` rend la planche des meshes, `tools/check_biomes.gd` vérifie le système de biomes (code de sortie 1
si échec) et `tools/save_biome_presets.gd` régénère `biomes/presets/*.tres` (à recopier dans
l'addon principal), avec aussi `generation/presets/*.tres`.
`"$G" --path . --rendering-method mobile --resolution 1280x720 --script res://tools/shoot_map.gd -- --tag=final --lighting=biome`
photographie la carte de banc sous 9 angles (`--only=track,eye` pour en choisir),
`tools/check_maps.gd` vérifie les cartes générées et le runtime,
`tools/build_map_scene.gd -- --seed=2026` sauve une carte générée en scène de banc, et
`"$G" --path . --rendering-method mobile res://demo/runtime_demo.tscn -- --walk-test`
lance la démo jouable (WASD, R = nouvelle carte, F = vue d'ensemble).

Options du banc : `--orbit=ground` (orbite au sol), `--details=0` (retire herbe et rochers),
`--rendering-method mobile|gl_compatibility|forward_plus`,
`--terrain=res://scenes/terrain_256_mobilewater.tscn`, `--shadows=0`, `--shots=0`,
`--spheres=0`, `--seconds=6`.

L'addon de `test_project/addons/` est une **copie**. Il faut la recopier depuis
`addons/lowpoly_terrain_editor` après chaque modification du plugin.

## Sol nu : le décor vient après (2026-11-23)

Sur un terrain neuf, le sol peint à la main reste nu. Herbe, arbres et décors s'ajoutent ensuite avec l'outil Végétation. Generate Map les fait toujours pousser sur la carte qu'il crée. Le réglage est Inspector > Advanced > Details > « Details Everywhere » : coupé sur un terrain neuf, activé sur les anciennes scènes, qui ne changent donc pas.

Mesure `tools/profile_bare_ground.gd` sur savanna_128 : 16 morceaux, `DetailScatter.build`, meilleur de 3 essais.

| Cas | Objets | Temps par morceau |
|---|---|---|
| Décor partout (ancien comportement) | 12 313 | 19,7 ms |
| Carte générée, réglage coupé | 12 313, placement identique | 19,5 ms |
| Sol peint à la main + coups de pinceau Végétation de la scène | 169 | 1,6 ms |
| Sol peint à la main, sans pinceau | 0 | 0,26 ms |

**Conséquence :** chaque coup de pinceau Sol refait les détails des morceaux qu'il touche. Sur un sol nu, ce travail est presque nul, environ 75 fois moins qu'avant. Le jeu n'affiche que les objets peints.

### Clic = un objet (même jour)

Avant, il fallait cliquer plusieurs fois pour faire apparaître un baobab, et souvent rien n'apparaissait.

**Cause :** chaque case a un tirage au hasard fixe. Même peinte au maximum, seule une case sur 40 environ pouvait porter un baobab.

**Correction :** une couche rare (arbres, décors, rochers) se peint maintenant par blocs de 2 à 8 cases. Chaque bloc reçoit un objet, placé sur sa case la plus peinte qui n'est pas trop raide.

Mesure `tools/check_click_props.gd` : 30 endroits de l'île, clic de taille 3, une couche choisie.

| Couche | Avant : 1er clic | Avant : jamais en 12 clics | Après : 1er clic | Après : jamais |
|---|---|---|---|---|
| Baobabs | 1/30 | 23/30 | 30/30 | 0/30 |
| Termitières | 0/30 | 14/30 | 30/30 | 0/30 |
| Crânes | 2/30 | 19/30 | 30/30 | 0/30 |
| Acacias | 4/30 | 7/30 | 30/30 | 0/30 |
| Rochers | 3/30 | 0/30 | 30/30 | 0/30 |

Les cases non peintes gardent le même placement : `compare_chunks` donne IDENTICAL, et `profile_bare_ground` montre que carte générée = décor partout.

**Deuxième passe :** les derniers clics ratés tombaient sur une falaise ou sur une pente trop raide pour l'objet.
- L'objet va maintenant sur la case plate voisine.
- La chance du bloc vient de sa case la plus peinte.
- Le test de pente est le même pour le choix de la case et pour la pousse.

`check_click_props` exige désormais un objet au premier clic, dans 30 cas sur 30. Un seul cas reste normal : un clic juste à côté d'un objet du même type n'en ajoute pas un deuxième.
