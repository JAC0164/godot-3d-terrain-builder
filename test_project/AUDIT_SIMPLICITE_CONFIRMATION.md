# Lowpoly Terrain Editor — Audit UX/UI (confirmation)

**Portée**
- Plugin `lowpoly_terrain_editor` dans Godot 4.7.2.
- Éditeur réel ouvert hors écran : 1920×1051, échelle d'éditeur 1.25, police principale 17 px.
- Date : 23 novembre 2026.
- Parcours d'un débutant, en 5 étapes :
  1. plugin activé dans une scène vide ;
  2. « New Terrain » ;
  3. « Generate Map » sans recette, deux fois ;
  4. les 9 sections de l'Inspecteur, ouvertes une par une avec leurs sous-sections ;
  5. une carte savane générée, puis un réglage modifié dans le biome.

**But** : confirmer ou corriger le premier audit (`AUDIT_SIMPLICITE.md`), avec une mesure ou une citation exacte pour chaque point.

**Méthode adaptée.** Les sondes de l'audit web (DOM, contraste CSS, focus clavier) ne s'appliquent pas à un plugin Godot. À la place, un plugin de capture (`lte_test/addons/lte_uxaudit/uxaudit.gd`) a relevé, pour chaque contrôle visible de la barre d'outils et de l'Inspecteur :
- la classe, le texte et l'info-bulle ;
- la taille à l'écran ;
- la taille et la couleur de police lues dans le thème ;
- la largeur réelle du texte.

