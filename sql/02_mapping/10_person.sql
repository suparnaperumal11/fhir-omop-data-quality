-- person  <- FHIR Patient
--
-- Maps:     1,112 Patient resources to OMOP person, plus a surrogate key crosswalk
--           that every other clinical table joins through.
-- Assumes:  FHIR administrative gender and US Core OMB race/ethnicity codes, per
--           the attested mappings in source_to_concept_map.
-- Drops:    nothing silently. A Patient with no birth_date cannot satisfy OMOP's
--           NOT NULL year_of_birth and is routed to etl_rejects with a reason.
--
-- WHAT IS LOST HERE, DELIBERATELY:
--   * person.location_id stays NULL. Patient.address is not mapped (out of scope),
--     so geography is absent from the output. A researcher asking a question about
--     place would find nothing. Documented, not hidden.
--   * FHIR gender permits male | female | other | unknown; OMOP's Gender domain has
--     two standard concepts. 'other' and 'unknown' have nowhere to go. Synthea emits
--     neither, so the loss is zero HERE and would not be zero on real data - the
--     mapping is no safer, we were just handed easy input.
--   * Race 'UNK' (19 patients) is left at concept_id 0 on purpose. OMOP has no
--     standard Race concept meaning "unknown", and inventing one would turn missing
--     data into a positive claim about a person's race.
--
-- PLAUSIBILITY IS NOT FILTERED HERE. A death recorded before a birth would be loaded,
-- not rejected, so that check PLA-02 can detect it. An ETL that quietly drops the rows
-- its own quality checks are meant to find makes those checks pass by construction.
-- Only STRUCTURAL failures (cannot supply a NOT NULL column) become rejects.

-- Idempotent: re-running replaces this file's output rather than doubling it.
DELETE FROM person;
DELETE FROM death;
DELETE FROM etl_rejects WHERE target_table = 'person';

-- ---------------------------------------------------------------------------
-- Surrogate keys.
--
-- OMOP person_id is an integer; FHIR ids are UUIDs. We need a stable crosswalk, and
-- every clinical table will join through it.
--
-- SQL NOTE - row_number() OVER (ORDER BY ...) is a "window function". It numbers rows
-- 1..n without collapsing them the way GROUP BY would. The ORDER BY inside OVER is
-- what makes the numbering deterministic: with a fixed Synthea seed, rerunning the
-- whole pipeline produces identical person_ids. Without it the ids would shuffle
-- between runs and nothing downstream would be reproducible.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE xref_person AS
SELECT
    row_number() OVER (ORDER BY patient_id) AS person_id,
    patient_id,
    full_url
FROM stg_patient;

-- ---------------------------------------------------------------------------
-- Rejects first, so that the reject path is never an afterthought.
-- ---------------------------------------------------------------------------
INSERT INTO etl_rejects
    (reject_id, source_resource_type, source_id, source_full_url,
     target_table, reason_code, reason_detail, source_row_json)
SELECT
    row_number() OVER (ORDER BY p.patient_id),
    'Patient',
    p.patient_id,
    p.full_url,
    'person',
    'MISSING_REQUIRED_FIELD',
    'birth_date is NULL; OMOP person.year_of_birth is NOT NULL',
    p.resource_json
FROM stg_patient p
WHERE p.birth_date IS NULL;

-- ---------------------------------------------------------------------------
-- person
-- ---------------------------------------------------------------------------
INSERT INTO person (
    person_id, gender_concept_id, year_of_birth, month_of_birth, day_of_birth,
    birth_datetime, race_concept_id, ethnicity_concept_id,
    location_id, provider_id, care_site_id,
    person_source_value, gender_source_value, gender_source_concept_id,
    race_source_value, race_source_concept_id,
    ethnicity_source_value, ethnicity_source_concept_id
)
SELECT
    x.person_id,

    -- COALESCE(a, b) returns the first non-NULL argument.
    -- The LEFT JOINs below produce NULL when a source code has no attested mapping;
    -- COALESCE turns that NULL into 0, OMOP's explicit "no matching concept".
    -- This distinction carries the project's whole argument: 0 is an assertion
    -- ("we looked and found nothing"), NULL is an absence. OMOP declares these
    -- columns NOT NULL precisely so that unmapped cannot masquerade as missing.
    COALESCE(g.target_concept_id, 0)                AS gender_concept_id,

    year(v.birth_date)                              AS year_of_birth,
    month(v.birth_date)                             AS month_of_birth,
    day(v.birth_date)                               AS day_of_birth,
    v.birth_datetime,

    COALESCE(r.target_concept_id, 0)                AS race_concept_id,
    COALESCE(e.target_concept_id, 0)                AS ethnicity_concept_id,

    NULL                                            AS location_id,   -- address not mapped
    NULL                                            AS provider_id,
    NULL                                            AS care_site_id,

    -- *_source_value columns are OMOP's own provenance mechanism. Populating them is
    -- what makes an unmapped row auditable rather than merely empty: the original
    -- code survives even when the concept_id is 0, so a later vocabulary load could
    -- resolve it retrospectively. Losing the source code would be irreversible.
    v.patient_id                                    AS person_source_value,
    v.gender_source_value,
    NULL                                            AS gender_source_concept_id,
    v.race_code                                     AS race_source_value,
    NULL                                            AS race_source_concept_id,
    v.ethnicity_code                                AS ethnicity_source_value,
    NULL                                            AS ethnicity_source_concept_id

FROM v_patient v
JOIN xref_person x ON x.patient_id = v.patient_id

-- LEFT JOIN, never an inner join, for every concept lookup in this repo.
-- An inner join would delete rows whose code has no mapping - turning "we could not
-- map this code" into "this patient does not exist". With 259 unmapped SNOMED codes
-- downstream, inner joins would erase most of the dataset and the row counts would
-- still look internally consistent.
LEFT JOIN source_to_concept_map g
       ON g.source_vocabulary_id = 'FHIR.administrative-gender'
      AND g.source_code = v.gender_source_value
LEFT JOIN source_to_concept_map r
       ON r.source_vocabulary_id = 'US-Core.race'
      AND r.source_code = v.race_code
LEFT JOIN source_to_concept_map e
       ON e.source_vocabulary_id = 'US-Core.ethnicity'
      AND e.source_code = v.ethnicity_code

WHERE v.birth_date IS NOT NULL;

-- ---------------------------------------------------------------------------
-- death  <- Patient.deceasedDateTime
--
-- Sixth table, added because OMOP has no death_date on person and the required
-- plausibility checks (PLA-02..PLA-06) need it. No new FHIR resource: the data comes
-- from Patient, already staged.
--
-- death_type_concept_id is 32817 (EHR), describing where the record came from rather
-- than how the person died. cause_concept_id stays NULL - Synthea's Patient resource
-- carries no cause of death, and that absence is real, not a mapping failure.
-- ---------------------------------------------------------------------------
INSERT INTO death
    (person_id, death_date, death_datetime, death_type_concept_id,
     cause_concept_id, cause_source_value, cause_source_concept_id)
SELECT
    x.person_id,
    v.deceased_date,
    v.deceased_datetime,
    32817,
    NULL,
    NULL,
    NULL
FROM v_patient v
JOIN xref_person x ON x.patient_id = v.patient_id
WHERE v.deceased_date IS NOT NULL;
