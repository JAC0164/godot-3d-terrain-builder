# Audit mémoire + fps (2026-11-25)

Godot 4.7.2, renderer **Mobile**, Jolt. Mesures sur PC (Iris Xe), fenêtre hors écran 1280×720.

**Scène mesurée** :
- le monde ouvert de 1,5 km : preset savane monde ouvert, graine 7, 1 024 cases ;
- streamé comme en jeu : sol à 160 m, blocs lointains à 600 m, détails streamés, threads ;
- caméra debout au centre ; on mesure une fois tout construit.

**Outils** :
- `tools/profile_memory.gd [-- --noshadow] [--radiance=0] [--sky-only]` ;
- `tools/check_heightmap_collision.gd`.

Chaque poste de RAM a été **vérifié en le libérant** : on regarde de combien la RAM statique
baisse.

## Résumé

| Levier | Gain mesuré | Côté | Risque |
|---|---|---|---|
| Caches de routes sans normales + zstd | **−13,8 Mo RAM** (16,5 → 2,7) | plugin | faible |
| Collision du sol en height map tournée de 90° | **−9 à −12 Mo RAM**, un chunk en **0,09 ms au lieu de 3,6** | plugin | moyen |
| Compression des sommets avec tangentes | **−33 %** de VRAM sur le sol (≈ −5,8 Mo) | plugin | coutures à vérifier |
| Libérer le vieux masque par sommet en jeu | −4 Mo RAM (1 024 cases) | plugin | faible |
| Blocs lointains soudés et indexés | ≈ −6 Mo VRAM | plugin | visuel au loin |
| Taille de radiance du ciel 256 → 32 | **−19 Mo VRAM** | jeu | à vérifier à l'œil |
| Carte d'ombre du soleil (4 096 sur PC) | 40 Mo VRAM tant qu'elle existe | jeu | déjà coupée sur le téléphone |

**Côté fps**, le plugin n'a presque plus de marge GPU :
- sur le Tecno, le terrain coûte environ 0,4 ms quand les ombres du soleil sont coupées ;
- le reste, environ 15,5 ms, vient du ciel, du brouillard et du post-traitement (côté jeu) ;
- il reste par contre des **à-coups** pendant le streaming. La construction des collisions en est
  le plus gros, et la height map la rend 40× plus rapide.

## 1. Où va la mémoire

Le terrain construit ajoute **+49 Mo de RAM statique**. Il ajoute aussi **+21 Mo de mémoire
vidéo** pour sa géométrie, sans compter les ombres et les buffers de rendu.

### RAM (statique)

| Poste | Mo | Mesure |
|---|---|---|
| Données de la carte (hauteurs, styles, masque, cases) | 14,0 | tableaux de la carte |
| Caches de routes et rivières découpées par chunk (`_road_pieces` + `_road_faces`) | **16,5** | libéré |
| Collisions du sol (33 corps, 60 k triangles, Jolt) | **9,8** | libéré |
| Faces des chunks gardées pour la collision (`_chunk_face_cache`) | 2,9 | libéré |
| Couleurs du sol pour les détails (`_shading_cache`) | 2,1 | libéré |
| Grilles des blocs lointains (`_far_data`) | 2,5 | libéré |
| Reste : nœuds, objets, allocateur | ≈ 15 | déduit |

Les caches de routes gardent **toute la carte** : 213 chunks ont une route ou une rivière, alors
que 15 seulement sont affichés autour du joueur.

### Mémoire vidéo

| Poste | Mo |
|---|---|
| Ciel : cubemap de radiance, `radiance_size` 256 | 19,5 |
| Carte d'ombre du soleil (4 096, réglage PC par défaut) | 40 |
| Buffers de rendu à 1280×720 | ≈ 20 |
| Sol détaillé : 60 chunks, 415 k sommets, 24 o par sommet | 9,5 |
| Blocs lointains : 52 blocs, 334 k sommets | 7,7 |
| Ombre du sol (`_GroundShadow`, soudée et indexée) | 1,7 |
| Routes et rivières (15 chunks) | 0,95 |
| Détails : 10 900 instances × 64 o, plus les meshes partagés | 0,8 |

- Les détails streamés ne pèsent presque rien.
- Le gros de la mémoire vidéo vient du ciel, des ombres et de la résolution. Ce sont des réglages
  du jeu.
- **Draw calls** : 105 visibles et 28 dans le passage d'ombre, pour 158 k triangles. Rien à
  gagner de ce côté.

## 2. Leviers côté plugin

### 2.1 Caches de routes : −13,8 Mo (risque faible)

**Ce qu'on garde aujourd'hui** : pour toute la carte, les sommets, les normales et les UV de
chaque morceau de route, plus une copie des faces de collision.

