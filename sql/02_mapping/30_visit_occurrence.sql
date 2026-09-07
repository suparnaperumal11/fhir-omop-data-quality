-- visit_occurrence <- FHIR Encounter
--
-- Maps:     60,015 Encounters. Every clinical table below joins to visits through
--           xref_visit, so this runs before them.
-- Assumes:  Encounter.class (v3-ActCode) determines visit_concept_id.
-- Drops:    an Encounter with no period.start or period.end cannot satisfy OMOP's
--           NOT NULL visit_start_date / visit_end_date and goes to etl_rejects.
--
-- WHAT IS LOST HERE:
--   * Encounter.type (SNOMED, e.g. 185349003 "Encounter for check up") is NOT the
--     same as visit_concept_id, which describes the SETTING (inpatient, outpatient).
--     OMOP has no column for the encounter's clinical purpose at this granularity, so
--     the type code survives only in visit_source_value. A researcher wanting "well
--     child visits" specifically would have to parse a source value rather than query
--     a concept.
--   * class 'VR' (virtual, 122 encounters) maps to concept_id 0. OMOP's telehealth
--     representation is not part of the stable CDM concept set and inventing an id
--     would be worse than recording it as unmapped.
--   * admitted_from / discharged_to stay NULL - Synthea's Encounter carries neither.

DELETE FROM visit_occurrence;
DELETE FROM etl_rejects WHERE target_table = 'visit_occurrence';

CREATE OR REPLACE TABLE xref_visit AS
SELECT row_number() OVER (ORDER BY encounter_id) AS visit_occurrence_id,
       encounter_id, full_url
FROM stg_encounter;

INSERT INTO etl_rejects
    (reject_id, source_resource_type, source_id, source_full_url,
     target_table, reason_code, reason_detail, source_row_json)
SELECT
    NULL, 'Encounter', e.encounter_id, e.full_url, 'visit_occurrence',
    CASE
        WHEN e.start_date IS NULL OR e.end_date IS NULL THEN 'MISSING_REQUIRED_FIELD'
        ELSE 'UNRESOLVED_REFERENCE'
    END,
    CASE
        WHEN e.start_date IS NULL THEN 'period.start missing or unparseable'
        WHEN e.end_date   IS NULL THEN 'period.end missing or unparseable'
        ELSE 'subject reference does not resolve to a staged Patient'
    END,
    e.resource_json
FROM v_encounter e
LEFT JOIN xref_person xp ON xp.full_url = e.subject_reference
WHERE e.start_date IS NULL OR e.end_date IS NULL OR xp.person_id IS NULL;

INSERT INTO visit_occurrence (
    visit_occurrence_id, person_id, visit_concept_id,
    visit_start_date, visit_start_datetime, visit_end_date, visit_end_datetime,
    visit_type_concept_id, provider_id, care_site_id,
    visit_source_value, visit_source_concept_id,
    admitted_from_concept_id, admitted_from_source_value,
    discharged_to_concept_id, discharged_to_source_value,
    preceding_visit_occurrence_id
)
SELECT
    xv.visit_occurrence_id,
    xp.person_id,
    COALESCE(m.target_concept_id, 0)          AS visit_concept_id,
    e.start_date, e.start_datetime, e.end_date, e.end_datetime,
    32817                                     AS visit_type_concept_id,  -- EHR
    xpr.provider_id,
    xcs.care_site_id,
    -- source_value carries the class AND the SNOMED type code, because OMOP has no
    -- home for the latter and dropping it would lose the visit's clinical purpose.
    e.class_code || '|' || COALESCE(e.type_code, '')  AS visit_source_value,
    NULL, NULL, NULL, NULL, NULL, NULL
FROM v_encounter e
JOIN xref_visit  xv  ON xv.encounter_id = e.encounter_id
JOIN xref_person xp  ON xp.full_url     = e.subject_reference
LEFT JOIN source_to_concept_map m
       ON m.source_vocabulary_id = 'FHIR.v3-ActCode'
      AND m.source_code = e.class_code
LEFT JOIN xref_care_site xcs ON xcs.care_site_ident = e.care_site_ident
LEFT JOIN xref_provider  xpr ON xpr.provider_ident  = e.provider_ident
WHERE e.start_date IS NOT NULL AND e.end_date IS NOT NULL;