Il a aussi relevé la couleur de fond (un pixel de l'image rendue). Les contrastes sont calculés avec la formule WCAG sur ces couleurs. Ils ne sont pas estimés sur une capture.

**Référence.** Le projet n'a pas de charte UX propre. Les critères appliqués sont :
- l'accessibilité : WCAG 2.2, appliquée par analogie, car elle vise le web ;
- l'utilisabilité : les heuristiques de Nielsen ;
- la gravité et l'ordre de correction : les conventions de cet audit.

Captures, mesures brutes et textes : `results/ux_audit/confirmation/`.

## Résumé

| Gravité | Nombre |
|---|---|
| Critique | 1 |
| Majeur | 11 |
| Accessibilité | 1 |
| Note | 2 |

**Le premier audit est confirmé sur le fond**, avec trois corrections et trois nouveaux points.

**Corrections :**
- **« 115 réglages »** → il y en a **94 réglages + 14 boutons = 108 contrôles**. Le premier comptage incluait des sous-éléments des champs. L'ordre de grandeur ne change pas.
- **A1, « 17 icônes grisées sauf une »** → **12 éléments sur 17 sont grisés, 5 restent actifs** : New Terrain, Taille, Force, Undo, Redo.
- **A2, « aucune indication »** → le message d'aide **existe dans le code**, mais une condition le masque justement dans ce cas. La correction tient en une ligne (constat 04).

**Nouveaux points :**
- une info-bulle donne une limite fausse (« x4 » au lieu de x25) ;
- les textes d'aide ont une taille fixe de 12 px qui ignore l'échelle de l'éditeur ;
- deux textes sont coupés, dont le seul message affiché quand il n'y a pas de terrain.

**Ce qui marche :**
- tous les contrastes passent le niveau AA (6,49:1 à 10,65:1) ;
- toutes les cibles font au moins 40×41 px ;
- 94 réglages sur 94 ont une info-bulle ;
- une carte générée apparaît cadrée, avec un résumé dans la barre.

Le problème n'est pas la qualité de ce qui existe, c'est la **quantité visible d'un coup** et les **doublons**.

## Constats

### 01 · [Critique] · Inspecteur > Map Generator & Runtime
**« Generate Map » sans recette ne fait rien de visible.**

Le bouton principal d'un nouveau terrain a l'air cassé. Le seul retour est un avertissement dans le panneau Output, qui est replié. Un débutant clique, rien ne bouge, et il abandonne le générateur. Le générateur Pixel Map fait la même chose sans image.

```
GENERATE_NO_RECIPE attempt 1: cells 0 -> 0, resolution 48 -> 48, status '', toasts []
GENERATE_NO_RECIPE attempt 2: cells 0 -> 0, resolution 48 -> 48, status '', toasts []
plugin.gd:664  push_warning("…assign a Map Recipe before generating (e.g. generation/presets/senegal_savanna_map.tres).")
plugin.gd:806  push_warning("…assign a Source Pixel Map before generating.")
capture : confirmation/02_generate_no_recipe_0.png (vue 3D vide, barre d'état vide)
```

**Correction :** sans recette, utiliser un préréglage par défaut. À défaut, griser le bouton et afficher la raison dans la barre d'état.

### 02 · [Majeur] · Biome > Baked Shading ↔ Rendering
**Modifier l'ombrage dans le biome ne change pas le terrain.**

L'utilisateur règle le biome, rien ne bouge, et il conclut que le réglage ne sert à rien. La valeur qui compte est une copie stockée sur le terrain. Elle n'est mise à jour que par un bouton séparé, « Re-apply Biome Shading ».

```
BIOME_EDIT biome.ambient_occlusion -> 1.0 ; terrain _lte_shade_ao 0.45 -> 0.45 ; chunk colours changed: false   (après 1,2 s)
Bouton : "Re-apply Biome Shading" — "Copy the biome's Baked Shading values to this terrain's Rendering settings."
```

**Correction :** le biome devient la seule source de l'aspect (étape 4 du plan). En attendant, appliquer automatiquement à chaque modification du biome.

### 03 · [Majeur] · Inspecteur > Map Generator & Runtime
**Pour générer une carte, il faut connaître un chemin de fichier.**

Le geste le plus utile du plugin dépend d'un dossier à trouver dans l'arborescence. Le champ affiche seulement `<empty>`.

```
"Presets: addons/lowpoly_terrain_editor/generation/presets/."
Map Recipe : <empty>   (capture 02, Inspecteur)
```

**Correction :** une liste des préréglages (Savane, Tempéré…) à la place du sélecteur de fichier, avec « Autre… » pour une recette perso.

### 04 · [Majeur] · Vue 3D après « New Terrain »
**L'aide « terrain vide » existe, mais elle est masquée exactement quand elle sert.**

Juste après « New Terrain », la vue est vide et l'outil Paint est actif. La condition qui affiche l'aide exclut justement Paint : le message n'apparaît jamais à ce moment-là.

```
NEW TERRAIN 224 ms, active tool 1 (PAINT), status ''      CELLS active: 0
plugin.gd:315  elif not (...CELL_ACTIVE...).has(1) and _tool != ToolMode.Mode.PAINT:
plugin.gd:316      _toolbar.set_status("Empty terrain: pick Paint and drag in the 3D view, or Generate Map (Inspector)")
```

**Correction :** retirer `and _tool != PAINT` et reformuler (« Glisser pour poser du sol · ou Générer une carte »). Idéalement, afficher le message dans la vue 3D, pas dans une zone de 162 px (voir 09).

### 05 · [Majeur] · Barre d'outils > Vegetation
**L'info-bulle annonce « x4 », le code va jusqu'à x25.**

L'utilisateur ne s'attend pas à une forêt dense et peut croire à un bug. Le texte date d'avant le pinceau permissif. La même valeur périmée se trouve à trois endroits.

```
terrain_toolbar.gd:46  "Drag for more trees, grass, rocks... (up to x4 the biome density)."
detail_layer.gd:102    "Painted cells go from none (Ctrl) to x4 with clumps filled in."
terrain_meta.gd:37     "255 ~ x4"
detail_scatter.gd:50-51  PAINT_MIN_MULTIPLIER := 4.0 / PAINT_MAX_MULTIPLIER := 25.0
```

**Correction :** remplacer par « jusqu'à x4 (herbe) et x25 (arbres rares) » ou par « plus dense ». Trois lignes à changer.

### 06 · [Majeur] · Inspecteur du terrain, toutes sections
**108 contrôles et 22 paragraphes d'aide sur un seul panneau.**

Trop de choix d'un coup (loi de Hick) : rien n'indique ce qui est essentiel et ce qui sert au dépannage. Deux sections, Terrain Features et Pixel Map, portent à elles seules 52 réglages sur 94.

```
section                  réglages  boutons  paragraphes  caractères
Map Generator & Runtime      4        2         3          519
Biome & Details              5        8         3          555
Terrain Features            28        2         5          712
Manual Brush Settings        6        0         1          152
Canvas                       3        1         1           74
Pixel Map Generator         24        1         5          476
Collisions                   4        0         0            0
Geometry Tuning              6        0         1          155
Rendering                   14        0         3          550
TOTAL                       94       14        22        3 193
```

Exemples de réglages de dépannage visibles d'emblée :
- « Double-sided Faces » : *« If some generated or painted faces are unexpectedly invisible, turn it ON for troubleshooting. »* ;
- Geometry Tuning : Top / Cliff / Feature Y Offset.

**Correction :** quatre sections (Carte, Aspect, Routes-rivières-mares, Jeu), plus une section « Avancé » repliée. Les paragraphes deviennent des info-bulles (étape 2 du plan).

### 07 · [Majeur] · Couleur du sol réglée à 4 endroits
**Une même chose, « quelle couleur je peins », se règle à quatre endroits.**

Les quatre endroits :
1. les boutons de style du biome ;
2. Manual Brush Settings (6 réglages) ;
3. Pixel Map > Material Settings (3 × 6 réglages) ;
4. la case « Use Manual Brush Settings » qui bascule entre les deux derniers.

Le même clic est décrit de deux façons différentes. De plus, ce clic ne sélectionne pas l'outil Paint et le bouton ne reste pas marqué comme choisi : seule la barre d'état affiche « Brush: … ».

```
Label  : "Ground styles (click to load into the Manual Brush):"
Bouton : "Paint with this ground style."
plugin.gd:774-783  use_ground_style() règle les couleurs du pinceau, _set_status("Brush: %s"), pas de changement d'outil
Pixel Map : "Uncheck 'Use Manual Brush Settings' to assign textures and colors individually."
```

**Correction :** une liste « Sol [Latérite ▾] » à côté de l'outil Paint, comme la liste de végétation. Manual Brush et les couleurs de Pixel Map passent dans « Avancé ».

### 08 · [Majeur] · Couleurs des mares en double
**Les couleurs des mares se règlent dans le biome et dans Terrain Features.**

C'est le même piège que le constat 02 : une copie à appliquer à la main.

```
Terrain Features > Dried Waterholes : "Clay Color", "Crack Color"
"These settings apply to new waterholes." + bouton "Apply to Existing Waterholes"
```

Non re-mesuré dans cette passe : le premier audit l'avait vérifié dans le code. La passe actuelle confirme seulement les textes.

**Correction :** même chose que pour le constat 02.

### 09 · [Majeur] · Barre d'outils, aucun terrain
**Le seul guide affiché sans terrain est coupé à 47 %.**

Le message qui dit quoi faire se lit « No terrain: sele… ». Autre texte coupé : « Everything at runtime » apparaît comme « Every ».

```
Label 'No terrain: select one, or click New Terrain'   texte 342 px dans une boîte de 162 px
OptionButton 'Everything at runtime'                    texte 172 px dans une boîte de 90 px
captures : confirmation/toolbar_00_no_terrain.png, 02_generate_no_recipe_0.png (« Every »)
```

**Correction :**
- sans terrain, afficher le bouton « ＋ Terrain » avec son texte, et rien d'autre ;
- libellés courts dans la liste « Runtime Build », ou liste en pleine largeur.

### 10 · [Majeur] · Barre d'outils
**11 outils sont des icônes sans texte, et 5 éléments restent actifs sans terrain.**

- Il faut survoler chaque icône pour savoir ce qu'elle fait. « Paint » veut dire *poser du sol*, ce que l'icône pinceau ne dit pas.
- Sans terrain, Undo, Redo, Taille et Force restent actifs alors qu'ils n'agissent sur rien.

```
11 × Button '' 40x41 (texte vide, nom seulement dans l'info-bulle)
sans terrain : disabled = Paint, Erase, Raise, Lower, Flatten, Smooth, Road, River, Waterhole, Vegetation, liste, Level (12/17)
               actifs   = New Terrain, Size, Strength, Undo (terrain), Redo (terrain) (5/17)
Paint : "Add ground with the current ground style (Inspector > Biome > ground styles, or Manual Brush)."
```

**Correction :**
- « ＋ Terrain » avec un mot ;
- fusionner les outils (Sol, Relief) : de 11 à 7 outils ;
- retirer Undo / Redo (constat 11).

### 11 · [Majeur] · Barre d'outils > Undo / Redo / disquette
**Deux boutons font ce que fait déjà Ctrl+Z, et l'icône disquette n'enregistre pas la scène.**

La disquette évoque Ctrl+S. En réalité, elle ouvre un export JSON que le plugin ne relit jamais.

```
Undo (terrain) / Redo (terrain) → même historique que Ctrl+Z (_get_active_undo_history)
MenuButton "Level: save, duplicate or delete the selected terrain level."
Meta.LEVEL_PATH lu seulement par save (plugin.gd:835, 857) et delete (877) ; aucun JSON.parse dans le plugin
```

**Correction :** retirer Undo / Redo. Pour le menu Level, retrait ou passage en « Avancé », selon ta réponse à la question 2.

### 12 · [Majeur] · Textes visibles de l'Inspecteur
**Une dizaine de termes de programmeur sont visibles par défaut.**

Celui qui dessine un terrain n'a pas à connaître le vocabulaire du moteur pour comprendre un réglage.

```
"Each layer is one MultiMesh per chunk (one draw call)"           (Biome & Details)
"Rebuilding is done by the _LowpolyTerrainRuntime child"           (Runtime Build)
"Runtime node: _LowpolyTerrainRuntime."                            (Map Generator)
"Vertical road offset used to avoid z-fighting."                   (Road Y Offset)
"Disable back-face culling."                                       (Double-sided Faces)
"Create a local NoiseTexture2D + FastNoiseLite normal map"         (Rivers)
"0 also skips the screen copy (cheaper)."                          (Refraction)
"COLOR = style colour x baked shading" / "(COLOR in a shader)"     (Custom Materials)
Noms : "Canvas", "Runtime Build", "Style Blend (cells)", "Top Normal Up Bias", "Feature Y Offset", "Indented Ground"
```

**Correction :**
- décrire l'effet, pas la technique (« Décalage de la route » → « évite le scintillement ») ;
- les détails techniques passent dans `ARCHITECTURE.md` ;
- exception : les matériaux perso. Ils visent un programmeur de shader, donc « COLOR » y reste justifié, mais dans « Avancé ».

### 13 · [Majeur] · Noms qui changent d'un écran à l'autre
**Un même concept porte plusieurs noms.**

Le nouvel utilisateur ne sait pas que ces mots désignent la même chose.

```
sol peint   : "Paint" / "ground style" / "Manual Brush" / "Material Settings" / "newly painted cells"
mare        : outil "Dried waterhole" / aide "pick the Waterhole tool" / section "Dried Waterholes"
relief      : outils "Raise" / "Lower" ; Pixel Map "Raised Ground" / "Indented Ground" / "Height / Dent Smoothness" ; recette "lowlands"
orthographe : "Clay Color" (libellé) / "Colour of the mud plates." (info-bulle) ; 13 lignes de texte en "colour", 18 en "color"
```

**Correction :**
- un mot par concept : Sol / style de sol, Relief (monter / creuser), Mare ;
- une seule orthographe (« color », comme Godot).

### 14 · [Accessibilité] · Textes d'aide et titres de section
**Les tailles de police sont fixes (12 px et 14 px) et ne suivent pas l'échelle de l'éditeur.**

Le reste de l'éditeur est à 17 px à l'échelle 1.25. Si l'utilisateur agrandit l'éditeur (paramètre Display Scale, l'équivalent du zoom), ces textes restent à 12 et 14 px. Ce sont pourtant les 22 paragraphes censés expliquer le plugin.

```
EDITOR scale 1.25, main font size 17
Label (aide)      font_size 12   n = 44
titres de section font_size 14   n = 18
autres textes     font_size 17   n = 271
```

Critère : **WCAG 2.2 SC 1.4.4 Resize Text**. Le texte doit pouvoir être agrandi sans perte. Ici, une partie du texte ne suit pas l'agrandissement prévu par l'outil. Le critère vise le web : il est appliqué ici par analogie.

**Correction :** multiplier les tailles par `EditorInterface.get_editor_scale()`, ou utiliser des variations de thème (comme `HelpLabel`) plutôt que des tailles en dur. Si les paragraphes deviennent des info-bulles (constat 06), le point disparaît en partie.

### 15 · [Note] · Textes de détail

Six défauts mineurs de texte :
1. **Pluriel bricolé** : `"6 waterhole(s) on this terrain."` au lieu de « 1 mare » / « 6 mares ».
2. **Casse mélangée sur les cases à cocher** :
   - 4 en Title Case : « Enable Details », « Smooth Ground », « Double-sided Faces », « Use Manual Brush Settings » ;
   - 4 en casse de phrase : « Generate walkable collision », « Road collision », « Water surface collision », « Auto-expand while painting ».
3. **Pixel Map** : `"Upload a pixel art image"`. Il n'y a pas d'envoi : on assigne une texture.
4. **Pixel Map** : `"Recommended size: 1x1 to 256x256."`. 1×1 n'est pas une taille recommandable.
5. **Aide « Rivers »** : elle parle de la texture de normales (`"Leave Water Normal Texture empty…"`) et pas de la façon de dessiner une rivière.
6. **Aide « Terrain Features »** : `"Roads and rivers are special terrain features…"`, sans les mares, qui sont pourtant dans la même section.

### 16 · [Note] · Barre d'état après génération
**Le résumé de génération n'est peut-être jamais visible.**

Au moment du clic, la barre contient un résumé utile. Mais sur la capture prise 2 s plus tard, la zone d'état est vide. **Je n'ai pas pu vérifier** si le texte a été effacé par la mise à jour de la barre ou s'il est rogné par sa boîte de 162 px.

```
GENERATE 1842 ms, status 'Map Senegal Savanna seed 2026 | 192x192 | plateaus 4350 | lowlands 3895 | tracks 2 | waterholes 6 | 165 ms'
capture : confirmation/toolbar_03_generated.png (zone d'état vide)
```

**Correction :** à vérifier avant de corriger. Si c'est confirmé, afficher le résumé dans un toast de l'éditeur.

## Ce qui marche

- **Contraste** : tout passe le niveau AA (SC 1.4.3, 4,5:1) sur le fond mesuré #292929.

  | Texte | Contraste | Niveau |
  |---|---|---|
  | Texte normal | 8,83:1 | AAA (7:1) |
  | Titres de section | 9,09:1 (bleu) et 10,65:1 (vert) | AAA |
  | Aide grise | 6,49:1 | AA, pas AAA |

  Ce point n'est pas à retoucher.
- **Taille des cibles** :
  - la plus petite fait 40×41 px (icônes de la barre), au-dessus des 24×24 du SC 2.5.8 ;
  - les cases à cocher sont cliquables sur toute la ligne (379–396 × 34 px).
- **Info-bulles** :
  - 94 réglages sur 94 en ont une ;
  - les 11 outils donnent leur nom, puis une ligne de modificateurs (`"Ctrl+drag: lower · Shift+drag: smooth"`) et les raccourcis (`"[ ] size · - = strength · Esc leave the tool"`). Ce format court est le bon modèle pour remplacer les paragraphes.
- **Réactivité** :
  - « New Terrain » répond en 224 ms ;
  - une carte 192×192 complète est générée en 1,8 s ;
  - la carte apparaît cadrée en entier (capture `03_generated.png`).
- **Annulation** : Generate Map, Apply to Existing Waterholes et Generate from Image se défont avec Ctrl+Z, et leurs info-bulles le disent.
- **Choix visibles** :
  - les styles de sol du biome sont des boutons colorés ;
  - la liste de végétation est à côté de l'outil.

  Ce sont les deux seuls endroits où l'on voit ce qu'on choisit sans lire. C'est le modèle à étendre au sol et aux recettes.

## Ce qui n'a pas pu être mesuré

- **Focus clavier.** Le parcours au Tab dans l'Inspecteur n'a pas été sondé. Godot dessine son propre anneau de focus, et je ne l'ai pas mesuré.
- **Lecteur d'écran.** Godot 4.7 expose l'accessibilité (AccessKit), mais le plugin n'a pas été testé avec un lecteur d'écran.
- **Ressources biome, couche et recette.** Elles n'ont pas été recomptées : les chiffres (15, 45 et 28 réglages) viennent du premier audit.
- **Couleurs des mares (B3).** Pas re-mesurées : le constat 08 repose sur les textes et sur la lecture du code du premier audit.
- **Utilisateurs réels.** Aucun test avec un vrai débutant : tout ce qui précède est une inspection.

## Par où commencer

Classement par rapport effet ÷ effort.

| Ordre | Constats | Travail | Effort |
|---|---|---|---|
| 1 | **04** | Retirer `and _tool != PAINT`, reformuler l'aide | 1 ligne |
| 2 | **05** | Corriger « x4 » à trois endroits | 3 lignes |
| 3 | **01** | Recette par défaut, ou bouton grisé avec la raison | ~10 lignes |
| 4 | **03** | Liste des préréglages à la place du chemin de fichier | ~40 lignes |
| 5 | **09, 10, 11** | Bouton « ＋ Terrain » avec un mot ; retrait de Undo / Redo ; libellés courts | petit |
| 6 | **06, 12, 13, 14, 15** | Sections Carte / Aspect / Routes-rivières-mares / Jeu / Avancé ; aides en info-bulles ; vocabulaire unifié ; tailles de police à l'échelle | moyen, affichage seulement |
| 7 | **07, 10** | Liste « Sol ▾ » et fusion des outils | moyen, tests à adapter |
| 8 | **02, 08** | Biome = seule source de l'aspect | gros, avec migration des scènes |

Les points 1 à 5 forment l'**étape 1** du plan du premier audit. Ils ne touchent à aucune donnée et sont vérifiables par le test de fumée (96 vérifications) et par une nouvelle capture.

## Suivi : étape 1 faite (23 novembre 2026)

| Constat | Avant | Après (mesuré) |
|---|---|---|
| 01 | « Generate Map » sans recette : cases 0 → 0, aucun message | cases 0 → 36 864 : carte « Senegal Savanna » générée (préréglage du biome, sinon le premier). Sans aucun préréglage : toast dans l'éditeur. Pixel Map sans image : toast aussi |
| 03 | `Map Recipe : <empty>` et un chemin de fichier dans l'aide | liste « Map Preset » (Senegal Savanna, Temperate Island, Custom Recipe...) ; plus de chemin dans l'aide |
| 04 | aide masquée quand Paint est actif | une ligne en haut de la vue 3D tant que le terrain est vide : « Empty terrain: drag in the view to add ground · or Inspector > Generate Map » |
| 05 | « up to x4 » | « trees and other sparse layers up to x25 the biome density, grass up to x4 » (barre + 3 commentaires) |
| 09 | 2 textes coupés (342 px dans 162 px ; « Every ») | 0 texte coupé. Sans terrain : « No terrain selected » ; « All at runtime » dans une liste à mi-largeur |
| 10 | sans terrain : 17 éléments, 12 grisés | sans terrain : « New Terrain » (avec son nom) et l'état, sur la ligne de Godot ; les outils apparaissent avec un terrain |
| 11 | Undo / Redo dans la barre | retirés (Ctrl+Z / Ctrl+Shift+Z). Le menu Level reste en attendant ta réponse à la question 2 |

Vérifications :
- test de fumée : 103 réussis, 0 échec (7 nouveaux) ;
- `tools/check_maps.gd` : OK ;
- captures `results/ux_audit/etape1/`.

Le constat 02 (modifier le biome ne change pas le terrain) n'a pas changé : il relève de l'étape 4.

## Suivi : étape 2 faite (23 novembre 2026)

L'Inspecteur passe de 9 sections à **4 sections, plus une section « Advanced » fermée**. Aucune donnée ne change : seuls l'affichage et les textes changent.

| Section | Réglages | Boutons | Contenu |
|---|---|---|---|
| Map (ouverte) | 2 | 2 | Map Preset, Map Seed, Generate Map, Random Seed + Generate, taille du terrain |
| Look | 6 | 8 | Biome, Edit / Re-apply, 6 styles de sol, Show Details, Detail Density, Smooth Ground, 2 matériaux |
| Roads, Rivers & Waterholes | 9 | 1 | largeur et couleur des routes ; largeur, profondeur et couleur des rivières ; profondeur, plaques et couleurs des mares ; Apply to Existing Waterholes |
| Game | 6 | 0 | Walkable Collision, Collision Layer, Runtime Build, Detail Draw Distance, Mobile Water, Detail Seed |
| Advanced (fermée) | 71 | 3 | Terrain Size, Shading, Heights & Offsets, Custom Ground Style, Road Look, River Water, Waterhole Shape, Details, Pixel Map |

**Mesures, avant → après :**

| Mesure | Avant | Après |
|---|---|---|
| Réglages hors « Avancé » | 94 | **23** (les 71 autres sont dans Advanced) |
| Paragraphes d'aide | 22 (3 193 caractères) | **0** : chaque explication est une info-bulle, y compris sur les titres de section |
| Textes à 12 px ou 14 px | 62 | **0** : tous les textes suivent la police de l'éditeur (17 px à l'échelle 1.25) ; le titre « LowPoly Terrain » suit l'échelle |
| Textes coupés | 0 | 0 |
| Réglages sans info-bulle | 0 sur 94 | 0 sur 94 |

**Vocabulaire :**
- « Manual Brush Settings » → « Custom Ground Style ». Un clic sur un style de sol sélectionne maintenant aussi l'outil Paint.
- « Canvas » → « Terrain Size » (« Grow Terrain », « Maximum Cells »).
- « Indented » → « Lowered ».
- « Top Normal Up Bias » → « Flat Top Lighting ».
- « Feature Y Offset » → « Road / River Y Offset ».
- « Style Blend (cells) » → « Style Blend Width ».
- « Base Y » → « Cliff Bottom » ; « Terrain Height Min / Max » → « Lowest / Highest Ground ».
- La texture de normales de l'eau devient « Ripple Texture ».
- L'outil s'appelle « Waterhole » partout.
- « color » partout (plus de « colour » visible).
- Les cases à cocher sont toutes en Title Case.
- « 6 waterhole(s) » → « 6 waterholes » / « 1 waterhole ».

**Jargon retiré des textes visibles :** MultiMesh, draw call, `_LowpolyTerrainRuntime`, z-fighting, back-face culling, screen copy, NoiseTexture2D / FastNoiseLite. « COLOR » reste seulement dans l'info-bulle des matériaux perso, qui s'adresse à quelqu'un qui écrit un shader.

**Vérifications :**
- test de fumée : 106 réussis, 0 échec, dont 3 nouveaux (ordre des sections, aucun paragraphe, un style de sol sélectionne Paint) ;
- `check_maps`, `check_biomes`, `check_vegetation_paint` : OK ;
- captures : `results/ux_audit/etape2/`.

## Suivi : étape 3 faite (outils fusionnés)

**Barre d'outils : 7 outils au lieu de 10.** Il y avait 10 boutons d'outil, plus Undo / Redo retirés à l'étape 1, soit 11 au départ.

| Outil | Glisser | Ctrl + glisser | Shift + glisser |
|---|---|---|---|
| **Ground** | ajoute du sol dans le style choisi dans la liste | enlève le sol, et aussi routes, rivières et points d'eau sous le pinceau (ancien Erase) | lisse |
| **Relief** | monte le sol (ancien Raise) | creuse (ancien Lower) | lisse (ancien Smooth) |
| Flatten, Road, River, Waterhole | inchangés | — | — |
| Vegetation | plus de plantes | moins | retour à la densité du biome |

Erase, Lower et Smooth restent des modes internes. Quand l'un d'eux est actif, c'est le bouton Ground ou Relief qui s'allume.

**Liste des sols à côté de Ground :**
- elle remplace les boutons de style de l'Inspecteur ;
- chaque entrée a une pastille de couleur (dessus / côté) ;
- « Custom » = Inspector > Advanced > Custom Ground Style ;
- choisir un style sélectionne l'outil Ground.

**Correctif trouvé à la capture :** la liste affichait « Custom » au départ. Le pinceau gardait la couleur par défaut, verte, donc on peignait du vert tempéré sur une savane générée. Maintenant :
- un pinceau jamais réglé prend le premier sol du biome (« Grass » sur un terrain neuf) ;
- quand le biome change (Generate Map ou Biome), un pinceau qui tenait un style de l'ancien biome passe au premier style du nouveau (« Dry Grass » sur la savane) ;
- des couleurs « Custom » à soi sont gardées.

**Docs :** `HOW TO USE.txt` (les 7 outils, Ctrl / Shift) et `ARCHITECTURE.md` (entrée toolbar).

**Vérifications :**
- test de fumée : **115 réussis, 0 échec**. Les nouveaux tests couvrent :
  - la liste des sols et la sélection de Sand ;
  - Ctrl / Shift sur Ground et Relief ;
  - Erase qui allume Ground ;
  - Custom ;
  - un terrain neuf sur le 1er style ;
  - le pinceau qui suit le biome généré ;
  - Custom gardé quand on change de biome ;
- `check_maps`, `check_biomes`, `check_vegetation_paint` : OK ;
- captures : `results/ux_audit/etape3/` (`barre_avant_apres.png`, `03_generated.png`).

## Suivi : étape 4 faite (le biome est la seule source de l'aspect)

Cette étape corrige les constats 02 et 08 (B2 et B3 du premier audit).

**Ce qui change :**
- **L'ombrage précalculé** (fondu entre styles, teinte des pentes, occlusion, variation, falaises) est lu directement dans le biome. Le terrain n'en garde plus de copie. Modifier le biome reconstruit le terrain 250 ms après le dernier changement. Le bouton « Re-apply Biome Shading » disparaît.
- **Les couleurs des mares** (argile, fissures) viennent aussi du biome, les mêmes pour toutes les mares du terrain. Les lignes « Clay Color » et « Crack Color » sont retirées de la section Roads, Rivers & Waterholes.
- **Biome partagé.** Un fichier de biome (ex. `senegal_savanna.tres`) sert à tous les terrains qui l'utilisent. Un nouveau bouton « Copy Biome to This Terrain » met une copie dans la scène, pour modifier ce terrain seul (Ctrl+Z l'annule). L'info-bulle de « Edit Biome » dit si le biome est partagé.
- **Advanced > Shading** garde « Flat Top Lighting » et « Double-Sided Faces » (réglages propres au terrain). Un bouton « Edit Ground Shading » ouvre le biome.
- **Restent sur le terrain :** Smooth Ground, les matériaux perso, la densité des détails.

