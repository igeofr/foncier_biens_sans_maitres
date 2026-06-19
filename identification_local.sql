-- ============================================================
-- Locaux bâtis (lots de copropriété) dont le propriétaire
-- est décédé selon le fichier national des décès INSEE.
--
-- Objectif : identifier des biens potentiellement sans maître
-- en croisant les données fiscales MAJIC avec le fichier INSEE.
--
-- Chaîne de jointure :
--   lot_local → bati_0010_local → proprietaire
--                               → s_cadastre.parcelle (géom)
--
-- Réf. légale : art. L1123-1 CGPPP
--   Bien sans maître = propriétaire décédé sans héritier connu
--   ou succession non réclamée depuis 30 ans.
-- ============================================================

WITH

-- Propriétaires personnes physiques issus des fichiers fiscaux MAJIC.
-- Seuls les comptes apparaissant une seule fois sont conservés
-- afin d'éviter les ambiguïtés liées aux indivisions ou doublons.
-- L'âge est calculé dynamiquement depuis la date de naissance
-- au format MAJIC (DD/MM/YYYY).
-- ccodem renseigne la situation juridique du compte :
--   S = succession, V = veuve/héritiers, I = indivision, L = litige
proprietaire AS (
    SELECT
        p.id_dnupro,
        p.dnomlp,           -- nom de famille
        p.dprnlp,           -- prénom
        p.jdatnss,          -- date de naissance (format DD/MM/YYYY)
        p.ccodem,           -- code démembrement / situation juridique
        EXTRACT(year FROM age(
            CURRENT_DATE::timestamptz,
            to_date(p.jdatnss::text, 'DD/MM/YYYY')::timestamptz
        )) AS age
    FROM s_majic.proprietaire p
    WHERE p.id_dnupro IN (
        -- Ne retenir que les id_dnupro sans doublon (un seul propriétaire par compte)
        SELECT p2.id_dnupro
        FROM s_majic.proprietaire p2
        GROUP BY p2.id_dnupro
        HAVING count(*) = 1
    )
),

-- Rapprochement entre les propriétaires MAJIC et le fichier
-- national des décès INSEE (ref_insee.personnes_deces).
--
-- La correspondance est établie sur trois critères :
--   - Nom    : LIKE insensible à la casse avec normalisation des espaces
--   - Prénom : même logique
--   - Date de naissance : correspondance exacte après conversion de format
--
-- Les entrées avec date de naissance invalide ('0--') sont exclues.
--
-- Pour chaque propriétaire décédé identifié, on calcule :
--   - date_deces      : date de décès la plus récente trouvée
--   - deces_recent    : décès il y a moins de 3 ans (succession en cours probable)
--   - deces_ancien    : décès il y a plus de 10 ans (alerte sans maître opérationnelle)
--   - deces_tres_ancien : décès il y a plus de 30 ans (seuil légal art. L1123-1 CGPPP)
deces_info AS (
    SELECT
        prop.id_dnupro,
        max(p.date_deces::text) AS date_deces,
        bool_or(
            to_date(p.date_deces::text, 'YYYY-MM-DD') > (CURRENT_DATE - '3 years'::interval)
        ) AS deces_recent,
        bool_or(
            to_date(p.date_deces::text, 'YYYY-MM-DD') < (CURRENT_DATE - '10 years'::interval)
        ) AS deces_ancien,
        bool_or(
            to_date(p.date_deces::text, 'YYYY-MM-DD') < (CURRENT_DATE - '30 years'::interval)
        ) AS deces_tres_ancien
    FROM proprietaire prop
    JOIN ref_insee.personnes_deces p
        -- Correspondance sur le nom (LIKE, insensible à la casse)
        ON upper(TRIM(p.nom))    ~~ ('%' || upper(TRIM(prop.dnomlp)) || '%')
        -- Correspondance sur le prénom (même logique)
       AND upper(TRIM(p.prenom)) ~~ ('%' || upper(TRIM(prop.dprnlp)) || '%')
        -- Correspondance exacte sur la date de naissance (conversion des deux formats)
       AND to_date(p.date_naissance::text, 'YYYY-MM-DD') = to_date(prop.jdatnss::text, 'DD/MM/YYYY')
    -- Exclusion des entrées INSEE avec date de naissance invalide
    WHERE p.date_naissance::text IS DISTINCT FROM '0--'
    GROUP BY prop.id_dnupro
),

