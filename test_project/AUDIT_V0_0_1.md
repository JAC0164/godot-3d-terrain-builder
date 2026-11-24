# Audit complet du plugin avant la v0.0.1 (2026-11-24)

**Portée.** Les 15 942 lignes de `addons/lowpoly_terrain_editor` ont été relues en entier en 4 parties :
- runtime et `core/` ;
- construction des meshes et des détails ;
- ombrage, routes et rivières, matériaux et styles ;
- éditeur, UI, outils et génération.

S'y ajoute la batterie automatique `tools/run_checks.sh` :
- empreintes octet par octet ;
- 18 contrôles headless ;
- typage statique ;
- smoke de l'éditeur.

**Avant les corrections**, la batterie passait déjà entièrement : empreintes OK, 18/18 contrôles, 0 avertissement de typage, smoke 175 réussis et 0 échec.

**Résultat de la relecture.** Pas de crash ni d'index hors limites.

Aucune tâche de thread ne touche à la scène : les workers ne lisent que des instantanés. Les graines sont déterministes. Il ne reste ni TODO ni print de debug.

## Corrigé dans cette version

### Éditeur

| # | Problème | Correction |
|---|---|---|
| 1 | Annuler puis Refaire **New Terrain** : le terrain et ses nœuds perdaient leur propriétaire, disparaissaient du dock Scène et n'étaient plus sauvegardés. | Refaire rend le propriétaire à tous les nœuds que la scène possédait (`plugin.gd`, `_set_owners`). |
| 2 | Baisser **Highest Ground** ou monter **Lowest Ground** écrasait les hauteurs pour de bon, sans Annuler. | Les réglages de géométrie sont annulables. Des pas de spin box d'affilée se fusionnent en un seul Annuler. Pour les limites de hauteur, Annuler rend les hauteurs coupées. |
| 3 | **Grow Terrain** n'avait pas d'Annuler. Un Annuler d'un trait plus ancien le défaisait en silence. | Grow Terrain est annulable (instantané). |
| 4 | Biome, Custom Material, Runtime Build, Create Editable Biome, Growth Step et Maximum Cells ne marquaient pas la scène comme modifiée : on pouvait fermer sans sauvegarder. | `mark_scene_as_unsaved()` après ces changements. |
| 5 | **Generate Map** : chaque étape écrivait des réglages, et `_process` reconstruisait tout le terrain à moitié écrit. C'était lent sur les cartes de 1024. | Pas de reconstruction pendant la génération. Elle reconstruit une seule fois à la fin. |
| 6 | **Random Seed + Generate** : Annuler ne rendait pas l'ancienne graine. La graine changeait aussi quand une génération était déjà en cours. | La nouvelle graine est écrite après la capture de l'état d'avant. Rien ne se passe si une génération tourne déjà. |
| 7 | **Generate from Image** avec une texture importée compressée (VRAM) : aucun pixel n'était lu, le terrain était vidé et 65 000 erreurs s'affichaient. | L'image est décompressée avant la lecture. |
| 8 | **Generate from Image** gardait les points d'eau de l'ancienne carte, placés au hasard sur la nouvelle grille. | Ils sont effacés avec les routes et les rivières, comme le fait Generate Map. |

### Jeu (runtime)

| # | Problème | Correction |
|---|---|---|
| 9 | `terrain_ready` arrivait seulement à la toute fin quand le sol est sauvegardé dans la scène (Runtime Build = Details). Le joueur attendait tous les détails, soit plusieurs secondes sur téléphone. | Il est émis dès le début, en différé : un script qui se connecte juste après `build()` le reçoit quand même. |
| 10 | Grande carte en streaming dans l'éditeur, collision activée : après une retouche, la collision d'un chunk était refaite avec l'**ancien** relief. | Le cache des faces du chunk est vidé quand il change. |
| 11 | Téléphones : une rivière construite sur PC et sauvegardée gardait le shader à réfraction, environ 8 ms par image sur un Mali, alors que l'Inspector dit « Phones always get it ». | Au chargement sur téléphone, la rivière reçoit le shader sans copie d'écran. |

