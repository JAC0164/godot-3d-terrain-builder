# Sol low poly en vue FPS : diagnostic et recherche (2026-11-23)

## Ce qu'on voit
La planche est dans `results/fps_look/planche_sol_fps.png`. Les images viennent de `tools/shoot_fps.gd`, qui prend des vues à 1,7 m du sol. Les essais sont faits en mémoire : la scène n'est pas modifiée.

| Vue | Réglage | Ce qu'on voit |
|---|---|---|
| 1 | Ta scène : Smooth Ground ON, sol plat | Une nappe jaune floue avec de fausses bosses molles. C'est l'effet « sol buggé ». |
| 2 | Smooth Ground OFF | Des facettes nettes, le vrai look low poly. On voit aussi la grille régulière des triangles. |
| 3 | OFF + bosses de 30 cm | Les facettes prennent la lumière de façons différentes, le sol vit. |
| 4 | Vue 3 + variation de couleur plus calme | La plus naturelle. |

## Pourquoi le sol actuel fait « buggé »
- **Le sol est parfaitement plat.** La mesure donne : toutes les hauteurs à 0, 28 222 cases, 2 sols.
- **Les « bosses » sont des taches de couleur.** Elles viennent du mélange bruité des 2 sols (`blend_noise` 0,75) et de la variation de teinte (`variation` 0,09). Smooth Ground les lisse. Sur un sol plat, l'œil lit ces taches floues comme un relief mou qui ne correspond à rien.
- **La source citée le résume ainsi :** « choisir facettes OU lissé, le mélange des deux a l'air faux ».

## Ce que fait la profession
Synthèse de recherche web ; les sources sont listées en bas.

1. **Casser la grille.**
   - Un découpage identique de toutes les cases trahit la grille. C'est la cause n° 1 de l'effet « faux » (McGuire, SIGGRAPH 2004).
   - Solutions : alterner ou choisir la diagonale de chaque case, et décaler les sommets au hasard de 0,25 à 0,35 m à l'horizontale (outil Unity « Low Poly Terrain » de Jean Simonet : XZ Offset).
   - Ce décalage doit être calculé d'après la position dans le monde, pour que les morceaux se raccordent, et la collision, les détails et les routes doivent le suivre.
2. **S'engager pour les facettes nettes**, avec une couleur par face légèrement variée (±3 à 6 % de luminosité). Pas de dégradés le long des diagonales.
3. **Petit relief.**
   - Un léger décalage vertical (environ ±5 cm) évite les grands plans morts.
   - Des bosses douces de 0,2 à 0,5 m sur 8 à 20 m complètent.
   - Le sol « plat et vide » est la plainte n° 1 sur les cartes low poly.
4. **Ambiance (côté jeu).**
   - Brouillard en profondeur avec perspective aérienne, et un tonemap Filmic, ACES ou AgX plutôt que Linear.
   - Soleil plus bas (25 à 40°) avec ombres, pour que les facettes contrastent.
   - Couleurs un peu moins saturées.
   - Sur Mobile, pas de SSAO : garder l'AO précalculée.
5. **Couvrir le sol près de la caméra** de touffes d'herbe et de cailloux, denses dans les 10 à 20 premiers mètres. Ici, avec le pinceau Végétation.
6. **Scintillement.** Mettre la rugosité du sol vers 1. Utiliser TAA ou FSR2 ; le MSAA ne lisse que les bords.

## Ce que le plugin fait déjà
- **Facettes nettes :** Smooth Ground OFF (couleur et normale par triangle).
- **Variation par face :** le réglage `variation` du biome.
- **Ambiance :** la scène d'exemple `world/savanna_sky.tscn` a du brouillard, un tonemap et de la lueur.

Il manque :
- les facettes par défaut ;
- le petit relief ;
- les sommets décalés (la diagonale est la même dans toutes les cases).

## Propositions
| # | Quoi | Où | Taille |
|---|---|---|---|
| 1 | Facettes par défaut : nouveau terrain = Smooth Ground OFF. Pour ta scène : Inspector > Look > décocher Smooth Ground. | plugin | petit |
| 2 | Petit relief : un réglage « Ground Bumps » (hauteur des bosses, ex. 0,3 m), écrit dans les hauteurs (donnée). La collision, les détails et les routes suivent d'eux-mêmes. | plugin | moyen |
| 3 | Ambiance FPS : brouillard en profondeur, soleil plus bas, couleurs un peu moins vives dans `world/savanna_sky.tscn`. | test_project (jeu) | petit |
| 4 | Casser la grille : sommets décalés de ~0,3 m et diagonale variée, avec la collision, les détails et les routes qui suivent. C'est le vrai « look low poly », mais le plus gros chantier. | plugin | gros |

