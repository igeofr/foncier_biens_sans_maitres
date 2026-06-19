# Parcelles cadastrales — Propriétaires décédés

## Description

Cette requête SQL (PostgreSQL / PostGIS) identifie les **parcelles cadastrales dont le propriétaire enregistré est décédé**, en croisant les données fiscales MAJIC avec le fichier national des décès de l'INSEE.

Elle est destinée à alimenter une vue cartographique permettant de repérer des biens fonciers potentiellement en attente de succession ou en déshérence.

---

## Sources de données

| Schéma | Table | Contenu |
|---|---|---|
| `s_cadastre` | `parcelle` | Géométries et identifiants des parcelles cadastrales |
| `s_cadastre` | `commune` | Référentiel des communes (id + nom) |
| `s_majic` | `proprietaire` | Propriétaires issus des fichiers fiscaux MAJIC |
| `s_majic` | `nb_10_parcelle` | Lien parcelle ↔ propriétaire, contenance, adresse |
| `ref_insee` | `personnes_deces` | Fichier national des décès INSEE |

---

## Fonctionnement

### 1. Sélection des propriétaires (CTE `proprietaire`)
Seuls les propriétaires dont l'identifiant `id_dnupro` est **unique** dans la table sont conservés, afin d'éviter les ambiguïtés liées aux indivisions ou aux fiches dupliquées. L'âge de chaque propriétaire est calculé dynamiquement à partir de la date de naissance (format `DD/MM/YYYY` propre aux fichiers MAJIC).

### 2. Rapprochement avec les décès INSEE (CTE `deces_info`)
La correspondance est établie sur trois critères :
- **Nom** : correspondance `LIKE` insensible à la casse, avec normalisation des espaces
- **Prénom** : même logique
- **Date de naissance** : correspondance exacte après conversion de format (`DD/MM/YYYY` → `YYYY-MM-DD`)

Les entrées INSEE avec une date de naissance invalide (`0--`) sont exclues.

Pour chaque propriétaire décédé trouvé, la requête calcule :
- La **date de décès** la plus récente (en cas de doublons)
- Un flag **`deces_recent`** : décès survenu il y a moins de 3 ans
- Un flag **`deces_ancien`** : décès survenu il y a plus de 10 ans

### 3. Assemblage final
Les parcelles sont restituées avec leurs attributs cadastraux, leur géométrie (`MultiPolygon`, SRID 2154 — Lambert-93) et les informations de décès du propriétaire. Seules les parcelles ayant un propriétaire décédé sont retournées (jointure `INNER JOIN` sur `deces_info`).

Un filtre final (`age > 1 AND age < 200`) écarte les propriétaires avec des dates de naissance manifestement erronées.

---

## Colonnes restituées

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
| `contenance` | Surface cadastrale en m² (sans zéros de tête) |
| `geom` | Géométrie MultiPolygon, SRID 2154 (Lambert-93) |
| `date_deces` | Date de décès trouvée dans le fichier INSEE |
| `deces_recent` | `true` si le décès date de moins de 3 ans |
| `deces_ancien` | `true` si le décès date de plus de 10 ans |
| `gparbat` | Indicateur parcelle bâtie (`1`) ou non bâtie (NULL) |

---

## Limites et points d'attention

- **Faux positifs** : le matching sur le nom et le prénom par `LIKE` peut rapprocher des homonymes. La date de naissance exacte réduit ce risque mais ne l'élimine pas totalement.
- **Faux négatifs** : des orthographes différentes (accents, particules, abréviations) peuvent empêcher la correspondance entre MAJIC et INSEE.
- **Indivisions exclues** : les parcelles détenues en indivision (plusieurs propriétaires sous le même `id_dnupro`) ne sont pas restituées.
- **Performances** : le `LIKE` sur les noms/prénoms est coûteux sur de grands volumes. Des index fonctionnels `GIN` sur les colonnes `nom` et `prenom` de la table `personnes_deces` peuvent améliorer significativement les temps de traitement.

---

## Prérequis techniques

- PostgreSQL 12+
- Extension **PostGIS** (pour `ST_Multi`, `geometry`)
- Projection **SRID 2154** (Lambert-93) sur les géométries sources