-- Locaux bâtis issus de la table lot_local (lots de copropriété / PDL).
-- lot_local fait le lien entre un lot (klot) et un local (id_local).
-- La description complète du local est dans bati_0010_local, qui porte
-- également le lien direct au propriétaire (id_dnupro) et à la parcelle (id_par).
--
-- Filtre : uniquement les maisons (dteloc=1) et appartements (dteloc=2).
-- Note : dnatlc (nature d'occupation) est déprécié depuis MAJIC III ;
--        il peut encore être renseigné mais ne doit pas être utilisé
--        comme critère fiable de vacance.
local_bati AS (
    SELECT
        ll.id_local,            -- identifiant unique du local
        ll.klot,                -- identifiant du lot dans la copropriété
        ll.dnulot,              -- numéro de lot
        ll.dnumql,              -- numérateur de la quote-part
        ll.ddenql,              -- dénominateur de la quote-part
        b.id_par,               -- identifiant parcelle (pour jointure géométrie)
        b.id_dnupro,            -- lien vers le propriétaire
        b.id_com,               -- code commune (ccodep+ccocom)
        b.ccocom,               -- code commune INSEE
        b.ccodep,               -- code département
        b.dteloc,               -- type de local : 1=maison, 2=appartement
        b.cconlc,               -- nature du local : MA, AP, ME...
        b.dnatlc,               -- nature d'occupation (déprécié, indicatif)
        b.dnvoiri,              -- numéro de voirie
        b.dindic,               -- indice de répétition (bis, ter...)
        b.dvoilib,              -- libellé de la voie
        b.dnubat,               -- lettre de bâtiment
        b.nesc,                 -- numéro d'escalier
        b.dniv,                 -- niveau / étage
        b.dpor,                 -- numéro de porte
        b.jannat,               -- année de construction
        b.dvltrt,               -- valeur locative totale retenue
        b.hlmsem,               -- indicateur HLM (5) ou SEM (6)
        b.jdatat                -- date de la dernière mutation connue
    FROM s_majic.lot_local ll
    JOIN s_majic.bati_0010_local b ON ll.id_local = b.id_local
    WHERE b.dteloc IN ('1', '2')    -- maisons et appartements uniquement
),

-- Géométries des parcelles cadastrales
parcelle AS (
    SELECT p.id_par, p.id_com, p.geom
    FROM s_cadastre.parcelle p
),

-- Référentiel des communes (identifiant + nom)
commune AS (
    SELECT c.id_com, c.texte AS libcom
    FROM s_cadastre.commune c
)

-- ============================================================
-- Résultat final : locaux de copropriété dont le propriétaire
-- est confirmé décédé dans le fichier INSEE.
-- Triés par date de décès croissante (les plus anciens en tête).
-- ============================================================
SELECT
    -- Identifiants du local et du lot
    lb.id_local,
    lb.klot,
    lb.dnulot                                           AS num_lot,
    lb.id_com,
    comm.libcom                                         AS commune,
    lb.ccodep                                           AS dep,

    -- Adresse reconstituée depuis les champs MAJIC
    -- (numéro + indice de répétition + libellé de voie)
    TRIM(COALESCE(lb.dnvoiri, '') || ' '
        || COALESCE(lb.dindic, '') || ' '
        || COALESCE(lb.dvoilib, ''))                    AS adresse,

    -- Type de local traduit depuis le code MAJIC
    CASE lb.dteloc
        WHEN '1' THEN 'Maison'
        WHEN '2' THEN 'Appartement'
    END                                                 AS type_local,
    lb.cconlc                                           AS nature_local,    -- MA, AP, ME...

    -- Âge calculé du propriétaire (peut être incohérent si jdatnss erronée,
    -- filtré en aval par WHERE prop.age > 1 AND prop.age < 200)
    prop.age                                            AS age_proprietaire,

    -- Informations de décès issues du croisement INSEE
    di.date_deces,
    COALESCE(di.deces_recent,      false)               AS deces_recent,        -- < 3 ans
    COALESCE(di.deces_ancien,      false)               AS deces_ancien,        -- > 10 ans
    COALESCE(di.deces_tres_ancien, false)               AS deces_tres_ancien,   -- > 30 ans (seuil légal)

    -- Géométrie de la parcelle support, forcée en MultiPolygon Lambert-93
    ST_Multi(parc.geom)::geometry(MultiPolygon, 2154)   AS geom

FROM local_bati lb
    -- Lien local → propriétaire
    JOIN proprietaire prop ON lb.id_dnupro  = prop.id_dnupro
    -- Filtre principal : uniquement les propriétaires confirmés décédés (INNER JOIN)
    JOIN deces_info   di   ON prop.id_dnupro = di.id_dnupro
    -- Géométrie via la parcelle support du local
    JOIN parcelle     parc ON lb.id_par      = parc.id_par
    -- Nom de la commune
    JOIN commune      comm ON lb.id_com      = comm.id_com

-- Exclusion des âges aberrants liés à des dates de naissance erronées en MAJIC
WHERE prop.age > 1
  AND prop.age < 200

-- Les décès les plus anciens en premier (priorité de traitement successoral)
ORDER BY di.date_deces ASC;