**Mesures** :
- les normales de route et de rivière sont des normales de face (`_add_triangle`,
  `add_upward_triangle_uv`). On peut les recalculer à l'affichage ;
- sans les normales, il reste 8,0 Mo ;
- compressé en zstd, il reste 1,75 Mo, plus 0,9 Mo pour les faces de collision ;
- décompresser les 213 chunks prend 22 ms en tout, soit **environ 0,1 ms par chunk**, au moment où
  la route est attachée.

**Changement** :
- `FeatureMesher` compresse chaque chunk pendant le découpage, qui tourne déjà sur un thread ;
- `_attach_roads` décompresse et recalcule les normales ;
- `_add_chunk_shape` décompresse les faces.

**Vérification** : le hash de `check_feature_split.gd` doit rester identique.

### 2.2 Collision du sol en height map : −9 à −12 Mo, 40× plus rapide (risque moyen)

**Mesures** (64 corps de 32×32 cases) :
- trimesh : **271 Ko et 3,6 ms** par chunk ;
- `HeightMapShape3D` : **11 Ko et 0,09 ms** par chunk.

**Le piège : la diagonale**
- Jolt (comme Godot Physics) coupe chaque case par la diagonale (x+1, z)–(x, z+1).
- Le terrain la coupe par la diagonale 00-11.
- Écart mesuré : jusqu'à 2,5 m sur un relief aléatoire.
- **Avec la forme tournée de 90° autour de Y** (données réordonnées), l'écart tombe à **0,1 mm**
  (`tools/check_heightmap_collision.gd`).

**Ce que ça apporte** :
- la RAM des collisions passe de 9,8 Mo à environ 0,4 Mo ;
- `_chunk_face_cache` ne sert plus : les hauteurs se lisent dans les données (−2,9 Mo) ;
- la forme d'un chunk se construit en 0,09 ms au lieu de 3,6 ms, sur le fil principal ;
- sur le téléphone, environ 3× plus lent, c'est une image de 10 ms évitée chaque fois qu'un chunk
  entre dans la zone de collision.

**Limites** :
- **Trous** : une height map n'a pas de murs, mais elle accepte des trous, codés par NaN dans la
  height field de Jolt.
  - Les cases non peintes deviennent des trous.
  - Les chunks qui ont des murs (falaises vers le vide, bord de carte) gardent le trimesh actuel.
- **Routes** : elles restent une deuxième forme trimesh sur le même corps, comme aujourd'hui.
- **Espacement** :
  - Godot met un échantillon par mètre ;
  - pour l'espacement de 1,5 m, on divise les hauteurs par 1,5 et on applique une échelle
    **uniforme** de 1,5 ;
  - on évite ainsi une échelle non uniforme sur la forme.
- **Grille carrée** : obligatoire. Sinon Jolt retombe en silence sur une MeshShape complète.
  33×33 convient.

### 2.3 Compression des sommets : −33 % sur le sol (risque faible à moyen)

Avec `ARRAY_FLAG_COMPRESS_ATTRIBUTES`, un sommet du sol passe de 24 à 16 o :
- la position est stockée en 16 bits dans la boîte du chunk ;
- la tangente est rangée dans la position et ne coûte rien ;
- la couleur reste en RGBA8.

