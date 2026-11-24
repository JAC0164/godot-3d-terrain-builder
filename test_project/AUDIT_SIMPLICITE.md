# Audit : prise en main et simplicité

Date : 23 novembre 2026. Godot 4.7.2.

Question posée : quelqu'un qui n'a jamais vu le plugin peut-il s'en servir **sans lire la doc
et sans pavés de texte** ? Et y a-t-il trop de réglages ?

Réponse courte : **non, pas encore.** Le plugin fait beaucoup de choses bien (outils fluides,
modificateurs Ctrl / Shift, cadrage automatique), mais il montre **115 réglages d'un coup**. Beaucoup
existent **en double**. Et le chemin le plus utile (générer une carte) demande de connaître un
chemin de fichier.

Le premier audit (`AUDIT_UX.md`, 22 novembre) traitait la fluidité et les raccourcis. Celui-ci
traite la **compréhension** et le **nombre d'options**.

## Méthode

- L'éditeur a été ouvert hors écran comme le ferait un nouvel utilisateur :
  1. scène vide ;
  2. « New Terrain » ;
  3. chaque section de l'Inspecteur ouverte une par une ;
  4. « Generate Map » avec la recette savane ;
  5. le biome et une couche de végétation ouverts.
- Un script a compté chaque contrôle réel (case, nombre, couleur, bouton, ressource) et chaque
  texte d'aide.
- Trois comportements ont été vérifiés dans le code (voir B2, B3, B5).

Captures : `results/ux_audit/`.

## Les chiffres

| Où | Réglages | Textes d'aide |
|---|---|---|
| Barre d'outils | 11 outils + liste + taille + force + Undo + Redo + menu Level = **17** | info-bulles |
| Inspecteur du terrain, 9 sections | **115** | **22 paragraphes** (jusqu'à 327 caractères) |
| dont Terrain Features (routes, rivières, mares) | 33 | 4 |
| dont Pixel Map Generator | 29 | 5 |
| dont Rendering | 14 | 3 |
| Une couche de végétation (ressource) | 45, en 8 groupes | — |
| Le biome (ressource) | 15 | — |
| Une recette de carte (ressource) | 28, en 8 groupes | — |

Les ressources (biome, couche, recette) sont correctes : Godot les range en groupes repliés, et
on n'y va que pour personnaliser. **Le vrai problème est l'Inspecteur du terrain et la barre
d'outils**, que tout le monde voit.

## A. Le parcours d'un débutant : où il bloque

| # | Moment | Ce qu'il voit | Pourquoi il bloque |
|---|---|---|---|
| A1 | Plugin activé, scène vide | 17 icônes grisées sauf une, et un texte coupé « No terrain: sele… » | Le seul bouton utile (créer un terrain) est une petite icône sans mot. |
| A2 | Après « New Terrain » | Une vue 3D **vide** (rien à voir), l'outil Paint déjà actif, aucune indication | Il ne sait pas qu'il faut cliquer-glisser pour poser du sol, ni qu'on peut générer une carte. |
| A3 | Inspecteur, 1re section | Un paragraphe de 5 lignes, puis « Map Recipe : `<empty>` » | Pour générer, il faut deviner qu'il faut charger `addons/.../generation/presets/*.tres`. |
| A4 | Il clique « Generate Map » sans recette | **Rien ne se passe à l'écran** (un avertissement part dans la console Output) | Il pense que le bouton est cassé. |
| A5 | La même section | « Detail Seed », « Runtime Build : Every… » à côté de Generate | Des réglages techniques au milieu du geste principal. |
| A6 | La barre d'outils | 11 icônes sans texte : route = « A », rivière = « ≈ », mare = un œil, végétation = une sucette | Il faut survoler chaque icône. « Paint » veut dire *poser du sol*, pas *colorier*. |
| A7 | Les icônes Undo / Redo / disquette | Undo et Redo font la même chose que Ctrl+Z ; la disquette n'enregistre pas la scène mais ouvre un menu « Level » (fichiers JSON) | Doublons, et une icône qui ment (« sauvegarder » ≠ Ctrl+S). |

Ce qui marche bien et qu'il faut garder :
- après « Generate Map », la carte apparaît en entier, cadrée ;
- l'anneau du pinceau change de couleur avec Ctrl / Shift ;
- les styles de sol du biome sont des boutons avec leurs couleurs ;
- la liste de végétation à côté de l'outil (on voit ce qu'on peint).

