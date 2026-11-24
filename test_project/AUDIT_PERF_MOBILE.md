# Audit perfs + rendu – terrains sur mobile (2026-11-23)

Godot 4.7.2, renderer **Mobile**, portable Intel Iris Xe, fenêtre 1280×720, vsync coupée.
Outil : `tools/audit_perf.gd` (résultats et captures dans `results/audit/`).

Scène mesurée = un vrai niveau de jeu :
- carte savane générée, 192×192 m (preset Senegal savanna, graine 7) ;
- une rivière de test et 2 routes ;
- construction au lancement par le nœud runtime (« All at runtime », progressif, collisions) ;
- éclairage `world/savanna_sky.tscn` (soleil avec ombres).

Caméra à hauteur d'yeux (1,7 m) sur 7 vues : 4 vues de plaine, une vue d'ensemble à 45 m,
un point d'eau, une rivière. Plus une forêt d'acacias peinte au pinceau.

> ⚠️ Ce PC n'est pas un téléphone, et son GPU change de fréquence d'un run à l'autre.
> - Les temps GPU varient de ±0,5 ms entre deux runs identiques : seuls les gros écarts comptent.
> - Les chiffres fiables sont les triangles, les draw calls, la mémoire vidéo et les temps de
>   chargement (CPU).
> - Un GPU de téléphone milieu de gamme est environ 3 à 5× plus lent. Il est aussi beaucoup plus
>   sensible au nombre de triangles : un GPU mobile « à tuiles » trie chaque triangle avant de
>   dessiner.
> - **À confirmer sur un vrai appareil.**

## Résumé

- **Triangles dessinés par image : −47 %**.
  - Moyenne des vues : 328 k → **175 k** ; forêt : 550 k → **295 k**.
  - Draw calls : 129 → **116**.
  - Cause principale : l'herbe à un triangle par brin. Ensuite, moins d'ombres à calculer.
- **Temps GPU sur ce PC : presque inchangé.**
  - Réglages PC : 4,30 → 4,25 ms.
  - Réglages téléphone : 3,80 → 3,41 ms.
  - Ce PC n'est pas limité par les triangles. Son coût fixe, c'est la carte d'ombre du soleil.
  - Un téléphone, lui, paie chaque triangle (tri par tuiles) : le gain y sera plus visible.
    À confirmer sur un appareil.
- **Godot règle déjà mieux les ombres sur téléphone.** Ses réglages `*.mobile` (carte d'ombre
  2048 et bords nets) font gagner −30 Mo de mémoire vidéo (104 → 73 Mo) et environ 0,5 ms.
  Rien à faire de plus.
- **Estimation pour un téléphone milieu de gamme**, GPU 3 à 5× plus lent : environ 10 à 17 ms
  par image en 720p.
  - 30 fps : confortable.
  - 60 fps : à la limite, possible avec l'échelle de rendu 3D à 0,75.
- **Chargement correct : le sol est prêt en 1,1 à 1,8 s, tout est fini en 2,2 à 3,6 s.**
  - Une seule étape longue : routes et rivières, 0,16 à 0,28 s en une image. Sur téléphone, ce
    sera 0,5 à 1,4 s, normalement derrière un écran de chargement.
  - Un pic de 1,5 s au tout premier lancement : la compilation du nouveau shader d'herbe. Il est
    mis en cache, les lancements suivants sont normaux.
- **Rendu : la savane est jolie.** Quatre défauts sont listés plus bas, comme propositions.
- **Rien n'est cassé.** Test de fumée 143/143 (2 vérifications ajoutées). check_biomes,
  check_custom_model, check_vegetation_paint, check_click_props, check_maps et check_waterholes
  sont OK.

## Ce qui a été changé

### Dans le plugin

1. **Herbe : un seul triangle par brin au lieu de deux.**
   - Avant, chaque brin était émis deux fois, dos à dos, pour être visible des deux côtés.
   - Maintenant l'herbe a son propre matériau « deux faces » (`materials/detail_wind_two_sided.gdshader`),
     et son maillage n'a qu'un triangle par brin.
   - Le dos du brin garde la normale vers le haut, donc l'éclairage est le même des deux côtés.
   - Seules les touffes d'herbe intégrées sont concernées. Les arbres, rochers et buissons gardent
     leur matériau. Avec un Detail Material personnalisé, l'herbe garde ses deux faces, pour qu'elle
     reste visible quel que soit ce matériau.
   - Herbe sèche : 14 → **7** triangles par touffe ; herbe verte : 12 → **6**.
   - Toute la végétation de la carte : 564 k → **381 k** triangles (−32 %).
   - Rendu identique : voir `results/audit/grass_compare.png`. Les petites différences viennent
     du vent animé.
2. **Routes et rivières ne projettent plus d'ombre.**
   - Elles sont posées à plat sur le sol, donc leur ombre ne se voit pas, mais elle coûtait une
     passe d'ombre sur ~28 k triangles.
   - Les scènes déjà sauvegardées sont corrigées au chargement.
   - Les plaques des points d'eau étaient déjà sans ombre.

Fichiers : `mesh/detail_meshes.gd`, `mesh/detail_scatter.gd`, `materials/material_factory.gd`,
`materials/detail_wind*.gdshader*`, `mesh/terrain_builder.gd`.

### Côté jeu (test_project, pas le plugin)

3. **Soleil de `world/savanna_sky.tscn` : 2 cascades d'ombre au lieu de 4, portée 50 m au lieu de 80.**
   - Triangles dessinés pour les ombres : environ un tiers en moins.
   - Les ombres restent nettes de près (captures `results/audit/a_new3_*.png`).
   - `HOW TO USE.txt` le conseille aux jeux mobiles.

## Mesures

### Rendu (moyenne des 7 vues, forêt à part)

Deux runs ou plus par ligne (une valeur par run). Les vues de plaine changent d'un run à
l'autre de ±0,5 ms, la forêt de ±2 ms : seules les colonnes triangles, draw calls et mémoire
vidéo sont exactes.

