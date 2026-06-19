# Cadastre MAJIC — Détection des propriétaires décédés

## Description

Ce dépôt contient deux requêtes SQL (PostgreSQL / PostGIS) permettant d'identifier des biens fonciers dont le propriétaire enregistré est décédé, en croisant les données fiscales MAJIC avec le fichier national des décès de l'INSEE.

Elles sont destinées à alimenter des vues cartographiques permettant de repérer des biens **potentiellement en attente de succession ou en déshérence**.

> [!WARNING]
> La structuration des données est à adapter à votre modèle de données. Les données du cadastre et les données MAJIC reposent sur le [modèle Veremes](http://documentation.veremes.net/majic/index.html).

---

## Sources de données communes

| Schéma | Table | Contenu |
|---|---|---|
| `s_cadastre` | `parcelle` | Géométries et identifiants des parcelles cadastrales |
| `s_cadastre` | `commune` | Référentiel des communes (id + nom) |
| `s_majic` | `proprietaire` | Propriétaires issus des fichiers fiscaux MAJIC |
| `ref_insee` | `personnes_deces` | Fichier national des décès INSEE |

---

## Script 1 — Parcelles cadastrales des propriétaires décédés

### Sources spécifiques

| Schéma | Table | Contenu |
|---|---|---|
| `s_majic` | `nb_10_parcelle` | Lien parcelle ↔ propriétaire, contenance, adresse |

### Fonctionnement

#### 1. Sélection des propriétaires (CTE `proprietaire`)
Seuls les propriétaires dont l'identifiant `id_dnupro` est **unique** dans la table sont conservés, afin d'éviter les ambiguïtés liées aux indivisions ou aux fiches dupliquées. L'âge de chaque propriétaire est calculé dynamiquement à partir de la date de naissance (format `DD/MM/YYYY` propre aux fichiers MAJIC).

#### 2. Rapprochement avec les décès INSEE (CTE `deces_info`)
La correspondance est établie sur trois critères :
- **Nom** : correspondance `LIKE` insensible à la casse, avec normalisation des espaces
- **Prénom** : même logique
- **Date de naissance** : correspondance exacte après conversion de format (`DD/MM/YYYY` → `YYYY-MM-DD`)

Les entrées INSEE avec une date de naissance invalide (`0--`) sont exclues.

Pour chaque propriétaire décédé trouvé, la requête calcule :
- La **date de décès** la plus récente (en cas de doublons)
- Un flag **`deces_recent`** : décès survenu il y a moins de 3 ans
- Un flag **`deces_ancien`** : décès survenu il y a plus de 10 ans

#### 3. Assemblage final
Les parcelles sont restituées avec leurs attributs cadastraux, leur géométrie (`MultiPolygon`, SRID 2154 — Lambert-93) et les informations de décès du propriétaire. Seules les parcelles ayant un propriétaire décédé sont retournées (jointure `INNER JOIN` sur `deces_info`).

Un filtre final (`age > 1 AND age < 200`) écarte les propriétaires avec des dates de naissance manifestement erronées.

### Colonnes restituées

| Colonne | Description |
|---|---|
| `age` | Âge du propriétaire calculé depuis sa date de naissance |
| `id_com` | Code commune INSEE |
| `parcelle` | Numéro de parcelle (sans zéros de tête) |
| `section` | Section cadastrale (sans zéros de tête) |
| `id_par` | Identifiant interne de la parcelle |
| `id_sec` | Identifiant composite de la section (`id_com + pre + section`) |
| `commune` | Nom de la commune |
| `recherche` | Chaîne de recherche textuelle (`section parcelle commune`) |
| `contenance` | Surface cadastrale en m² |
| `geom` | Géométrie MultiPolygon, SRID 2154 (Lambert-93) |
| `date_deces` | Date de décès trouvée dans le fichier INSEE |
| `deces_recent` | `true` si le décès date de moins de 3 ans |
| `deces_ancien` | `true` si le décès date de plus de 10 ans |
| `gparbat` | Indicateur parcelle bâtie (`1`) ou non bâtie (NULL) |

---

## Script 2 — Locaux bâtis (lots de copropriété) des propriétaires décédés

Cible spécifiquement les **locaux bâtis appartenant à des lots de copropriété (PDL)** dont le propriétaire est décédé, en vue d'identifier des biens potentiellement sans maître au sens de l'article L1123-1 du CGPPP.

> **Réf. légale — Bien sans maître (art. L1123-1 CGPPP)** : bien dont le propriétaire est décédé sans héritier connu, ou dont la succession n'a pas été réclamée depuis plus de 30 ans.

### Sources spécifiques

| Schéma | Table | Contenu |
|---|---|---|
| `s_majic` | `lot_local` | Lien lot PDL ↔ local bâti |
| `s_majic` | `bati_0010_local` | Description du local (type, nature, adresse, valeur locative) |

### Fonctionnement

#### 1. Sélection des propriétaires (CTE `proprietaire`)
Identique au script 1. Le champ `ccodem` est également sélectionné afin de détecter les situations de succession (`S`) ou de veuve/héritiers (`V`) déjà référencées dans MAJIC.

#### 2. Rapprochement avec les décès INSEE (CTE `deces_info`)
Identique au script 1, avec un flag supplémentaire :
- Un flag **`deces_tres_ancien`** : décès survenu il y a plus de 30 ans — correspond au seuil légal de qualification en bien sans maître (art. L1123-1 CGPPP).

#### 3. Sélection des locaux bâtis (CTE `local_bati`)
Les locaux sont extraits via la table `lot_local` (lots de copropriété / PDL), jointure avec `bati_0010_local` pour obtenir la description complète. Seuls les locaux de type maison (`dteloc = 1`) ou appartement (`dteloc = 2`) sont retenus.

> [!NOTE]
> Le champ `dnatlc` (nature d'occupation : vacant, occupé...) est **déprécié depuis MAJIC III**. Il peut encore être renseigné dans certains millésimes mais ne doit pas être utilisé comme critère fiable de vacance.

#### 4. Assemblage final
Les locaux sont restitués avec leur adresse, leur description, les informations du propriétaire et les flags de décès. Seuls les locaux ayant un propriétaire confirmé décédé (INNER JOIN sur `deces_info`) sont retournés, triés par date de décès croissante.

### Colonnes restituées

| Colonne | Description |
|---|---|
| `id_local` | Identifiant unique du local |
| `klot` | Identifiant du lot dans la copropriété |
| `num_lot` | Numéro de lot |
| `id_com` | Code commune INSEE |
| `commune` | Nom de la commune |
| `dep` | Code département |
| `adresse` | Adresse reconstituée (numéro + indice + libellé voie) |
| `type_local` | Type de local (`Maison` ou `Appartement`) |
| `nature_local` | Nature du local (MA, AP, ME...) |
| `age_proprietaire` | Âge du propriétaire calculé depuis sa date de naissance |
| `date_deces` | Date de décès trouvée dans le fichier INSEE |
| `deces_recent` | `true` si le décès date de moins de 3 ans |
| `deces_ancien` | `true` si le décès date de plus de 10 ans |
| `deces_tres_ancien` | `true` si le décès date de plus de 30 ans (seuil légal sans maître) |
| `geom` | Géométrie MultiPolygon, SRID 2154 (Lambert-93) |

---

## Limites et points d'attention communs

- **Faux positifs** : le matching sur le nom et le prénom par `LIKE` peut rapprocher des homonymes. La date de naissance exacte réduit ce risque mais ne l'élimine pas totalement.
- **Faux négatifs** : des orthographes différentes (accents, particules, abréviations) peuvent empêcher la correspondance entre MAJIC et INSEE.
- **Indivisions exclues** : les biens détenus en indivision (plusieurs propriétaires sous le même `id_dnupro`) ne sont pas restitués.
- **Performances** : le `LIKE` sur les noms/prénoms est coûteux sur de grands volumes. Des index fonctionnels `GIN` sur les colonnes `nom` et `prenom` de la table `personnes_deces` peuvent améliorer significativement les temps de traitement.

---

## Prérequis techniques

- PostgreSQL 12+
- Extension **PostGIS** (pour `ST_Multi`, `geometry`)
- Projection **SRID 2154** (Lambert-93) sur les géométries sources
