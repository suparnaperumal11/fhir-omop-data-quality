-- measurement <- FHIR Observation (laboratory and vital-signs only)
--
-- Maps:     Observations in the laboratory and vital-signs categories.
-- Routes:   survey, social-history, exam, procedure, imaging and therapy Observations
--           to etl_out_of_scope - NOT to etl_rejects.
-- Expands:  blood pressure panels into one measurement row per component.
--
-- THREE DISPOSITIONS, NOT TWO. This is the file where the distinction matters most.
--
--   MAPPED       laboratory + vital-signs -> measurement.
--   OUT OF SCOPE survey and social-history Observations belong in OMOP's observation
--                table, which this project does not build. They were not lost; they
--                were correctly routed somewhere we do not go. Counting them as
--                rejects would overstate the loss figure substantially - PRAPARE
--                surveys alone are tens of thousands of rows.
--   REJECTED     genuinely unmappable: no date, no code, unresolvable subject.
--
-- EXPANSION. A blood pressure panel (LOINC 85354-9) carries no scalar value; systolic
-- (8480-6) and diastolic (8462-4) live in component[] with their own LOINC codes.
-- OMOP models them as two separate measurements, so one source row becomes two target
-- rows. Recorded in etl_expansion so that target_rows > mapped_source_rows is visibly
-- legitimate rather than looking like a duplicate-key bug.
--
-- WHAT IS LOST:
--   * All 238 distinct LOINC codes map to measurement_concept_id = 0. Bucket 2.
--     measurement_source_value preserves the code. CMP-06 fails at its 30% threshold,
--     unrelaxed.
--   * valueCodeableConcept results (SNOMED) get value_as_concept_id = 0 with the code
--     kept in value_source_value. A qualitative lab result - "positive" - is therefore
--     present but not queryable as a concept.
--   * unit_concept_id = 0 for every row. Units are UCUM and would map cleanly with a
--     vocabulary; unit_source_value carries the original string.
--   * range_low / range_high stay NULL - Synthea emits no reference ranges.

-- Idempotent: re-running this file replaces its own output rather than doubling it.
DELETE FROM measurement;
DELETE FROM etl_rejects      WHERE target_table = 'measurement';
DELETE FROM etl_out_of_scope WHERE source_resource_type = 'Observation';
DELETE FROM etl_expansion    WHERE target_table = 'measurement';

-- ------------------------------------------------------- out of scope (NOT loss)
INSERT INTO etl_out_of_scope
    (source_resource_type, source_id, source_full_url, correct_omop_table, reason)
SELECT DISTINCT
    'Observation',
    o.observation_id,
    o.full_url,
    'observation',
    'Observation.category = ' || o.category_code
        || ' belongs in OMOP observation, which is outside this project''s five tables'
FROM v_observation o
WHERE o.category_code NOT IN ('laboratory', 'vital-signs');

-- ------------------------------------------------------------------- rejects
INSERT INTO etl_rejects
    (reject_id, source_resource_type, source_id, source_full_url,
     target_table, reason_code, reason_detail, source_row_json)
SELECT DISTINCT
    NULL, 'Observation', o.observation_id, o.full_url, 'measurement',
    CASE WHEN o.measurement_date IS NULL THEN 'MISSING_REQUIRED_FIELD'
         WHEN o.code IS NULL             THEN 'NO_SOURCE_CODE'
         ELSE 'UNRESOLVED_REFERENCE' END,
    CASE WHEN o.measurement_date IS NULL THEN 'effectiveDateTime missing or unparseable'
         WHEN o.code IS NULL             THEN 'code.coding[0].code absent'
         ELSE 'subject reference does not resolve to a staged Patient' END,
    o.resource_json
FROM v_observation o
LEFT JOIN xref_person xp ON xp.full_url = o.subject_reference
WHERE o.category_code IN ('laboratory', 'vital-signs')
  AND (o.measurement_date IS NULL OR o.code IS NULL OR xp.person_id IS NULL);

-- ----------------------------------------------------------------- expansion
INSERT INTO etl_expansion
    (source_resource_type, source_id, target_table, n_target_rows, expansion_reason)
SELECT
    'Observation', o.observation_id, 'measurement', count(*),
    'value[x] absent; component[] expanded to one measurement per component'
FROM v_observation o
JOIN xref_person xp ON xp.full_url = o.subject_reference
WHERE o.category_code IN ('laboratory', 'vital-signs')
  AND o.measurement_date IS NOT NULL AND o.code IS NOT NULL
  AND o.value_kind = 'component'
GROUP BY o.observation_id
HAVING count(*) > 1;

-- --------------------------------------------------------------- measurement
--
-- xref_measurement exists so that Observation -> measurement can be reconciled in SQL
-- rather than by arithmetic. Every other target table has a crosswalk back to its
-- source; without one here, "501,440 target rows came from 485,764 source
-- observations" is an assertion nobody can verify. It is built from the same
-- expression that numbers the rows below, so the two cannot drift apart.
CREATE OR REPLACE TABLE xref_measurement AS
SELECT
    row_number() OVER (ORDER BY o.observation_id, o.component_seq) AS measurement_id,
    o.observation_id,
    o.component_seq
FROM v_observation o
JOIN xref_person xp ON xp.full_url = o.subject_reference
WHERE o.category_code IN ('laboratory', 'vital-signs')
  AND o.measurement_date IS NOT NULL
  AND o.code IS NOT NULL;

INSERT INTO measurement (
    measurement_id, person_id, measurement_concept_id,
    measurement_date, measurement_datetime, measurement_time,
    measurement_type_concept_id, operator_concept_id,
    value_as_number, value_as_concept_id, unit_concept_id,
    range_low, range_high, provider_id, visit_occurrence_id, visit_detail_id,
    measurement_source_value, measurement_source_concept_id,
    unit_source_value, unit_source_concept_id, value_source_value,
    measurement_event_id, meas_event_field_concept_id
)
SELECT
    xm.measurement_id,
    xp.person_id,
    0                       AS measurement_concept_id,   -- see header
    o.measurement_date,
    o.measurement_datetime,
    NULL,
    32817                   AS measurement_type_concept_id,
    NULL,
    o.value_as_number,
    CASE WHEN o.value_kind = 'valueCodeableConcept' THEN 0 END AS value_as_concept_id,
    CASE WHEN o.unit_source_value IS NOT NULL       THEN 0 END AS unit_concept_id,
    NULL, NULL, NULL,
    xv.visit_occurrence_id,
    NULL,
    o.code                  AS measurement_source_value,
    NULL,
    o.unit_source_value,
    NULL,
    o.value_source_value,
    NULL, NULL
FROM v_observation o
JOIN xref_person xp ON xp.full_url = o.subject_reference
JOIN xref_measurement xm
      ON xm.observation_id = o.observation_id
     AND xm.component_seq  = o.component_seq
LEFT JOIN xref_visit xv ON xv.full_url = o.encounter_reference
WHERE o.category_code IN ('laboratory', 'vital-signs')
  AND o.measurement_date IS NOT NULL
  AND o.code IS NOT NULL;