| Réglages | GPU ms | Triangles | Draw calls | Forêt GPU / triangles | Mémoire vidéo |
|---|---|---|---|---|---|
| **Avant**, ombres PC (carte 4096, bords doux), soleil 4 cascades / 80 m | 4,25 · 4,35 | 328 k | 129 | 8,3–8,8 ms / 550 k | 104 Mo |
| **Après**, ombres PC, soleil 2 cascades / 50 m | 4,04 · 4,30 · 4,34 · 4,32 | **175 k** | **116** | 6,3–7,4 ms / **295 k** | 104 Mo |
| Après, ombres téléphone (2048, nettes), 4 cascades / 80 m | 3,66 · 3,93 | 239 k | 128 | 5,3–6,2 ms / 455 k | 73 Mo |
| **Après, ombres téléphone, 2 cascades / 50 m** | 3,60 · 3,22 | **175 k** | **116** | 4,2–8,2 ms / **295 k** | **73 Mo** |
| + le sol ne projette pas d'ombre (piste 1) | 2,68 · 3,64 | 139 k | 102 | 3,5–5,6 ms / 243 k | 73 Mo |
| Sans aucune ombre (référence) | 2,34 · 2,98 · 2,26 | 124 k | 86 | 3,2–3,5 ms / 160 k | 62 Mo |

« Ombres téléphone » = les réglages par défaut de Godot sur Android et iOS
(`directional_shadow/size.mobile` = 2048 et `soft_shadow_filter_quality.mobile` = nettes),
reproduits avec `--phone=1`.

Autres essais (audit précédent, mêmes conditions) :
- échelle de rendu 0,5 : 4,2 → 3,5 ms ;
- distance de la végétation × 0,6 : presque rien, car la végétation est cachée par chunk de 32 m ;
- matériau de sol « grain » : +0,3 ms ;
- eau mobile : dans le bruit.

### Chargement (construction progressive au lancement)

| | Sol prêt | Tout construit | Pire étape (routes + rivières) | Images > 33 ms |
|---|---|---|---|---|
| Avant | 1,5–1,8 s | 3,0–3,6 s | 175–232 ms | 7–43 |
| Après | 1,1–1,8 s | 2,2–3,6 s | 156–283 ms | 4–41 |

- Pas de changement, à part le bruit : les changements ne touchent pas la construction.
- Génération de la carte : 150 ms.
- L'étape la plus longue est le maillage d'un réseau de routes : 117 à 190 ms pour 2 routes
  (grille de 0,45 m, 45 k sommets). Les rivières prennent 41 à 49 ms.

### Contenu de la carte savane 192×192 m

- 36 chunks de 32 m, 76 800 triangles de terrain, une surface par chunk.
- Routes + rivières + points d'eau : 28 k triangles.
- 29 400 objets de végétation en 313 MultiMesh :

  | Couche | Instances |
  |---|---|
  | herbe sèche | 22 157 |
  | herbe verte | 4 347 |
  | gravier | 1 169 |
  | rochers | 748 |
  | buissons | 453 |
  | acacias | 116 |
  | baobabs | 24 |