**Conversion des anciennes scènes** (automatique à l'ouverture, dans l'éditeur et en jeu) :
- les copies stockées sur le terrain sont retirées ;
- si elles avaient été réglées à la main, le terrain reçoit d'abord sa propre copie du biome avec ces valeurs (nommée « <biome> (<terrain>) »), donc il garde le même aspect ;
- si une scène a des mares de couleurs différentes entre elles, c'est la couleur de la première qui est gardée (cas que je n'ai pas rencontré) ;
- vérifié sur `scenes/savanna_128.tscn` : ses 11 valeurs étaient déjà celles du biome Senegal Savanna, donc pas de copie propre et aucun changement d'aspect ;
- la scène n'est pas réécrite tant que tu ne l'enregistres pas : la conversion refait la même chose à chaque ouverture.

**Mesures, avant → après :**

| Mesure | Avant (étape 3) | Après |
|---|---|---|
| Modifier l'occlusion dans le biome change le terrain | non (constat 02 : `chunk colours changed: false`) | **oui** : `BIOME_EDIT biome.ambient_occlusion 0.45 -> 1.0 ; terrain copy kept: false ; chunk colours changed: true` |
| Endroits où régler l'ombrage | 2 (biome + Advanced > Shading) | **1** (biome) |
| Endroits où régler les couleurs des mares | 3 (biome, Inspecteur, chaque mare) | **1** (biome) |
| Contrôles de la section Roads, Rivers & Waterholes | 15 | 13 |
| Contrôles de la section Advanced | 133 | 116 |