**Premier essai, sans tangentes** :
- 651 normales sur 6 912 étaient fausses, certaines retournées (jusqu'à 172°) ;
- c'est la règle de Godot (PR #81138) : en compression, il faut **des normales avec des
  tangentes, ou ni l'un ni l'autre**.

**Second essai, avec une tangente quelconque perpendiculaire à la normale** :
- erreur de normale max **0,017°** ;
- erreur de position max **1 mm** sur un chunk de 48 m.

**Gain** :
- sol détaillé 9,5 → 6,3 Mo ;
- blocs lointains 7,7 → 5,1 Mo ;
- moins d'octets lus par sommet. L'auteur du PR mesure environ 10 % sur le renderer Mobile. Le
  gain sera plus petit sur le Tecno, qui est limité par les pixels.

**À vérifier** :
- chaque chunk est arrondi dans sa propre boîte. Un sommet partagé par deux chunks peut donc tomber
  à 1 mm près de chaque côté ;
- il faut contrôler les coutures entre chunks : aucun pixel ne doit scintiller sur les bords.

### 2.4 Vieux masque par sommet : −4 Mo en jeu (risque faible)

- `_lte_mask` stocke un float par sommet : 4 Mo à 1 024 cases.
- Il ne sert plus que de repli pour les terrains créés avant `_lte_cell_active`.
- En jeu, le runtime peut le libérer quand `_lte_cell_active` existe.
- Dans l'éditeur, on n'y touche pas : le pinceau l'utilise encore.

### 2.5 Blocs lointains soudés : ≈ −6 Mo VRAM (optionnel, visuel)

- Un bloc lointain a autant de sommets qu'un chunk : 6 912, chaque triangle avec ses propres
  sommets pour les facettes.
- Soudé et indexé, il descend à environ 1 100 sommets plus des index 16 bits : de 165 Ko à environ
  30 Ko.
- En échange, le sol devient lisse au-delà de 160 m, sous le brouillard.
- À proposer en option, désactivée par défaut.

## 3. Leviers côté jeu (test_project)

- **Ciel** : passer `radiance_size` de 256 à 32 libère **19 Mo de VRAM**.
  - Dans la savane comme dans le monde ouvert, l'ambiance est en couleur et les reflets sont
    coupés : la radiance ne sert presque plus.
  - Seule la perspective aérienne du brouillard la lit encore (0,5), et `phone_quality.gd` la coupe
    déjà sur le téléphone.
  - Sur PC, il faut vérifier à l'œil.
- **Ombres du soleil** : leur carte prend 40 Mo de VRAM à la taille PC (4 096). Sur le téléphone,
  la taille par défaut est 2 048, et `phone_quality` coupe déjà les ombres.
- **Buffers de rendu** : environ 20 Mo à 720p. Ils suivent la résolution et l'échelle 3D, que
  `phone_quality` règle déjà.

## 4. Recherches

Sources principales :
- le code de Godot (`master`) ;
- la doc 4.7 ;
- les blogs Arm.

### Mémoire

- **Meshes** :
  - Godot ne garde pas de copie CPU d'un mesh : `surface_get_arrays` relit le GPU ;
  - par contre, `Mesh.get_faces()` et `create_trimesh_shape()` créent un cache CPU (TriangleMesh
    avec BVH) que `clear_surfaces()` ne libère pas ;
  - le runtime ne s'en sert déjà plus en jeu.
- **MultiMesh** :
  - tout est en float 32, soit 64 o par instance avec la couleur ;
  - `set_buffer()` ne crée pas de copie CPU, contrairement à `set_instance_*`. Le plugin utilise
    déjà `buffer` ;
  - `visible_instance_count` et les visibility ranges ne libèrent aucune mémoire.
- **Collision** :
  - `ConcavePolygonShape3D` garde les faces (36 o par triangle) en plus de la MeshShape de Jolt.
    Mesuré ici : 162 o par triangle au total ;
  - `HeightMapShape3D` devient une height field de Jolt, compressée par blocs, à condition que la
    grille soit carrée ;
  - NaN code un trou.
- **Moniteurs** :
  - `MEMORY_STATIC` ne compte que ce que Godot alloue, et seulement en build debug. Jolt passe par
    cet allocateur, il est donc compté ;
  - sur Android, la mémoire vidéo est de la RAM partagée, et ce que prend le pilote n'apparaît
    nulle part ;
  - à recouper avec `adb shell dumpsys meminfo com.lte.perftest`.

### Fps sur Mali

- **Pas de prépasse de profondeur** sur le renderer Mobile : Mali compte sur Forward Pixel Kill.
  - `discard` et l'alpha-to-coverage cassent FPK. L'herbe opaque à un triangle du plugin l'évite
    déjà.
  - Les micro-triangles au loin réduisent l'efficacité de FPK. La densité d'herbe doit donc
    baisser avec la distance.
- **Occlusion culling** :
  - sans prépasse, la doc dit qu'il réduit vraiment le sur-dessin sur Mobile, et le relief en
    collines est son meilleur cas ;
  - son coût est sur le CPU (Embree), et je n'ai pas pu vérifier qu'Embree tourne sur Android
    arm64 ;
  - le plugin pourrait fournir un occluder grossier par chunk (`ArrayOccluder3D`). Piste non
    mesurée.
- **Leviers récents de Godot** :
  - constantes de spécialisation (4.5) : −7 ms sur un Pixel 8 Pro. Elles sont déjà dans 4.7 ;
  - FP16 automatique (4.5) ;
  - ubershaders (4.4) : ils suppriment des à-coups, pas le coût par image ;
  - FSR retombe en bilinéaire sur Mobile. La vraie manette reste `scaling_3d/scale`, que
    `phone_quality` règle déjà ;
  - le VRS demande un Mali-G615 ou plus récent, il n'existe pas sur le Tecno (G57).
- **`force_vertex_shading`** (4.4) :
  - la doc annonce un gros gain, avec une forte perte de qualité ;
  - pour un sol à facettes, l'éclairage par sommet est presque identique, puisque la normale est la
    même sur tout le triangle ;
  - c'est un réglage du projet, côté jeu, à tester sur le Tecno. Personne ne l'a mesuré sur Mali.
- **Ciel** : en mode AUTOMATIC, la radiance est recalculée à chaque image si le shader du ciel
  utilise `TIME`. Le ciel procédural du jeu ne l'utilise pas : on n'y gagne que la mémoire
  (radiance 32).

### Pratiques de l'industrie

- **Meta, Dead & Buried 2 (Quest)** :
  - LOD en quadtree, recalculé seulement tous les 1 m de déplacement ;
  - le parent reste visible tant que ses enfants chargent ;
  - moins de 100 draw calls statiques ;
  - l'occlusion culling intégré, jugé trop lourd sur mobile, n'est pas utilisé.
  - Le plugin fait déjà l'équivalent : les blocs lointains restent tant que les chunks arrivent, et
    on dessine 105 draw calls.
- **SEED (Unity)** : couleurs et matériaux dans les sommets pour économiser la bande passante.
  C'est le choix du plugin.
- **Ghost of Tsushima** : herbe par brin, avec une densité qui baisse avec la distance.

Points non trouvés :
- le coût en octets par triangle de la MeshShape de Jolt (mesuré ici à la place) ;
- un benchmark height map contre trimesh (mesuré ici) ;
- le coût sur Mali des normales par dérivées et du vertex shading.

## 5. Ordre conseillé

1. **Caches de routes compressés** : −13,8 Mo de RAM, risque faible, test de hash existant.
2. **Collision en height map** : −12 Mo de RAM, chunk 40× plus rapide. Trous en NaN ; les chunks
   avec murs gardent le trimesh.
3. **Compression des sommets** avec tangentes : −5,8 Mo de VRAM, sommets plus légers. Coutures à
   vérifier.
4. **Masque libéré en jeu** : −4 Mo, trivial.
5. **Côté jeu** : radiance 32 (−19 Mo de VRAM) ; `force_vertex_shading` à tester sur le Tecno.
6. **Optionnel** : blocs lointains soudés, occluders par chunk.

**En tout, côté plugin** :
- environ **−30 Mo de RAM**, soit −60 % de ce que le terrain construit ajoute en plus des
  données ;
- **−6 à −12 Mo de VRAM**.

Côté jeu, on gagne en plus −19 Mo de VRAM.

**Côté fps**, le gain du plugin porte surtout sur les **à-coups** : collision 40× plus rapide,
routes plus légères à attacher. La moyenne bougera peu, parce que le GPU du Tecno passe son temps
sur les pixels du ciel, du brouillard et du post-traitement.

## 6. Appliqué (2026-11-25) : les quatre leviers du plugin

**Les changements** :
1. **Routes** : `FeatureMesher` compresse chaque morceau par chunk en zstd sur le thread de travail
   (`pack_arrays`).
   - Le runtime décompresse au moment d'attacher la route ou de construire la collision
     (`piece_arrays`, `unpack_faces`).
   - L'aller-retour est exact au bit près : les normales restent stockées, compressées elles
     aussi.
2. **Collision** : `TerrainMesher.height_field()` fait la height map tournée de 90° pour chaque
   chunk sans mur.
   - Le runtime construit une `HeightMapShape3D` et ajoute les routes en seconde forme.
   - Les chunks du bord de carte, qui ont des murs, gardent leurs triangles.
3. **Sommets compressés** : nouvelle option `compress_vertices` du runtime, activée par défaut.
   - Elle touche le sol streamé et les blocs lointains.
   - Les tangentes sont calculées sur le thread (`MeshUtils.tangents_for`).
4. **Masque** : en jeu streamé, `_lte_mask` devient un tableau vide (`_free_legacy_mask`).

Les petites cartes non streamées et l'éditeur ne changent pas.

**Résultat** (même scène, `profile_memory.gd -- --noshadow`) :

| | Avant | Après |
|---|---|---|
| RAM ajoutée par le terrain construit | +49,1 Mo | **+21,3 Mo** (−57 %) |
| Mémoire vidéo totale | 71,8 Mo | **66,1 Mo** |
| Buffers GPU | 23,1 Mo | 17,4 Mo |
| Triangles de collision du sol | 60 300 | 5 000 (routes et bords) + 24 height maps |
| Caches de routes | 16,5 Mo | 3,3 Mo |
| Cache de faces | 2,9 Mo | 0,27 Mo |
| Sol détaillé / blocs lointains (VRAM) | 9,5 / 7,7 Mo | 6,3 / 5,1 Mo |

**Contrôles** :
- coutures entre chunks compressés : écart max **0,15 mm** sur 3 387 coins partagés ;
- height map contre triangles sur la carte monde ouvert (`check_heightmap_ground.gd`, dans
  run_checks) :
  - écart max 1,1 cm : ce sont les hauteurs stockées sur 8 bits par Jolt ;
  - 73 % des chunks échantillonnés ont une height map ; les autres sont au bord de carte.
