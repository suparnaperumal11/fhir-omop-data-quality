-- Vocabulary tables.
--
-- The full Athena vocabulary download is several GB and is deliberately out of scope.
-- We hand-map the most frequent source codes per domain and report coverage honestly;
-- the long tail of unmapped codes IS the finding, not a gap to be papered over.
--
-- source_to_concept_map is OMOP's own standard vehicle for exactly this situation, so
-- the hand-mapping lives there rather than in bespoke CASE statements scattered through
-- the mapping SQL. One table, inspectable, with a row per decision.
--
-- concept holds only the OMOP concepts we actually reference. It is NOT a vocabulary
-- load - it is a local, auditable subset so that a reader can see what 8507 means
-- without downloading Athena. Rows are marked with their provenance.

DROP TABLE IF EXISTS concept;
CREATE TABLE concept (
    concept_id       INTEGER NOT NULL,
    concept_name     VARCHAR NOT NULL,
    domain_id        VARCHAR NOT NULL,
    vocabulary_id    VARCHAR NOT NULL,
    concept_class_id VARCHAR NOT NULL,
    standard_concept VARCHAR,
    concept_code     VARCHAR NOT NULL,
    valid_start_date DATE,
    valid_end_date   DATE,
    invalid_reason   VARCHAR
);

DROP TABLE IF EXISTS source_to_concept_map;
CREATE TABLE source_to_concept_map (
    source_code             VARCHAR NOT NULL,
    source_concept_id       INTEGER NOT NULL,
    source_vocabulary_id    VARCHAR NOT NULL,
    source_code_description VARCHAR,
    target_concept_id       INTEGER NOT NULL,
    target_vocabulary_id    VARCHAR NOT NULL,
    valid_start_date        DATE,
    valid_end_date          DATE,
    invalid_reason          VARCHAR
);