**Vérifications :**
- test de fumée : **123 réussis, 0 échec**. Les nouveaux tests couvrent :
  - l'ombrage lu dans le biome ;
  - une modification du biome qui reconstruit le sol ;
  - l'absence du bouton Re-apply ;
  - la copie du biome et son annulation ;
  - la conversion (valeurs égales → rien de créé ; valeurs réglées → biome propre ; une seule fois) ;
- `check_maps`, `check_biomes`, `check_vegetation_paint`, `check_waterholes`, `check_shading_seams`, `check_optimizations` : OK ;
- `compare_chunks` et `compare_feature_mesh` : IDENTICAL ;
- outils adaptés (ils réglaient l'ombrage sur le terrain) : `check_shading_seams.gd`, `check_optimizations.gd`, `check_waterholes.gd`, `style_test.gd` ;
- captures : `results/ux_audit/etape4/` (`look_avant_apres.png`).

## Suivi : étape 5 faite (Pixel Map et Level JSON)

**Tes réponses :** menu Level → retirer ; Pixel Map → garder en Avancé.

**Menu Level retiré** (icône disquette : Save Level / Duplicate / Delete).
- Pourquoi : le JSON écrit n'était relu par rien (le plugin n'avait pas de chargement). « Delete » supprimait le terrain de la scène sans Ctrl+Z. La scène Godot garde déjà tout le terrain.
- Retirés du plugin : `io/level_serializer.gd` (197 lignes), `ui/level_dialogs.gd`, l'icône « level », le dossier `io/`, la création automatique de `res://terrain_levels`.
- Mis de côté, pas supprimés : `_sauvegarde_level_json_2026-11-23/` à la racine du dépôt, avec un `LISEZMOI.txt`.
- Les anciennes scènes perdent leur réglage `_lte_level_path` à l'ouverture (il ne servait qu'à ce menu).
- Le dossier `test_project/terrain_levels/` (vide) n'a pas été touché.

