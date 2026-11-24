# Audit UI / UX de l'addon LowPoly Terrain Editor

Date : 22 novembre 2026. Godot 4.7.2.

Méthode :
- l'éditeur a été ouvert hors écran et chaque étape a été capturée : scène vide, nouveau
  terrain, outil Gomme sur une carte générée, chaque page de l'Inspector ;
- les sources de l'addon ont été relues ;
- l'addon a été comparé aux bonnes pratiques des éditeurs de terrain connus : Terrain3D et
  HTerrain (Godot), Unity Terrain Tools, Unreal Landscape et la sculpture de Blender.

La fluidité (gomme, pinceaux, Undo) est traitée à part, dans `RAPPORT_PERF.md`, section
« Fluidité de l'édition ».

## Bonnes pratiques retenues

Les éditeurs de terrain établis partagent ces conventions :

| Pratique | Où on la trouve |
|---|---|
| Ctrl inverse l'outil (monter ↔ creuser, peindre ↔ effacer) | Terrain3D, Unity, Blender |
| Shift lisse, quel que soit l'outil | Terrain3D, Unity, Unreal, Blender |
| `[` `]` changent la taille du pinceau | Unity, Unreal, Blender (F) |
| Réglages de l'outil près de la vue 3D, seulement ceux qui servent | Terrain3D, Unreal |
| Les clics de navigation caméra ne lancent pas de trait (Alt, bouton droit / milieu) | tous |
| Un seul Undo par trait | tous |
| Collision et LOD recalculés à la fin du trait, pas pendant | Terrain3D, Unreal |
| Tampons espacés à la distance, pas au nombre d'événements souris | Unity, Blender |
| Raccourcis modifiables dans les réglages de l'éditeur | Terrain3D (EditorSettings) |
| Infos en direct sous le curseur (hauteur, pente) | Terrain3D, Unreal |

## Problèmes trouvés et corrections

| # | Problème | Gêne | Correction |
|---|---|---|---|
| 1 | La gomme et les pinceaux saccadaient (70 à 165 ms par mouvement, ~2 s sur une route). | forte | Corrigé : 15 à 60 ms (voir `RAPPORT_PERF.md`). |
| 2 | Undo et resélection du terrain bloquaient ~2 s. | forte | Corrigé : 0,1 à 0,2 s pour Undo, resélection instantanée. |
| 3 | Alt+clic gauche (orbite caméra en schéma Maya / Modo) lançait un trait. | forte | Corrigé : Alt, bouton droit ou milieu enfoncé laissent la caméra bouger. |
| 4 | Un clic dans le ciel désélectionnait le terrain : l'outil disparaissait. | moyenne | Corrigé : le clic est consommé, le terrain reste sélectionné. |
| 5 | Relâcher la souris hors de la vue 3D laissait le trait « collé ». | moyenne | Corrigé : le trait se termine dès que le bouton n'est plus enfoncé. |
| 6 | Il n'y avait aucun modificateur. Pour creuser après avoir monté, il fallait changer d'outil. | moyenne | Corrigé : Ctrl inverse, Shift lisse. L'anneau change de couleur dès qu'on appuie. |
| 7 | La largeur des routes et rivières ne se réglait que dans l'Inspector. | moyenne | Corrigé : avec Route / Rivière, le champ Taille et `[` `]` règlent la largeur. |
| 8 | Le champ Force restait actif pour les outils qui ne s'en servent pas (route, rivière, mare). | faible | Corrigé : il est grisé avec une info-bulle. |
| 9 | La force ne se réglait qu'à la souris. | faible | Corrigé : `-` `=` (et le pavé numérique) ; l'anneau affiche « 3.0 m  50% ». |
| 10 | Pas de moyen rapide de quitter l'outil. | faible | Corrigé : Échap revient à la sélection normale. |
| 11 | Un nouveau terrain n'affiche rien, sans aucune indication. | moyenne | Corrigé : la barre d'état dit « Empty terrain: pick Paint… or Generate Map ». |
| 12 | La barre d'état n'affichait que le nom de l'outil. | faible | Corrigé : elle montre le mode d'emploi (« Raise: drag · Ctrl lower · Shift smooth »). |
| 13 | Les info-bulles ne citaient pas les raccourcis. | faible | Corrigé : modificateurs et touches dans chaque info-bulle. |
| 14 | L'Inspector ouvrait « Canvas » en premier et Biome était loin en bas. | moyenne | Corrigé : ordre Map, Biome, Features, Manual Brush, Canvas (replié)… |
| 15 | Le dock Scène était encombré de nœuds `_Details` dépliés. | faible | Corrigé : le conteneur est replié à sa création. |
| 16 | La barre d'outils prenait 4 lignes. | moyenne | Corrigé : une seule ligne d'icônes, comme avant. |
| 17 | Après « Generate Map », la carte pouvait être hors champ. | moyenne | Corrigé : si la carte n'est pas entièrement visible, la caméra se recentre et recule pour la montrer en entier, avec le même angle de vue. |
| 18 | Taille et force du pinceau revenaient aux valeurs par défaut à chaque ouverture. | faible | Corrigé : elles sont gardées par projet (`.godot/editor/project_metadata.cfg`). |

Vérification : le smoke test headless passe 68 vérifications sur 68. Trois touchent le
cadrage (sélection gardée, carte visible) et la mémorisation du pinceau. Une capture hors
écran confirme que la carte de 193 m apparaît en entier. Dix autres touchent les entrées :
- Ctrl → creuser ;
- Shift → lisser ;
- Alt laissé à la caméra ;
- clic dans le ciel ;
- relâchement hors de la vue ;
- `=` ;
- `]` sur une route ;
- champ Force grisé ;
- retour du champ Taille au rayon ;
- Échap.

## Recommandations restantes (non faites)

Ordre conseillé, du plus utile au moins utile :

Le cadrage après « Generate Map » et la mémorisation du pinceau sont faits (lignes 17 et 18).

Cadrage : Godot 4.7 n'a pas d'API pour la caméra de l'éditeur, et « Focus Selection » (F)
recentre sans zoomer. L'addon sélectionne un repère temporaire au centre de la carte,
lance « Focus Selection », puis envoie des crans de molette à la vue 3D. La sélection est
rendue dans la même image. Si une future version de Godot change cette interface, le
cadrage ne se fait simplement pas.

L'outil actif n'est volontairement pas mémorisé : à la réouverture, un outil déjà actif
capterait le premier clic destiné à sélectionner un nœud.

1. **Raccourcis modifiables** : déclarer `[` `]` `-` `=` avec `EditorSettings.add_shortcut`
   pour qu'ils apparaissent dans Éditeur > Raccourcis.
2. **Touches pour choisir l'outil** (1 à 9 par exemple). Q, W, E et R sont déjà pris par
   Godot (sélection, déplacer, tourner, échelle), il faut donc des touches libres.
3. **Infos sous le curseur** : hauteur et pente en direct dans la barre d'état ou à côté de
   l'anneau.
4. **Aperçu du plan d'aplanissement** : dessiner un disque à la hauteur visée par Flatten
   avant de cliquer.
5. **Herbe et arbres pendant le trait** : ils gardent leur ancienne place jusqu'au
   relâchement. On pourrait masquer les détails sous le pinceau pendant le trait.
6. **Raccourcir les textes d'aide de l'Inspector**, ou ajouter un petit panneau
   « Réglages de l'outil » contextuel à côté de la vue 3D.