## Sources
- McGuire, « A Heightfield on an Isometric Grid », SIGGRAPH 2004 : https://history.siggraph.org/wp-content/uploads/2022/12/2004-Talks-Mcguire_A-Heightfield-on-an-Isometric-Grid.pdf
- Jean Simonet, Low Poly Terrain (XZ / Y Offset) : https://jeansimonet.net/low-poly-terrain
- Poisson + Delaunay pour un look low poly : https://arxiv.org/abs/2505.09350 , https://msagca.github.io/procedurally-generated-maps-for-mobas
- Couleurs par face et interpolation : https://discourse.threejs.org/t/how-to-disable-color-interpolation-when-using-vertexcolors/29006
- Godot Environment (brouillard, tonemap) : https://docs.godotengine.org/en/stable/classes/class_environment.html , https://docs.godotengine.org/en/stable/tutorials/3d/environment_and_post_processing.html
- Godot anticrénelage : https://docs.godotengine.org/en/stable/tutorials/3d/3d_antialiasing.html
- Sol « plat et vide » : https://devforum.roblox.com/t/why-does-my-simple-terrain-look-so-ugly/2172088
- Couverture du sol (herbe proche) : https://hexaquo.at/pages/grass-rendering-series-part-4-level-of-detail-tricks-for-infinite-plains-of-grass-in-godot/

## Fait (2026-11-23) : propositions 1, 2 et 3
- **1. Facettes par défaut :** « New Terrain » crée un sol à facettes (Smooth Ground OFF). Les anciennes scènes ne changent pas.
- **2. Ground Bumps :** réglage dans Inspector > Look (0,3 m sur un nouveau terrain, 0 = plat).
  - Code : `core/ground_bumps.gd`. Les bosses sont écrites dans les hauteurs : collision, détails, routes et rivières suivent.
  - Changer la valeur ne touche que les bosses, jamais le relief peint. Ctrl+Z annule.
  - Les nouvelles cases (terrain qui grandit), Generate Map et l'import d'image reçoivent les mêmes bosses.
  - 5 vérifications ajoutées au test de fumée : 139 réussies, 0 échec.
- **3. Ambiance :** dans `world/savanna_environment.tres`, brouillard 0,0022 → 0,0045, saturation 1,12 → 1,0 et contraste 1,12 → 1,06. Dans `world/savanna_sky.tscn`, le soleil passe de 32° à 24° au-dessus de l'horizon (même direction).
- **Captures :** planche `results/fps_look/planche_avant_apres.png` (`tools/shoot_fps.gd`, nouveaux réglages `--env`, `--fog`, `--saturation`, `--contrast` et `--sun`).
- **Ta scène `scenes/savanna_128.tscn` :** elle a son propre WorldEnvironment et son propre Sun intégrés. Elle ne profite donc de la nouvelle ambiance que si on remplace ces 2 nœuds par une instance de `world/savanna_sky.tscn`.

## Suite : les facettes ne plaisent pas → texture (2026-11-23)
- **Recherche :** ce qui manque à hauteur des yeux, c'est une texture de détail fine qui donne l'échelle. Les jeux stylisés gardent une couleur de base douce et ajoutent un grain qui se répète, qui s'efface au loin, avec de petits reliefs dans l'éclairage.
  - [Detail textures](https://gamedeveloper.com/programming/detail-textures)
  - [Unity Terrain Solutions](https://docs.unity3d.com/Packages/com.unity.shadergraph@17.4/manual/Shader-Graph-Sample-Terrain-Solutions.html)
  - [BeamNG, détail proche ou lointain](https://docs.beamng.com/modding/levels/level_creation/section2/)
  - [Techniques anti-répétition](https://masonstevenson-dev.github.io/posts/2024-09-20-LandscapeTilingTechniques)
  - [Stochastic texturing](https://unity.com/blog/engine-platform/procedural-stochastic-texturing-in-unity)
- **Essai :** `world/looks/ground_detail.gdshader` + `ground_detail.tres`, créés par `tools/make_looks.gd`.
  - Il garde les couleurs du sol et ajoute un grain de terre sur ~1,6 m (2 échelles tournées l'une par rapport à l'autre), de grandes taches douces (~18 m) et de petits reliefs dans l'éclairage. Le grain s'efface de 20 à 70 m.
  - Une seule texture de bruit, sans UV. Il se branche dans Inspector > Look > Ground Material.
- **Planche :** `results/fps_look/planche_texture_test.png`.
  - Ta scène actuelle (facettes et bosses) est comparée à une version lisse, avec le grain et les bosses.
  - Les colonnes 2 et 3 utilisent aussi la nouvelle ambiance.
- **Décision :** le plugin reste neutre. La texture du sol, c'est le matériau du jeu (Look > Ground Material).
  - « New Terrain » garde Smooth Ground ON, la valeur par défaut. La proposition 1 est annulée.
  - Les Ground Bumps restent à 0,3 m.
  - Le grain reste un exemple dans `world/looks/`.
