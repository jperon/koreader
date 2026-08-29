# breviarium.koplugin — conception

## Objectif

Plugin KOReader (`custom_plugins/breviarium.koplugin`, MoonScript, même convention que
`vatican.koplugin` / `corpusthomisticum.koplugin`) générant hors-ligne le bréviaire du
jour (rite romain 1960, latin, en v1), à partir des données du dépôt
[DivinumOfficium/divinum-officium](https://github.com/DivinumOfficium/divinum-officium),
sans aucune dépendance Perl.

## Constat d'ampleur

Le moteur Perl de référence ne se limite pas aux 7 modules `web/cgi-bin/DivinumOfficium/*.pm`
(~1100 lignes) : la logique métier réelle (calcul du calendrier, préséance, comput pascal,
commémoraisons, octaves, offices votifs, concurrence des vêpres, assemblage des heures) vit
dans `web/cgi-bin/horas/*.pl` et `web/cgi-bin/missa/*.pl`, soit **~13000 lignes de Perl**.
Une parité complète est un portage de plusieurs semaines. Ce document découpe le travail en
sous-projets livrables indépendamment, chacun fonctionnel et testable, avec une feuille de
route explicite pour le reste.

## Sous-projets

1. **Récupération et cache des données** (ce document la détaille intégralement — implémentée
   dans cette session).
2. **Calcul du calendrier liturgique du jour** — portage de `kalendar.pl` + logique de
   préséance/comput pascal de `horascommon.pl` : pour une date donnée, déterminer l'office
   du jour (temporal, sanctoral, commémoraisons, classe).
3. **Moteur d'assemblage de texte** — portage des routines de templating de
   `horascommon.pl`/`specmatins.pl`/`altovadum.pl` (substitutions `%…%`, références
   inter-fichiers, choix de psaumes/antiennes) pour produire le texte complet d'une heure.
4. **Rendu KOReader** — menu, sélection de la date/heure, affichage du texte assemblé.

Chaque sous-projet 2+ aura son propre design/plan au moment d'y arriver ; ils s'appuieront
sur les fixtures Perl (`t/`, `regress/`) du dépôt source comme oracle de correction.

## Sous-projet 1 : récupération et cache des données

### Source et méthode

Téléchargement de l'archive zip de la branche `master` du dépôt GitHub :
`https://github.com/DivinumOfficium/divinum-officium/archive/refs/heads/master.zip`
(une requête HTTP, pas de dépendance git). Extraction via `ffi/archiver.lua`
(binding libarchive déjà intégré à KOReader — aucune dépendance externe).

Le zip est extrait intégralement (le moteur référence des fichiers à travers plusieurs
répertoires — `horas/`, `missa/`, `Tabulae/`, `web/cgi-bin/DivinumOfficium/`, `t/`, etc. —
et élaguer risquerait de casser des sous-projets futurs) dans un répertoire versionné par
commit SHA, avec un lien symbolique `current` vers la version active.

### Emplacement

```
DataStorage:getDataDir!/breviarium/
├── cache/master.zip              -- archive téléchargée (supprimée après extraction réussie)
├── data/<sha>/...                -- contenu extrait (divinum-officium-master/*)
├── data/current -> data/<sha>    -- symlink vers la version active
└── settings.lua                  -- { sha = "...", fetched_at = ... } via LuaSettings
```

### Interface du module `fetch.moon`

- `fetch.currentDir!` → chemin de `data/current`, ou `nil` si aucune donnée locale.
- `fetch.status!` → `{ sha, fetched_at }` ou `nil`.
- `fetch.update(progress_callback)` → télécharge le zip, l'extrait dans `data/<sha>`
  (SHA dérivé du nom du dossier racine du zip GitHub, qui encode le commit pour un
  téléchargement par branche on utilisera plutôt un hash du contenu téléchargé, ou l'en-tête
  `ETag`/`Last-Modified` renvoyé par GitHub comme identifiant de version), bascule le
  symlink `current`, purge les versions précédentes, retourne `true` ou `nil, message`.
  Utilise `Trapper` pour permettre l'annulation et afficher la progression, comme
  `vatican.koplugin`.
- Gestion réseau : vérifie `NetworkMgr`, timeouts via `net.moon` (réutilisé/adapté du
  pattern `vatican.koplugin`/`corpusthomisticum.koplugin`).

### Menu

Un item de menu "Bréviaire" avec sous-item "Vérifier les mises à jour" (téléchargement
manuel uniquement, pas de fond de tâche automatique) affichant la date de la dernière
synchronisation et déclenchant `fetch.update`.

### Tests

Spec Busted (`spec/`, suivant la convention du dépôt — cf. `custom_plugins/*/spec`) :
- mock des réponses HTTP (`net.get` stubé) pour `fetch.update` (succès, échec réseau,
  zip corrompu, extraction).
- test que `fetch.currentDir!` retourne `nil` sans données locales et le bon chemin après
  un `fetch.update` simulé sur un vrai petit zip de test.

### Hors scope (sous-projet 1)

Pas de lecture/interprétation du contenu extrait — uniquement le rapatrier sur disque de
façon fiable et vérifiable hors-ligne. C'est l'objet du sous-projet 2.