## B. Trop d'options : les doublons

Le gros du problème n'est pas le nombre en soi, c'est que **la même chose se règle à plusieurs
endroits**. On ne sait pas lequel compte.

| # | La même chose… | …se règle ici | …et là | Ce qui se passe |
|---|---|---|---|---|
| B1 | Couleurs du sol | Biome > styles de sol (boutons) | Manual Brush Settings (6) + Pixel Map > 3 × 6 réglages | 4 endroits pour dire « quelle couleur je peins ». |
| B2 | Ombrage précalculé (pente, occlusion, variation…) | Biome > Baked Shading (10) | Rendering (10, les mêmes) | **Vérifié dans le code** : modifier le biome ne change pas le terrain. Il faut cliquer « Re-apply Biome Shading », qui écrase Rendering. Piège garanti. |
| B3 | Couleurs des mares | Biome > Waterholes (2) | Terrain Features > Dried Waterholes (Clay / Crack Color) | Même piège : le biome est copié une fois, puis c'est l'Inspecteur qui compte. |
| B4 | Générer une carte | Map Generator (recette + graine) | Pixel Map Generator (image + 29 réglages) | Deux générateurs complets ; le second date d'avant les recettes et a ses propres couleurs. |
| B5 | Annuler | Ctrl+Z (Godot) | Boutons Undo / Redo de la barre | **Vérifié** : les boutons appellent le même historique que Ctrl+Z. |
| B6 | Enregistrer | Ctrl+S (scène, qui contient tout le terrain) | Menu Level (JSON : Save, Duplicate, Delete) | Deux formats de sauvegarde. Le JSON n'est relu nulle part dans le plugin (export seulement). |
| B7 | Monter / creuser, peindre / effacer | Ctrl inverse l'outil | Un bouton séparé pour chaque sens | 4 boutons pour 2 gestes. |

## C. Réglages qu'un utilisateur ne devrait jamais voir d'emblée

Ces réglages servent à dépanner ou à des cas rares. Ils devraient être dans une section
« Avancé » repliée, ou disparaître :

- **Geometry Tuning** : Base Y, Top / Cliff / Feature Y Offset. Ce sont des corrections de
  scintillement, que le plugin devrait choisir seul.
- **Double-sided Faces** : son propre texte dit « pour dépanner ».
- **Top Normal Up Bias**.
- **Canvas** : Expansion Chunk, Maximum Resolution.
- **Rivières** : Water Surface Drop, Roughness, Normal Strength, Refraction, Normal Texture,
  « Create Editable Procedural Normal », Flow Speed / Direction. Cela fait 10 réglages de rendu
  d'eau, alors qu'il faut seulement largeur, profondeur et couleur pour dessiner une rivière.
- **Mares** : Floor, Irregularity, Rim Lip, Crack Width, Plate Curl.
- **Detail Seed** et **Runtime Build** : utiles pour le jeu, pas pour dessiner.

Côté vocabulaire, plusieurs noms parlent au programmeur, pas à l'utilisateur :
- « Canvas » (= taille du terrain) ;
- « Runtime Build » ;
- « Style Blend (cells) » ;
- « Indented Ground » ;
- « Top Normal Up Bias » ;
- « Feature Y Offset ».

## D. Proposition : un plugin qui s'explique tout seul

Principe : **un seul endroit par chose, les réglages rares cachés, et des choix sous forme de
listes plutôt que de chemins de fichiers.** Les textes d'aide deviennent des info-bulles : rien
ne doit dépendre d'un paragraphe.

### D1. Barre d'outils : 17 → 10 éléments

```
[＋ Terrain]  |  Sol [Latérite ▾]  Relief  Aplanir  |  Route  Rivière  Mare  |  Végétation [Tout ▾]  |  ◯ 3.0  ▮ 1.0
```

- **« ＋ Terrain » avec un mot**, seul bouton visible tant qu'il n'y a pas de terrain (A1).
- **Sol** = peindre ; Ctrl = effacer. La liste juste à côté choisit le style de sol du biome,
  comme la liste de végétation. Elle remplace la section Manual Brush (B1, B7). La dernière
  entrée « Personnalisé… » ouvre les couleurs à la main.