- 229 formes de collision. Mémoire vidéo : 104 Mo (73 Mo avec la carte d'ombre de téléphone).
- La petite île (carte « temperate island ») : 16 chunks, 3 ms GPU, chargée en 1 s.

## Revue du rendu (captures `results/audit/a_new3_*.png`)

Avant / après côte à côte : `results/audit/planche_audit_mobile.png`.
- Même image, avec moitié moins de triangles.
- Les ombres « téléphone » de Godot ont des bords nets, un peu crénelés sur les grandes ombres
  de collines.
- Si ça gêne, un jeu peut remettre `soft_shadow_filter_quality.mobile` sur « Soft Very Low ».
  C'est un peu plus cher.

**Ce qui marche bien :**
- La savane à hauteur d'yeux a de la profondeur : herbes sèches et vertes, acacias, baobabs,
  buissons, termitières, ombres douces.
- Les couleurs sont naturelles, la brume légère.
- Le vent fait bouger herbe et arbres.
- Les routes suivent le relief.
- Les points d'eau asséchés se lisent bien.

**À corriger (propositions, rien n'est changé) :**
1. ~~**Une rivière tracée sur une colline la monte**~~ — **corrigé le 2026-11-23.**
   - Le niveau d'eau ne fait que descendre depuis chaque bout de la rivière.
   - Sur une colline, la rivière creuse une tranchée à la hauteur de son côté le plus bas, avec
     des berges à 45°.
   - Une rivière qui descend une pente garde sa pente. Sur un terrain qui ne fait que descendre,
     le creusement est le même qu'avant.
   - Sculpter près d'une rivière met à jour son lit, et Annuler fonctionne.
   - Coût : +3 ms pour le creusement, +10 à 30 ms pour le maillage de l'eau.
   - Avant / après : `results/river_level/planche_riviere.png`.
   - Vérifié par `tools/check_river_level.gd` (7 vérifications) et par le test de fumée
     (146/146).
2. ~~**La vue d'ensemble à 45 m est délavée**~~ — **corrigé le 2026-11-23**, côté jeu
   (`world/savanna_environment.tres`, le plugin n'est pas touché).
   - La brume exponentielle (densité 0,0045) devient une brume selon la distance (« Depth ») :
     rien avant 60 m, puis elle monte doucement (courbe 2) jusqu'à couvrir tout à 320 m.
   - Vue d'en haut et à 15 m : couleurs nettes sur toute la carte. Au niveau des yeux : presque
     identique, et l'horizon lointain (MapHorizon) reste voilé.
   - Écarté : la brume en hauteur (Height Fog) de Godot ajoute de la brume sous la hauteur
     donnée. Elle épaissit la vue au sol sans éclaircir la vue d'en haut.
   - Piège Godot 4.7.2 : une brume « Depth » chargée depuis un fichier n'est appliquée que si
     la ligne `fog_mode = 1` vient **après** les lignes `fog_depth_*`. Or l'éditeur l'enregistre
     avant. Après avoir enregistré ce fichier depuis l'éditeur, il faut redescendre la ligne.
     `tools/check_environment.gd` le vérifie.
   - Avant / après : `results/fog_look/planche_brume_finale.png` (`tools/fog_look.gd --horizon`).
   - `scenes/savanna_128.tscn` utilise aussi ce fichier (avant : son propre environnement, brume
     exponentielle 0,0022, ambiance bleutée, contraste et saturation 1,12). Une seule ambiance à
     régler pour tout le test_project. Sur cette petite carte (128 m), la différence est faible :
     un peu moins de contraste, des couleurs un peu plus chaudes.
     Avant / après : `results/fps_look/fog_savanna128_compare.png`
     (`tools/shoot_fps.gd --views=high,low_far,eye_0`, nouvelle vue `high` à 60 m).
3. ~~**Les acacias peints au pinceau se chevauchent**~~ — **corrigé le 2026-11-23.**
   - Nouveau réglage par couche : Biome > couche > Advanced > « Paint Spacing » (0,85 par défaut).
     Les objets peints restent à 0,85 fois leur largeur l'un de l'autre : les couronnes se
     touchent à peine. À 0, ils peuvent se chevaucher comme avant.
   - Forêt peinte de l'audit : 209 → 128 acacias, 295k → 222k triangles dans la vue `forest`.
   - Dans une zone peinte, les arbres propres à la carte restent ceux de la carte non peinte.
     Seuls les arbres peints, espacés, s'ajoutent.
   - Reconstruction des détails de toute la carte : +3 à +14 % selon les mesures A/B (médianes
     860 → 894 ms, `tools/print_paint_blocks.gd`), soit 2 à 6 ms de plus par chunk.
   - Vérifié par `tools/check_vegetation_paint.gd` (aucune paire d'acacias peints à moins de
     3 m) et par le test de fumée (152/152).
   - Le placement non peint de la carte ne change pas.
   - Capture : `results/audit/planche_foret_espacement.png`.
4. ~~**Les rochers sont très sombres côté ombre**~~ — **corrigé le 2026-11-23.**
   - Cause : palette du modèle (~0,75) × couleur de côté du sol (brun foncé) : albédo linéaire
     d'environ 0,07, 6 à 8 fois plus sombre que le sable. Côté ombre, seule la lumière ambiante
     bleutée du ciel les éclairait : brun-violet presque noir.
   - Plugin, biome Senegal Savanna, couche Rocks : Brightness 1,4, Desaturate 0,55 (au lieu de
     0,35), Lighten 0,1 (au lieu de 0,08). Les rochers deviennent gris chaud et gardent la teinte
     du sol.
   - Jeu, `world/savanna_environment.tres` : lumière ambiante plus chaude, comme le sable qui
     renvoie la lumière. Couleur 0,86 / 0,78 / 0,68 (au lieu de 0,66 / 0,70 / 0,82), part du
     ciel 0,35 (au lieu de 0,5), énergie 1,0 (au lieu de 0,85). Les ombres de toute la scène sont
     un peu plus chaudes et plus claires.
   - Coût nul : mêmes triangles et draw calls, GPU dans le bruit de mesure.
   - Captures : `results/rock_look/planche_rochers.png` (rochers) et
     `results/rock_look/planche_scene_ambiance.png` (toute la scène). Outil :
     `tools/rock_look.gd`.

## Pistes restantes pour le mobile

Rien de cela n'est fait. Par ordre d'intérêt :

1. ~~**Option « le sol ne projette pas d'ombre »**~~ — **fait le 2026-11-23.**
   - Case Inspector > Game > « Ground Casts Shadows », activée par défaut. Elle s'applique tout
     de suite, sans reconstruction, et Annuler fonctionne.
   - Mesure en réglages téléphone, 3 paires de runs alternés, case activée → désactivée :

     | Paire | GPU activée | GPU désactivée |
     |---|---|---|
     | 1 | 3,20 ms | 2,78 ms |
     | 2 | 3,88 ms | 3,17 ms |
     | 3 | 3,28 ms | 3,13 ms |

     Soit **−0,43 ms en moyenne** (−12 %), plus bas à chaque paire.
   - Triangles : 175 k → **139 k** (−21 %) ; draw calls : 116 → 102.
   - Les collines ne font plus d'ombre sur la plaine. Les arbres, rochers et objets gardent la
     leur. Voir `results/audit/planche_ombre_sol.png`.
2. ~~**Découper l'étape « routes + rivières » du chargement**~~ — **fait le 2026-11-23.**
   - Le maillage des routes et des rivières se construit maintenant par tranches, dans le budget
     de chaque image (6 ms par défaut). Le maillage obtenu est identique au bit près, en une fois
     ou par tranches (`tools/hash_feature_mesh.gd`, avec ou sans `--sliced`).
   - Étape routes + rivières : 189 ms en une image → 18 tranches, 34 ms au pire. La tranche la
     plus longue est l'envoi au GPU des 45 k sommets de routes.
   - Deuxième à-coup trouvé : la première dispersion de détails (106 à 245 ms). Elle compilait
     les shaders de vent de l'herbe et des arbres, ~25 ms chacun. Chaque matériau a maintenant sa
     propre étape, avant les détails.
   - Résultat, 2 audits : pire étape 166–313 ms → **53–63 ms** ; pire image du chargement
     189–344 ms → **98–118 ms** ; temps total inchangé (2,6–2,9 s). Le reste de la pire image
     vient sans doute de la préparation GPU au premier affichage, hors des étapes du plugin.
   - Outils : `tools/profile_load_steps.gd` (temps de chaque étape du chargement) et
     `tools/profile_first_details.gd`.
3. ~~**Maillage des routes moins fin**~~ — **fait le 2026-11-23.**
   - La grille des routes suit maintenant celle du terrain : une maille de terrain (1 m ici)
     au lieu de 0,45 m, alignée sur ses sommets. Chaque maille est coupée selon la même
     diagonale que le terrain, et les hauteurs sont prises sur les triangles du terrain.
     Chaque triangle de route est donc posé sur un seul triangle de sol, à la même pente.
   - Routes de la carte de l'audit : 45 249 → **13 614 sommets** (−70 %). Île : 8 670 → 2 790.
   - Maillage des routes : 90 → 31 ms ; routes + rivières : 128 → 66 ms.
   - Le risque prévu est devenu un gain : **le sol ne perce plus les routes**. Avant, jusqu'à
     22 cm de sol dépassaient sur 1 à 7 % des points testés, même sur le plat (grille de 0,45 m
     à cheval sur les plis du terrain). Après, la route est partout exactement 3,5 cm au-dessus
     du sol, y compris sur une colline raide de test.
   - Le bord des routes est découpé tous les mètres environ, au lieu de tous les 0,45 m. Ça ne
     se voit pas en style low-poly. La largeur des routes est inchangée.
   - Construit d'un coup ou par tranches, le maillage reste identique.
   - Vérifié par `tools/check_road_fit.gd` (nouveau) et par le test de fumée (152/152).
   - Avant / après en dévers : `results/road_grid/planche_routes.png` (`tools/road_look.gd`).
4. **Tester sur un vrai téléphone** : export Android du test_project. C'est la seule façon
   de confirmer les estimations. **Prêt le 2026-11-23** :
   - Sur Android, la première scène est le menu `bench/phone_menu.tscn` (réglage
     `run/main_scene.android` ; l'éditeur et le PC gardent `savanna_128`) : « Explorer la
     carte » (graine 7), « Explorer une nouvelle carte » (graine au hasard), « Test de
     performance ». L'exploration (`bench/explore.tscn`) pose le joueur FPS dès que le sol
     est prêt, avec des commandes tactiles (`player/touch_controls.gd`) : joystick à
     gauche, glisser à droite pour regarder, boutons Saut / Courir / Voler / Menu, images/s
     en haut à gauche. Le test de performance est `bench/phone_bench.tscn`. Elle refait
     l'audit : même carte de savane (graine 7, une rivière), chargement image par image,
     les mêmes vues, puis la forêt d'acacias peinte. Résultats à l'écran, dans le journal
     (`adb logcat -s godot`) et dans `user://phone_bench_<ombres>_<échelle>.json`. Boutons : Relancer,
     Ombres oui / non, Échelle 3D 1 / 0,75 / 0,5.
   - Export : preset « Android » (`export_presets.cfg`, arm64 seulement, clé de debug) :
     `godot --headless --path . --export-debug "Android" builds/lte_perf_test.apk`
     puis `adb install -r builds/lte_perf_test.apk`.
   - Sur le téléphone, l'écran suit souvent la synchro verticale : « image » ne descend pas
     sous 16,7 ms à 60 Hz. La colonne **GPU** donne le vrai coût.
   - Essai sur le PC (Iris Xe) : `godot --path . res://bench/phone_bench.tscn -- --quit`.
     Sol prêt 1,55 s, tout construit 3,7 s, GPU 3,7–4,8 ms par vue, forêt 6,3 ms.
   - **Premier vrai téléphone, 2026-11-23** : TECNO CL6k (Helio G99, GPU Mali-G57 MC2, écran
     2436x1080, Android 16). Ombres oui, échelle 3D 1. Deux passages
     (`results/phone/tecno_run1_60hz.jpg`, `tecno_run2_90hz.jpg`, `tecno_shadows_scale1.json`).
     - **Rendu : 22 à 29 images/s.** GPU 33–42 ms par vue (PC : 4–5 ms), CPU de rendu 2–4 ms.
       Le téléphone est limité par le GPU, pas par le processeur.
     - **Ce n'est pas le nombre de triangles.** La vue rivière (111 000 triangles) coûte autant
       que la forêt (231 000) : ~35–40 ms. Le coût vient des pixels : 2,6 millions de pixels
       par image, avec les ombres, la brume et le ciel. Les leviers sont donc l'échelle 3D et
       les ombres. Prochain essai : les boutons Échelle 3D 0,75 / 0,5 et Ombres non.
     - **Chargement : sol prêt 5–9 s, tout construit 28–35 s** (PC : 1,6 / 3,7 s). Le travail
       du plugin n'est pas 8 fois plus lent : la pire étape fait 68–75 ms (PC 36–45 ms, ~1,7x).
       Mais chaque image coûte déjà ~40 ms de rendu et ne laisse que 6 ms au chargement. Il faut
       donc ~630 images au lieu de ~290. Piste : un budget par image plus grand pendant un
       écran de chargement, ou ne pas dessiner la 3D tant que le sol n'est pas prêt.
     - Au tout premier lancement, une image de **2,2 s** : Godot compile ses pipelines Vulkan.
       Au 2e lancement (cache prêt), la pire image tombe à 85 ms.
     - Forêt peinte (re-dispersion de toute la carte, une action d'éditeur) : 2,2–4,2 s.
   - **Série de réglages sur le même téléphone, 2026-11-23** (bouton « Série »,
     `results/phone/tecno_series.json`, moyenne des 9 vues, écran à 60 Hz) :

     | # | Ombres | Échelle 3D | GPU moyen | Images/s | Sol prêt | Tout construit |
     |---|---|---|---|---|---|---|
     | 1 | oui | 1,00 | 39,2 ms | 24 | 7,6 s | 36,4 s |
     | 2 | oui | 0,75 | 31,2 ms | 30 | 4,5 s | 24,7 s |
     | 3 | oui | 0,50 | 25,2 ms | 36 | 4,2 s | 18,9 s |
     | 4 | non | 1,00 | 31,3 ms | 28 | 4,7 s | 25,1 s |
     | 5 | oui | 1,00 | 34,3 ms | 28 | 4,2 s | 20,8 s |

     - Les passages 1 et 5 ont les mêmes réglages : ±5 ms d'écart. Le n° 1 suit la
       réinstallation (une image de 1,6 s : compilation des shaders). Le téléphone n'a pas
       ralenti en chauffant. Référence pour « ombres oui, échelle 1 » : **~37 ms**.
     - **Correction de l'analyse précédente** : les pixels ne font pas tout. Diviser leur
       nombre par 4 (échelle 0,5) ne fait gagner que ~12 ms. Donc à pleine échelle, ~15 ms
       viennent des pixels et **~20 ms sont fixes** (la géométrie dessinée deux fois, pour
       l'image et pour la carte d'ombres, et le coût de chaque passe).
     - Les ombres coûtent ~5 ms (15 %).
     - **Pour 30 images/s sur ce téléphone : échelle 3D 0,75** suffit. Pour 60 images/s, il
       faudrait aussi réduire beaucoup la géométrie (distance d'affichage des détails, herbe).
       Prochain essai à mesurer : distance des détails ×0,6, sans herbe.
     - Le chargement suit le GPU : plus l'image est rapide, plus le chargement l'est
       (36 s → 19 s à l'échelle 0,5).
   - **Série « géométrie », même téléphone** (bouton « Série géométrie »,
     `results/phone/tecno_series_geometry.json`, ombres oui) :

     | # | Échelle | Détails | GPU moyen | Images/s | Triangles | Tout construit |
     |---|---|---|---|---|---|---|
     | 1 | 1,00 | normaux | 37,3 ms | 25 | 188k | 30,1 s |
     | 2 | 1,00 | distance ×0,6 | 37,7 ms | 25 | 167k | 28,4 s |
     | 3 | 1,00 | sans herbe | 36,7 ms | 26 | 169k | 23,0 s |
     | 4 | 1,00 | **aucun détail** | 32,2 ms | 29 | 96k | **6,4 s** |
     | 5 | 0,75 | distance ×0,6 | 30,2 ms | 31 | 167k | 23,0 s |
     | 6 | 1,00 | normaux | 38,6 ms | 25 | 188k | 31,1 s |

     - **Les détails ne coûtent que ~5 ms au rendu.** Toute l'herbe, les rochers et les
       arbres ensemble = 32 → 38 ms. Réduire leur distance ou enlever l'herbe ne change
       rien de mesurable (dans le bruit de ±3 ms).
     - **Mais ils font presque tout le chargement** : 6,4 s sans détails contre ~30 s.
       C'est là qu'il faut agir pour le chargement.
     - **Il reste ~32 ms sans aucun détail** (96k triangles : sol, routes, eau, ombres). Avec
       l'échelle 0,5 : ~25 ms. Donc une grosse part ne vient ni du nombre de pixels ni des
       détails. Suspects : le coût fixe du moteur Mobile sur ce GPU d'entrée de gamme, la
       lueur (glow, plusieurs passes), la brume, le ciel, l'eau. Prochain essai à mesurer :
       ciel seul sans terrain (le plancher de Godot), puis sans lueur, sans brume.
   - **Série « environnement », même téléphone** (`results/phone/tecno_series_env.json`,
     ombres oui, échelle 1, une seule chose enlevée à chaque passage) :

     | Passage | GPU moyen | Gain |
     |---|---|---|
     | Référence (2 passages) | 38,0 / 38,5 ms | — |
     | **Ciel seul, sans terrain** | **16,6 ms** | le plancher de Godot sur ce téléphone |
     | Sans rivière | 31,3 ms | **−7 ms** |
     | Sans lueur (glow) | 32,1 ms | −6 ms |
     | Sans ciel (couleur unie, lumière sans ciel) | 31,9 ms | −6 ms |
     | Sans brume | 34,3 ms | −4 ms |

     - 16,6 ms ne viennent pas du plugin : un écran 2436x1080 avec ciel, lueur, brume et
       tonemapping. Le terrain ajoute ~21 ms par-dessus.
     - **La rivière est le plus gros poste du plugin.** Son eau (`river_water.gdshader`) lit
       l'image de l'écran (`hint_screen_texture`, avec mipmaps) pour la réfraction. Godot
       doit alors copier l'écran et en faire des versions réduites à chaque image où elle se
       voit. L'option « Mobile Water » (sans réfraction) existe, mais elle est éteinte par
       défaut.
     - La lueur, la brume et le ciel sont des choix d'ambiance du jeu
       (`world/savanna_environment.tres`), pas du plugin.
   - **Série « optimisations »** (correctifs ajoutés un par un ; le câble USB a lâché après
     5 passages sur 7, résultats lus dans le journal) :

     | # | Réglage | GPU moyen | Images/s |
     |---|---|---|---|
     | 1 | référence | 38,9 ms | 24 |
     | 2 | + eau mobile | **31,0 ms** | 30 |
     | 3 | + sans lueur | 36,8 ms | 26 |
     | 4 | + brume sans perspective aérienne | 34,8 ms | 27 |
     | 5 | + lumière sans le ciel | **26,4 ms** | 35 |

     - Deux gains sûrs, retrouvés dans deux séries différentes : **l'eau mobile (−7 à −8 ms)**
       et **l'éclairage sans le ciel (−6 à −8 ms)**. L'éclairage par le ciel fait lire à chaque
       pixel la carte de lumière du ciel (ambiante + reflets).
     - La lueur ne donne pas de gain net ici (−6 ms dans une série, +6 ms dans l'autre). Les
       écarts de ±5 ms entre deux passages identiques la cachent. À re-mesurer.
   - **Correctifs appliqués, 2026-11-23** :
     - Plugin : **sur téléphone, les rivières prennent toujours l'eau sans réfraction**
       (`MaterialFactory.phone_water`, `OS.has_feature("mobile")`). Sur ordinateur et dans
       l'éditeur, rien ne change. La case « Mobile Water » sert maintenant à voir cette eau sur
       ordinateur.
     - Jeu (`world/savanna_environment.tres`) : lumière ambiante d'une couleur fixe
       `(0.73, 0.71, 0.68)` au lieu du ciel, reflets du ciel coupés. Le ciel est toujours
       dessiné. Le rendu est presque identique (`results/fog_look/skylight_compare.png`),
       seule la bande d'horizon vue d'en haut est un peu plus grise.
     - Sauvegardes : `results/phone/bak/`. Test de fumée 152/0.
   - **Série finale sur le téléphone** (`results/phone/tecno_series_final.json`) :

     | # | Réglage | GPU moyen (pire vue) | Images/s (pire vue) | Tout construit |
     |---|---|---|---|---|
     | 1 | **nouveaux défauts** | **26,5 ms** (29,3) | **35** (32) | 23,5 s |
     | 2 | échelle 0,75 | 22,7 ms (24,4) | 40 (37) | 19,3 s |
     | 3 | sans lueur | 28,7 ms (35,8) | 32 (26) | 23,5 s |
     | 4 | sans ombres | 20,4 ms (22,7) | 40 (37) | 18,0 s |
     | 5 | nouveaux défauts | 26,9 ms (29,6) | 34 (31) | 21,2 s |

     - **Avant : 37–39 ms, 24–25 images/s. Après : 26,5–27 ms, 34–35 images/s (−30 %).**
       Toutes les vues, forêt peinte comprise, restent au-dessus de 30 images/s, à pleine
       résolution et avec les ombres. C'est le cas extrême de ce téléphone d'entrée de gamme.
     - La lueur ne coûte rien de mesurable : on la garde.
     - Marge disponible pour un jeu : échelle 3D 0,75 ou ombres coupées → ~40 images/s.
     - **60 images/s n'est pas atteignable à pleine résolution sur ce téléphone**, même sans
       terrain : le ciel seul coûte déjà 16,6 ms (une image à 60 Hz = 16,7 ms).
     - Chargement : sol prêt 4,2–4,7 s, tout construit 21–24 s (avant 30–36 s). Le premier
       lancement après installation a une image de 1,5 s (compilation des shaders).
5. ~~**Le pic d'environ 100 ms du chargement**~~ — **traité le 2026-11-23.**
   - Mesure image par image (`tools/profile_load_frames.gd`). Le pire venait du plugin : les
     détails du premier morceau (60 à 105 ms). Ils faisaient une seule fois des choses
     coûteuses :
     - compiler le matériau simple des rochers (~25 ms) : un StandardMaterial3D ne se
       compile qu'à sa première utilisation ;
     - préparer les formes des couches (~9 ms).
   - Même chose ailleurs :
     - le matériau du sol compilait au premier morceau (+28 ms) ;
     - le matériau des routes était recompilé à chaque construction (Godot libère le shader
       avec le dernier matériau qui s'en sert). Il est maintenant gardé en cache.
   - La texture de vagues générée faisait attendre l'image suivante ~25 ms. Elle est
     maintenant faite d'un coup, dans une étape à elle.
   - Chacune de ces préparations a maintenant sa propre étape, avant ce qui s'en sert.
   - Les détails de chaque morceau (25 à 40 ms d'un bloc) sont découpés par rangées dans le
     budget de 6 ms. Tranches de 7 à 10 ms ; placement identique au bit près
     (`tools/hash_details.gd`, avec ou sans `--sliced`).
   - Résultat, audit `--phone`, 2 passages :
     - pire étape du plugin 53–63 ms → **36–45 ms** (une compilation de shader, ~25–35 ms) ;
     - pire image 98–118 ms → 86–93 ms ;
     - temps total 2,6–2,9 s → 3,0–3,3 s (plus d'images, chacune plus courte).
   - La pire image restante est **la toute première image de la scène** : 68–73 ms même sans
     terrain (ciel, ombres, premiers pipelines de Godot). Ce n'est pas le plugin. Dans un jeu,
     elle tombe sous l'écran de chargement.
   - Ce qui reste au-dessus de 33 ms : chaque compilation de shader (8 en tout) et
     parfois un morceau de sol (~15 ms en moyenne, jusqu'à ~30 ms). Un vrai téléphone
     dira si ça compte.

Côté jeu, sans toucher au plugin :
- échelle de rendu 3D à 0,75 sur téléphone ;
- ~~moins de brume en hauteur~~ (fait : brume selon la distance) ;
- un peu de lumière ambiante pour déboucher les rochers.

## Détails chargés autour du joueur (streaming) — 2026-11-23

Option du plugin `LowpolyTerrainRuntime.stream_details`, activée par défaut depuis le 2026-11-24 (désactivée à l'origine). Elle est
activée dans `bench/explore.gd` (exploration au téléphone).

- **Principe : par couche, pas par chunk.** Chaque couche n'est construite que sur les chunks
  à moins de sa distance d'affichage + 16 m (`stream_margin`) du joueur. Elle est libérée
  au-delà de cette distance + 48 m (`unload_margin`, l'hystérésis). Exemples : herbe 50 m,
  buissons 120 m, acacias 300 m.
- **Pourquoi par couche.** Un découpage par chunk n'aurait rien gagné sur la savane : les
  baobabs se voient à 400 m, sur une carte de 192 m.
- **Distance mesurée au point le plus proche du chunk.** Godot mesure la distance
  d'affichage au centre de la boîte englobante, donc plus loin : une couche est toujours
  construite avant de pouvoir apparaître.
- **Collision des troncs.** Seulement à moins de 48 m (`collision_distance`). Le corps est
  rempli hors de l'arbre de scène, puis ajouté une fois complet : avec Jolt, chaque forme
  ajoutée à un corps déjà dans la scène reconstruit tout le corps.
- **Gain au passage, avec ou sans streaming.** Les couleurs du sol (~6 ms par chunk sur PC)
  étaient calculées deux fois : pour le sol, puis pour les détails. Elles sont maintenant
  gardées depuis la construction du sol : chargement complet sur PC ~1,7 s → ~1,4 s
  (`tools/check_streaming.gd`).
- **Vérifié par `tools/check_streaming.gd`** (headless). Scénario : centre, téléportation
  dans un coin, course à 10 m/s vers le coin opposé.
  - Chaque nœud de détail construit en streaming est identique à un build complet.
  - Aucune couche ne manque là où elle serait visible (0 sur ~1450 images).
  - Collision seulement près du joueur.
  - Travail du streaming par image, sur PC : médiane 0,02 ms, 99 % < 2,9 ms, max 3,8 ms.
  - Avant de garder les couleurs du sol, le début de chaque chunk prenait 11–13 ms d'un
    bloc.
- **Gain sur la carte 192 m.** Il reste petit au chargement : au centre, le premier anneau
  couvre déjà 249 nœuds sur 313. Le gain grandit avec la taille de la carte.
- **Bench.** `phone_bench` reste sans streaming : il mesure le pire cas. Sa « Série
  streaming » compare les deux.

## Coût du terrain sur PC (60 fps d'abord) — 2026-11-23

Mesuré avec `tools/profile_terrain_gpu.gd` : vraie fenêtre 1920×1080 (Iris Xe), carte
explore, 5 vues, même ciel que le jeu. Chaque variante est mesurée deux fois (A..Z puis
Z..A). Le portable est bruité : une différence de moins de ~0,3 ms n'est pas fiable.
Utiliser `--ab=` (8 manches, médiane) pour trancher.

| Poste | GPU par frame |
|---|---|
| Frame complète | 5,5 ms (≈ 180 fps) |
| Ciel seul (le jeu sans terrain) | 2,0 ms |
| **Terrain** | **3,5 ms** (~21 % d'une frame à 60 fps) |
| dont sol seul | 2,5 ms |
| dont ombres du sol (relief qui s'ombre) | 0,75–0,9 ms |
| dont ombres des détails | ~0,5 ms |
| dont toutes les couches de détails | ~1 ms (herbe sèche 0,55, buissons 0,5, le reste ≤ 0,4 chacune) |
| Toutes les ombres du soleil (réglage du jeu) | 2,4 ms |

- **Le PC tient déjà 60 fps**, avec beaucoup de marge : ~156–180 fps de moyenne dans
  `explore`.
- **Les creux sous 60 fps** viennent de pics d'horloge du GPU du portable. Ils existent
  aussi terrain caché (`profile_explore.gd --hide-terrain`) et ils sont proportionnels au
  travail. Donc moins de GPU pour le terrain veut aussi dire des creux plus petits.
- **Matériaux mats par défaut** (plugin). Le sol, les routes et les détails passent en
  Lambert sans spéculaire (`MaterialFactory._matte`, shaders du vent).
  - Rendu quasi identique.
  - A/B sur PC : −0,04 ms en médiane, donc dans le bruit. Le gain attendu est sur les GPU
    de téléphone, limités par les pixels.
- **Ombres du sol** : c'est le plus gros poste du plugin. L'option existe déjà (Jeu >
  « Ground Casts Shadows », `Meta.GROUND_SHADOWS`), mais la couper retire l'ombre des
  buttes sur elles-mêmes, ce qui se voit. Elle reste active par défaut : c'est au jeu de
  la couper s'il manque de GPU.
- **Le plus gros levier reste côté jeu.** Les ombres du soleil coûtent 2,4 ms. La version
  légère de `phone_bench` (orthogonale, atlas 1024) divise le GPU par ~2.

### Téléphone : série 60 fps (Tecno CL6k, Mali-G57 MC2, 2436×1080) — 2026-11-23

Résultats bruts : `results/phone/tecno_series_sixty.json`. APK Mobile avec matériaux mats
par défaut. Moyenne des 9 vues. La batterie était à 6 % (en charge USB) ; la référence
répétée en fin de série est cohérente : 24,0 puis 24,7 ms.

| Réglage | GPU (ms) | Frame (ms) | img/s |
|---|---|---|---|
| Référence | 24,0 | 26,5 | 37,8 |
| Sol léger (= défaut maintenant) | 24,5 | 27,0 | 37,0 |
| Sans post | 25,1 | 27,6 | 36,3 |
| Brume simple | 23,3 | 25,7 | 38,9 |
| Ombres légères | 22,7 | 25,6 | 39,1 |
| Tout léger | 22,4 | 25,6 | 39,0 |
| Tout léger + échelle 0,75 | **15,8** | 19,7 | **50,7** |
| Tout léger + lumière par sommet | 21,7 | 25,0 | 40,0 |
| Référence (répétée) | 24,7 | 27,2 | 36,8 |

- **Les réglages d'éclairage et d'effets ne changent presque rien** : 1 à 2 ms chacun, au
  plus. Même tous ensemble, on reste à ~39 img/s.
- **Le nombre de pixels domine.** L'échelle 0,75 retire 44 % des pixels et le GPU passe de
  22,4 à 15,8 ms, soit −30 %. Le Mali-G57 est limité par les pixels, comme l'annonçait la
  recherche Arm.
- **Matériaux mats** : ils ne se mesurent pas non plus sur ce téléphone (24,0 / 24,5 /
  24,7, dans le bruit). Ils ne coûtent rien à l'œil, donc on les garde.
- **Ce qui manque pour juger le plugin** : la part du terrain sur le téléphone, c'est-à-dire
  ciel seul, sol seul et complet, comme `profile_terrain_gpu.gd` sur PC. Sans elle, on ne
  sait pas si les 24 ms viennent du terrain ou du ciel et des effets du jeu.

### Téléphone : part du terrain (Tecno CL6k, série `share`) — 2026-11-23

Résultats bruts : `results/phone/tecno_series_share.json`. Moyenne des 9 vues, batterie à
5–6 %. La référence répétée est cohérente : 22,6 puis 22,4 ms.

| Réglage | GPU (ms) | img/s |
|---|---|---|
| Complet | 22,5 | 40,5 |
| Ciel seul (le jeu sans le plugin) | **16,0** | 53,7 |
| Sol seul (sans détails) | 18,9 | 47,1 |
| Sol sans ombres (`Meta.GROUND_SHADOWS`) | 21,6 | 42,0 |
| Ciel seul, sans ombres du soleil | 15,8 | 53,0 |
| Complet, sans ombres du soleil | 16,2 | 48,3 |

- **Le jeu seul prend déjà tout le budget.** Sans le terrain, le GPU est à 16 ms, alors
  qu'une image à 60 fps en laisse 16,6. Cette part vient du ciel, de la brume et des effets
  plein écran à 2436×1080 : c'est côté jeu, pas plugin. Une ancienne mesure montrait que
  retirer le ciel faisait gagner ~6 ms.
- **Le terrain coûte ~6,5 ms**, dont ~2,9 ms pour le sol et ~3,6 ms pour les détails.
- **Presque tout ce coût vient des ombres du soleil.** Sans elles, le terrain ne coûte que
  ~0,4 ms (16,2 contre 15,8). Ce qui coûte, c'est le terrain dans l'ombre du soleil : il
  est dessiné dans la carte d'ombres et filtré sur chaque pixel. Ombres du sol seules :
  ~1 ms.
- **Pistes plugin** :
  - mesurer sur le téléphone les ombres des détails seules (acacias, baobabs, buissons) ;
  - séparer le coût de projection de celui de réception.
- **Pistes jeu** :
  - le ciel et les effets, qui prennent les 16 ms ;
  - la qualité de filtrage des ombres ;
  - l'échelle de rendu.

### Ombre du sol par les faces arrière (plugin) — 2026-11-24

- **Constat sur le téléphone** : le terrain sans ombres du soleil coûte ~0,4 ms, contre
  ~6,5 ms avec. Presque tout le coût du terrain passe donc par les ombres.
- **Recherche** (doc Godot, guides Arm Mali) :
  - les ombres sont le poste le plus cher sur mobile ;
  - la passe d'ombre n'a besoin que des positions.
- **Essai 1 : mesh d'ombre soudé** (`ArrayMesh.shadow_mesh`, positions seules) : 5,6×
  moins de sommets, mais aucun gain sur PC, la passe d'ombre n'y est pas limitée par les
  sommets. Retiré.
- **Essai 2 : ombre par les faces arrière (retenu).** Chaque chunk ne projette plus
  d'ombre lui-même. Un enfant `_GroundShadow`, en ombre seule, contient les mêmes triangles
  à l'envers, positions seules et soudées, 10 cm sous le sol. Ce qui change :
  - seules les pentes tournées à l'opposé du soleil vont dans la carte d'ombres ;
  - le sol éclairé, c'est-à-dire presque toute la carte, n'y est plus dessiné ;
  - les buttes gardent la même ombre ;
  - pas besoin de connaître la direction du soleil ;
  - les 10 cm évitent un moucheté sur les faces presque rasantes, vu en zoom puis corrigé.
- **Mesure PC** (1080p, A/B 8 manches) :
  - ancienne ombre du sol : +0,75 ms ;
  - nouvelle : −0,02 ms par rapport à « sol sans ombres ».
  - L'ombre du sol ne coûte donc plus rien de mesurable.
- **Rendu** : même ombre des buttes. La différence de pixels est au niveau du bruit dû au
  vent sur l'herbe.
- **Coût au chargement** : ~1,3 ms par chunk sur PC.
- **Tests** : nouveau `tools/check_ground_shadow.gd` (nouvelle carte, option on/off,
  ancienne scène sauvegardée migrée au chargement), plus tous les autres. Smoke 152/0.
- **Téléphone** : à mesurer avec la série « ombres du terrain » (`casters`).
  `front_shadows` remet l'ancienne méthode pour comparer.

### Ombres des arbres (plugin) — 2026-11-24 : rien à gagner sur PC

Seules deux couches projettent une ombre : les acacias (249 triangles) et les baobabs
(411 triangles). Le soleil du jeu a 2 cascades et projette jusqu'à 50 m.

**Mesure PC** (1080p, A/B 8 manches, en médiane, comparé au rendu complet) :

| Variante | Écart |
|---|---|
| sans ombres de détails | −0,23 à −0,26 ms (3 séries) |
| vent coupé dans la passe d'ombre (`IN_SHADOW_PASS`) | −0,02 ms |
| jumeau d'ombre statique, matériau simple partagé | −0,04 / +0,01 / −0,04 ms |
| jumeau d'ombre avec le vent | +0,14 ms (le nœud en plus coûte) |
| jumeau soudé, positions seules (~5× moins de sommets) | −0,04 ms |
| un seul MultiMesh d'ombre par couche pour toute la carte | +0,09 ms (soudé : +0,01) |
| ombres limitées à 60 m | −0,05 ms |

**Conclusion.** Les ombres des arbres coûtent ~0,25 ms sur PC, et ni le vent, ni les
sommets, ni le nombre d'appels de dessin, ni la distance n'y changent rien. Ce qui reste,
c'est le remplissage de la carte d'ombres par les houppiers, qui dépend des réglages du
soleil du jeu (résolution, cascades, distance). Le plugin ne change donc rien. L'option
« Cast Shadows » par couche existe déjà pour un jeu qui veut s'en passer.

**Téléphone** : la série `casters` mesure `detail_shadows: false`. Si le Mali y montre un
coût nettement plus grand que sur PC, il faudra refaire l'essai du jumeau soudé
(conservé dans `results/phone/bak/profile_terrain_gpu_tree_experiments.gd`). Sur un GPU
à tuiles, les sommets de la passe d'ombre coûtent plus cher.

### Herbe (plugin) — 2026-11-24 : rien de gratuit sur PC, série téléphone prête

Sur PC (moteur Mobile, comme le téléphone), en 1080p, en médiane sur 8 manches A/B
comparées au rendu complet :

| Variante | Écart |
|---|---|
| sans Dry Grass | −0,19 à −0,27 ms (5 séries) |
| sans Green Grass, Waterhole Reeds ou Laterite Gravel | −0,01 à −0,02 ms |
| moitié des touffes (`visible_instance_count`) | −0,08 à −0,20 ms |
| herbe sans vent | −0,02 / −0,15 ms (série bruitée) |
| touffes qui rétrécissent avec la distance (40 %→100 % de la distance d'affichage) | −0,02 / −0,03 ms |
| herbe découpée en 2×2 ou 4×4 MultiMesh par chunk | +0,03 / +0,08 ms |

Les meshes de touffes ne partagent aucun sommet (21 sommets, tous différents). Les indexer
ne servirait donc à rien.

**Conclusion PC** : l'herbe sèche coûte ~0,2 ms, à peu près en proportion du nombre de
touffes. Le seul levier qui marche, c'est d'en dessiner moins, et c'est déjà le réglage
« Density » de la couche.

**Hypothèse téléphone** : sur le Tecno, les détails coûtent 3,6 ms avec les ombres du
soleil et presque rien sans. Sur un GPU à tuiles, les petits triangles lointains et le
filtrage d'ombre de chaque pixel d'herbe peuvent coûter bien plus que sur PC.

**Série `herbe` (`grass`)** ajoutée au banc :
- référence ;
- sans herbe ;
- moitié de l'herbe ;
- herbe éclaircie au loin ;
- détails sans ombre reçue ;
- sans ombres du soleil ;
- référence.

Elle tourne sur PC (3,0–3,3 ms partout, dans le bruit) et l'APK est reconstruit. Si
« éclaircie au loin » ou « sans ombre reçue » gagne nettement sur le téléphone, on en fera
une option du plugin. Les essais PC sont conservés dans
`results/phone/bak/profile_terrain_gpu_grass_experiments.gd`.

### Téléphone : ombres du terrain et herbe (Tecno, séries `casters` et `grass`) — 2026-11-24

Batterie à 68 %, en charge USB. Moyenne des 9 vues. Résultats bruts :
`results/phone/tecno_series_casters.json` et `results/phone/tecno_series_grass.json`.

| Série `casters` | GPU (ms) |
|---|---|
| Référence (faces arrière) | 22,8 / 23,6 en fin de série |
| Ancienne ombre du sol (faces avant) | **24,7** |
| Détails sans ombres | 23,5 |
| Sol sans ombres | 23,8 |
| Rien ne projette d'ombre | 23,9 |
| Sans ombres du soleil | 17,6 |

| Série `grass` | GPU (ms) |
|---|---|
| Référence | 23,5 / 23,9 en fin de série |
| Sans herbe | **22,3** |
| Moitié de l'herbe | 23,1 |
| Herbe éclaircie au loin | 23,5 |
| Détails sans ombre reçue | 23,3 |
| Sans ombres du soleil | 18,0 |

- **Ombre du sol par les faces arrière : −1,5 ms sur le téléphone**, confirmé (24,7 →
  ~23,2).
- **Projeter les ombres ne coûte plus rien.** Quand plus rien du terrain ne projette, on
  est à 23,9 ms, dans le bruit de la référence. Les ombres des arbres ne se mesurent pas non
  plus.
- **Il reste ~6 ms quand les ombres du soleil sont actives.** C'est le coût de *recevoir*
  l'ombre sur les pixels du terrain, surtout le sol, puisque les détails sans ombre reçue ne
  gagnent que ~0,4 ms. Ce n'est pas la carte d'ombres elle-même : avec « ombres légères »
  (1 cascade, 1024 px), on ne gagnait que ~1,3 ms. Ce coût dépend des réglages d'ombre du
  jeu et du moteur, qu'un matériau ne peut pas contourner. Une hypothèse, non vérifiée : le
  shader avec ombres est plus lourd et occupe moins bien le Mali.
- **L'herbe coûte ~1,4 ms**, en proportion du nombre de touffes (la moitié : −0,6 ms).
  L'éclaircir au loin ne gagne rien sur le téléphone non plus. Le levier reste donc la
  densité de la couche, un choix visuel.
- **Conclusion plugin** :
  - les postes que le plugin contrôle sont au plancher ;
  - le seul levier restant est visuel (densité ou distance de l'herbe dans le preset) ;
  - les ~6 ms d'ombre reçue relèvent de la configuration des ombres du jeu.
