-- ============================================================
-- Parcelles cadastrales dont le propriétaire est décédé
-- Croise les données MAJIC (cadastre fiscal) avec le fichier
-- des décès INSEE pour identifier les biens en déshérence
-- potentielle ou en attente de succession.
-- ============================================================

WITH

-- Données géographiques et identifiants des parcelles cadastrales
parcelle AS (
    SELECT parcelle.id_com,
           parcelle.id_par,
           parcelle.parcelle,
           parcelle.section,
           parcelle.pre,          -- préfixe de section
           parcelle.geom
    FROM s_cadastre.parcelle
),

-- Propriétaires issus des fichiers MAJIC fiscaux.
-- On ne conserve que ceux dont l'identifiant (id_dnupro) est unique
-- dans la table, afin d'écarter les cas d'indivision ou de fiches
-- dupliquées qui rendraient le rapprochement ambigu.
-- L'âge est calculé dynamiquement à partir de la date de naissance
-- (format DD/MM/YYYY propre aux fichiers MAJIC).
proprietaire AS (
    SELECT proprietaire.id_dnupro,
           proprietaire.dnomlp,   -- nom de famille
           proprietaire.dprnlp,   -- prénom
           proprietaire.jdatnss,  -- date de naissance (DD/MM/YYYY)
           EXTRACT(year FROM age(
               CURRENT_DATE::timestamp with time zone,
               to_date(proprietaire.jdatnss::text, 'DD/MM/YYYY'::text)::timestamp with time zone
           )) AS age
    FROM s_majic.proprietaire
    WHERE proprietaire.id_dnupro IN (
        -- Filtre : id_dnupro apparaissant une seule fois = propriétaire unique, sans indivision
        SELECT proprietaire_1.id_dnupro
        FROM s_majic.proprietaire proprietaire_1
        GROUP BY proprietaire_1.id_dnupro
        HAVING count(*) = 1
    )
),

-- Lien entre parcelles et propriétaires dans les fichiers MAJIC (table NB-10).
-- Contient notamment la contenance cadastrale (dcntpa) et l'adresse.
nb_10_parcelle AS (
    SELECT nb_10_parcelle.id_par,
           nb_10_parcelle.id_com,
           nb_10_parcelle.id_dnupro,  -- clé de jointure vers le propriétaire
           nb_10_parcelle.dnvoiri,    -- numéro de voirie
           nb_10_parcelle.dindic,     -- indice de répétition (bis, ter...)
           nb_10_parcelle.cconvo,     -- code type de voie
           nb_10_parcelle.dvoilib,    -- libellé de la voie
           nb_10_parcelle.dcntpa,     -- contenance cadastrale (surface en m²)
           nb_10_parcelle.gparbat     -- indicateur parcelle bâtie / non bâtie
    FROM s_majic.nb_10_parcelle
),

-- Référentiel des communes (identifiant + nom)
commune AS (
    SELECT commune.id_com,
           commune.texte  -- nom de la commune
    FROM s_cadastre.commune
),

-- Rapprochement entre les propriétaires MAJIC et le fichier des décès INSEE.
-- La jointure est approximative sur le nom et le prénom (LIKE insensible à la casse),
-- et exacte sur la date de naissance.
-- Pour chaque propriétaire trouvé décédé, on retient :
--   - la date de décès la plus récente trouvée (en cas de doublons)
--   - un flag si le décès est récent (< 3 ans)
--   - un flag si le décès est ancien (> 10 ans), utile pour prioriser les successions
deces_info AS (
    SELECT
        prop_1.id_dnupro,
        max(p.date_deces::text) AS date_deces,
        bool_or(
            to_date(p.date_deces::text, 'YYYY-MM-DD'::text) > (CURRENT_DATE - '3 years'::interval)
        ) AS deces_recent,
        bool_or(
            to_date(p.date_deces::text, 'YYYY-MM-DD'::text) < (CURRENT_DATE - '10 years'::interval)
        ) AS deces_ancien
    FROM proprietaire prop_1
    JOIN ref_insee.personnes_deces p
        -- Correspondance sur le nom (LIKE, insensible à la casse, normalisation des espaces)
        ON upper(TRIM(BOTH FROM p.nom))    ~~ ('%' || upper(TRIM(BOTH FROM prop_1.dnomlp)) || '%')
        -- Correspondance sur le prénom (même logique)
        AND upper(TRIM(BOTH FROM p.prenom)) ~~ ('%' || upper(TRIM(BOTH FROM prop_1.dprnlp)) || '%')
        -- Correspondance exacte sur la date de naissance (conversion des deux formats)
        AND to_date(p.date_naissance::text, 'YYYY-MM-DD') = to_date(prop_1.jdatnss::text, 'DD/MM/YYYY')
    -- Exclusion des entrées INSEE avec date de naissance invalide (valeur '0--' = inconnue)
    WHERE p.date_naissance::text IS DISTINCT FROM '0--'
    GROUP BY prop_1.id_dnupro
)

-- ============================================================
-- Requête principale : assemblage final
-- Seuls les propriétaires ayant une correspondance de décès
-- sont retournés (JOIN inner sur deces_info).
-- ============================================================
SELECT
    prop.age,
    parc.id_com,
    ltrim(parc.parcelle::text, '0') AS parcelle,   -- numéro de parcelle sans zéros de tête
    ltrim(parc.section::text,  '0') AS section,    -- section sans zéros de tête
    parc.id_par,
    (parc.id_com::text || parc.pre::text)