- **Relief** = monter ; Ctrl = creuser ; Shift = lisser. Le bouton Smooth séparé n'est plus
  utile (B7).
- On retire Undo / Redo (Ctrl+Z suffit, B5) et le menu Level (voir la question 2).
- Info-bulles courtes : le nom de l'outil, puis une ligne « Ctrl : … · Shift : … ».

### D2. Inspecteur : 9 sections et 115 réglages → 4 sections et environ 25 réglages visibles

| Section | Contenu (visible d'emblée) |
|---|---|
| **Carte** | Préréglage **[Savane ▾]** (liste des recettes, plus de chemin à connaître) · Graine [2026] [🎲] · **[Générer]** · Taille du terrain |
| **Aspect** | Biome [Savane ▾] [Modifier] · Sol lisse ☑ · Matériau du sol · Matériau des objets |
| **Routes, rivières, mares** | Route : largeur, couleur · Rivière : largeur, profondeur, couleur · Mare : profondeur, taille des plaques |
| **Jeu** | Collision ☑ · Couche · Construction au lancement ▾ · Graine de la végétation |
| ▶ **Avancé** (repliée) | Tout le reste : décalages Y, double face, extension auto, Pixel Map (import d'image)… |

- **Le biome devient la seule source de l'aspect** (B2, B3). L'ombrage précalculé, les couleurs
  des mares et l'eau des rivières se lisent dans le biome. Modifier le biome change le terrain
  tout de suite, et « Re-apply Biome Shading » disparaît. Pour un réglage propre à un seul
  terrain : « Modifier » crée une copie du biome dans la scène (cela existe déjà : « Create
  Editable Biome »).
- **Générer sans recette = un préréglage par défaut**, jamais un bouton qui ne fait rien (A4).
- **Terrain vide** : un message dans la vue 3D, « Glisser pour poser du sol · ou Carte >
  Générer », qui disparaît au premier coup de pinceau (A2). C'est une ligne, pas un paragraphe.

### D3. Ressources (biome, couche, recette)

Pas de refonte. Dans une couche de végétation, on regroupe les réglages rares dans un groupe
« Avancé » :
- Steep / Edge Bonus ;
- Small Bias ;
- Sink ;
- Cell Margin ;
- Paint Relaxes Rules ;
- Vegetation Brush.

Une couche passe ainsi de 8 groupes à 6.

## E. Ordre conseillé

| Étape | Contenu | Risque | Effet pour un débutant |
|---|---|---|---|
| 1 | A1, A2, A4 + liste de préréglages (D2 « Carte ») + retrait de Undo / Redo | faible, aucune donnée ne change | **le plus fort** : on génère une carte en 2 clics sans rien lire |
| 2 | Sections Carte / Aspect / Routes… / Jeu / Avancé, textes d'aide → info-bulles, noms plus clairs | faible (affichage seulement) | on ne voit plus que ~25 réglages |
| 3 | Barre d'outils fusionnée (Sol + liste, Relief) | moyen : changement d'habitude ; tests à adapter | 7 outils au lieu de 11 |
| 4 | Biome = seule source de l'aspect (B2, B3) | **moyen à fort** : il faut migrer les scènes existantes (leurs réglages Rendering deviennent un biome copié) | fin des pièges « je change et rien ne bouge » |
| 5 | Pixel Map et JSON Level : déplacés en Avancé, ou retirés | dépend de ta réponse aux questions | moins de surface |

Chaque étape garderait les mêmes vérifications qu'aujourd'hui : le test de fumée (96), les
vérifications de biome et de végétation, et des captures avant / après de l'Inspecteur.

## Questions à trancher

1. **Pixel Map Generator** : tu t'en sers encore ? Les recettes font mieux. Je propose de le mettre en « Avancé » (ou de le retirer).
2. **Menu Level (JSON)** : utile pour toi (outil externe, sauvegarde hors scène) ? Sinon on le retire, la scène contient déjà tout.
3. **Fusion des outils** (Sol, Relief) : d'accord pour 4 boutons de moins, en gardant Ctrl / Shift ?
4. **Le biome comme seule source de l'aspect** (étape 4) : c'est le changement le plus utile, mais il touche aux scènes existantes (migration automatique à l'ouverture).