### Robustesse

| # | Problème | Correction |
|---|---|---|
| 12 | Erreur de type au chargement si une couche de détails sauvegardée avec un mesh perso (SphereMesh…) repasse à un mesh intégré. | Le test de type tolère le cas, et le mesh est remplacé. |
| 13 | Lecture de `MASK` sans valeur par défaut alors qu'elle ne sert pas quand `CELL_ACTIVE` existe. | Lue seulement si besoin, avec une valeur par défaut. |

**Nouveaux tests dans le smoke de l'éditeur :**
- New Terrain : Annuler puis Refaire, le terrain reste dans la scène ;
- limite de hauteur : Annuler et Refaire rendent les hauteurs et la limite ;
- Grow Terrain : Annuler rend l'ancienne taille.

## Pas corrigé (connu, faible impact ou plus gros chantier)

### Éditeur
- **Biome partagé** : un deuxième terrain qui utilise le même `.tres` n'est reconstruit qu'à sa prochaine sélection-reconstruction.
- **Presets du plugin** : « Edit Biome » sur un nouveau terrain modifie le fichier preset du plugin (`biomes/presets/*.tres`), qui est écrasé à la mise à jour du plugin. Conseil : « Copy Biome to This Terrain » d'abord.
- **Changement de sélection pendant un trait** : le trait ne se termine pas. C'est rare.
- **Maximum Cells** compte les sommets : 1024 donne 1023 cases.
- **Anciennes clés `_lte_shade_*`** : elles sont encore écrites par le générateur de carte. Après Annuler puis Refaire d'une carte, un biome partagé modifié entre-temps peut être copié dans le terrain.

### Jeu
- **Second appel de `build()`** : sans `generate_map`, avec le streaming du sol, les anciens chunks et blocs lointains restent. Ne rappelez pas `build()` : rechargez la scène.
- **`generate_map` + routes découpées par chunk** : un mesh de routes sauvegardé reste par-dessus la nouvelle carte.
- **Ordre de chargement** : il suit la caméra, pas `stream_focus`, s'il n'y a pas encore de caméra.
- **`set_wind()`** n'agit que sur les matériaux créés pendant la partie, pas sur ceux des détails sauvegardés dans la scène.
- **Corps de collision orphelin** : il reste si la scène est quittée pendant la construction des collisions de troncs.

### Rendu
- **Renderer Compatibility** : les faces à textures mélangées sont un peu plus sombres. Il manque la garde `OUTPUT_IS_SRGB`.
- **Palette** : les styles inutilisés gardent leur place dans les 7 couches de textures, car la palette ne se vide jamais.
- **Sol lisse avec Blend 0** : les couleurs sont décalées d'une demi-case.
- **Routes** : elles ignorent les trous du masque et le bord de la carte, et n'utilisent pas Top Y Offset.
- **Petits défauts visuels** :
  - léger saut de couleur aux bords des blocs lointains ;
  - jupes de LOD parfois trop courtes sur les crêtes très raides.
- **Caches par terrain** (builder, matériaux) jamais vidés pendant une session d'éditeur : la mémoire grossit en ouvrant beaucoup de grandes cartes.

## Vérification

Après les corrections, `bash tools/run_checks.sh` donne :
- les 3 empreintes identiques à la base : aucun changement de rendu ;
- les 18 contrôles headless OK ;
- 0 avertissement de typage ;
- le smoke de l'éditeur à **180 réussis, 0 échec** (5 nouveaux tests).

Le smoke a trouvé un cas que la relecture n'avait pas vu. Le nœud runtime est ajouté *après* la création du terrain, au moment de la sélection. Le Refaire rend donc le propriétaire au moment même, pas à partir d'une liste figée.

À savoir : `run_checks.sh` affiche le résultat du smoke, mais ne le compte pas dans son code de sortie. Il faut lire la ligne `smoke:`.