**Pixel Map gardé** : il reste dans Inspector > Advanced > Pixel Map (Import from Image), fermé par défaut, sans changement.

**Barre d'outils :** 7 outils + 2 listes + taille / force, plus de menu à droite.

**Vérifications :**
- test de fumée : **121 réussis, 0 échec** (4 tests du menu Level retirés ; 2 ajoutés : plus de menu Level, ancien chemin retiré) ;
- `check_maps`, `check_biomes`, `check_vegetation_paint`, `check_waterholes`, `check_shading_seams`, `check_optimizations` : OK ;
- `compare_chunks`, `compare_feature_mesh` : IDENTICAL ;
- capture : `results/ux_audit/etape5/barre_avant_apres.png`.

## Bilan des 5 étapes

| Mesure | Avant l'audit | Après l'étape 5 |
|---|---|---|
| « Generate Map » sur un terrain neuf | ne fait rien de visible | génère la carte du préréglage par défaut |
| Boutons de la barre d'outils (hors listes et champs) | 10 outils + Undo + Redo + menu Level = 13 | 7 outils |
| Réglages visibles hors « Advanced » | 94 | 23 |
| Paragraphes d'aide dans l'Inspecteur | 22 | 0 (info-bulles) |
| Endroits où régler l'ombrage / les couleurs des mares | 2 / 3 | 1 / 1 (le biome) |
| Fonctions écrites mais jamais relues | export JSON | aucune |
