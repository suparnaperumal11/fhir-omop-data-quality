-- condition_occurrence <- FHIR Condition
--
-- Maps:     38,668 Conditions.
-- Assumes:  onsetDateTime is clinical onset and is the right source for
--           condition_start_date. recordedDate is NOT used - see 30_v_condition.sql.
-- Drops:    a Condition with no onset date, or whose subject does not resolve, goes
--           to etl_rejects.
--
-- WHAT IS LOST HERE - THE CENTRAL CASE:
--   Every one of the 259 distinct SNOMED codes maps to condition_concept_id = 0.
--   Not because the mapping is hard - SNOMED is itself an OMOP standard vocabulary and
--   the relationship is near-identity - but because resolving a code to an integer
--   concept_id requires the Athena vocabulary tables, which are out of scope.
--
--   These rows therefore land in BUCKET 2: structured but not computable. They load,
--   they reconcile, they pass every conformance check, and a concept-based cohort
--   query ("all patients with viral sinusitis") returns nothing. condition_source_value
--   preserves the original code so a later vocabulary load could resolve them
--   retrospectively - which is exactly why populating source values is not optional.
--
--   Checks CMP-04 will fail against its 20% threshold. The threshold was set on day 1
--   and has not been relaxed.
--
--   * Condition.category is all 'encounter-diagnosis' in this dataset, so the
--     diagnosis / problem-list / symptom ambiguity does not bite here. That is a
--     property of Synthea, not evidence the pipeline handles it. Real EHR data mixes
--     all three and this mapping is untested against that.
--   * clinicalStatus (active/resolved) has no OMOP home at this granularity;
--     condition_status_source_value carries it.

DELETE FROM condition_occurrence;
DELETE FROM etl_rejects WHERE target_table = 'condition_occurrence';

INSERT INTO etl_rejects
    (reject_id, source_resource_type, source_id, source_full_url,
     target_table, reason_code, reason_detail, source_row_json)
SELECT
    NULL, 'Condition', c.condition_id, c.full_url, 'condition_occurrence',
    CASE WHEN c.start_date IS NULL THEN 'MISSING_REQUIRED_FIELD'
         WHEN c.code IS NULL       THEN 'NO_SOURCE_CODE'
         ELSE 'UNRESOLVED_REFERENCE' END,
    CASE WHEN c.start_date IS NULL THEN 'onsetDateTime missing or unparseable'
         WHEN c.code IS NULL       THEN 'code.coding[0].code absent'
         ELSE 'subject reference does not resolve to a staged Patient' END,
    c.resource_json
FROM v_condition c
LEFT JOIN xref_person xp ON xp.full_url = c.subject_reference
WHERE c.start_date IS NULL OR c.code IS NULL OR xp.person_id IS NULL;

INSERT INTO condition_occurrence (
    condition_occurrence_id, person_id, condition_concept_id,
    condition_start_date, condition_start_datetime,
    condition_end_date, condition_end_datetime,
    condition_type_concept_id, condition_status_concept_id, stop_reason,
    provider_id, visit_occurrence_id, visit_detail_id,
    condition_source_value, condition_source_concept_id, condition_status_source_value
)
SELECT
    row_number() OVER (ORDER BY c.condition_id),
    xp.person_id,
    0                                   AS condition_concept_id,  -- see header
    c.start_date, c.start_datetime, c.end_date, c.end_datetime,
    32817                               AS condition_type_concept_id,
    NULL, NULL, NULL,
    -- LEFT JOIN to visits: a Condition whose encounter cannot be resolved still loads
    -- with a NULL visit_occurrence_id rather than being dropped.
    xv.visit_occurrence_id,
    NULL,
    c.code                              AS condition_source_value,
    NULL,
    c.clinical_status                   AS condition_status_source_value
FROM v_condition c
JOIN xref_person xp ON xp.full_url = c.subject_reference
LEFT JOIN xref_visit xv ON xv.full_url = c.encounter_reference
WHERE c.start_date IS NOT NULL AND c.code IS NOT NULL;
