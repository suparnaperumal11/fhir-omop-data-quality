-- drug_exposure <- FHIR MedicationRequest
--
-- Maps:     50,887 MedicationRequests - 33,709 with an inline RxNorm code and 17,178
--           resolved through medicationReference to a Medication resource. Reading
--           only the inline form would have lost 33.8% of drug exposures here, and
--           lost them non-randomly.
-- Drops:    a request with no authoredOn or no resolvable drug code goes to
--           etl_rejects.
--
-- DERIVED VALUE - drug_exposure_end_date.
--   FHIR MedicationRequest carries authoredOn and nothing else. There is no end date,
--   no duration, no days supply. OMOP declares drug_exposure_end_date NOT NULL.
--
--   RULE APPLIED: end = start. Every drug exposure is recorded as a single-day event.
--
--   This is a DERIVATION, not a fact from the source, and it is wrong in a specific
--   and important way: a 90-day prescription and a single dose are indistinguishable
--   in the output. Any analysis of drug exposure DURATION on this dataset is invalid.
--   Stated in the README rather than buried here, because a reader who does not know
--   this would draw false conclusions from correct-looking data.
--
--   days_supply, refills and quantity stay NULL rather than being back-derived from
--   dosageInstruction text - parsing a sig string into a number is guesswork wearing
--   a structured column's clothing.
--
-- WHAT IS LOST:
--   * All 189 distinct RxNorm codes map to drug_concept_id = 0. Bucket 2, same as
--     conditions. drug_source_value preserves the code. CMP-05 fails at its 20%
--     threshold, which was set before results were seen and has not been relaxed.
--   * route_concept_id NULL; the sig text is carried verbatim in sig.

DELETE FROM drug_exposure;
DELETE FROM etl_rejects WHERE target_table = 'drug_exposure';

INSERT INTO etl_rejects
    (reject_id, source_resource_type, source_id, source_full_url,
     target_table, reason_code, reason_detail, source_row_json)
SELECT
    NULL, 'MedicationRequest', m.medicationrequest_id, m.full_url, 'drug_exposure',
    CASE WHEN m.start_date IS NULL THEN 'MISSING_REQUIRED_FIELD'
         WHEN m.code IS NULL       THEN 'NO_SOURCE_CODE'
         ELSE 'UNRESOLVED_REFERENCE' END,
    CASE WHEN m.start_date IS NULL THEN 'authoredOn missing or unparseable'
         WHEN m.code IS NULL       THEN 'medication[x] absent or reference unresolved ('
                                        || m.medication_source || ')'
         ELSE 'subject reference does not resolve to a staged Patient' END,
    m.resource_json
FROM v_medication_request m
LEFT JOIN xref_person xp ON xp.full_url = m.subject_reference
WHERE m.start_date IS NULL OR m.code IS NULL OR xp.person_id IS NULL;

INSERT INTO drug_exposure (
    drug_exposure_id, person_id, drug_concept_id,
    drug_exposure_start_date, drug_exposure_start_datetime,
    drug_exposure_end_date, drug_exposure_end_datetime, verbatim_end_date,
    drug_type_concept_id, stop_reason, refills, quantity, days_supply, sig,
    route_concept_id, lot_number, provider_id, visit_occurrence_id, visit_detail_id,
    drug_source_value, drug_source_concept_id, route_source_value, dose_unit_source_value
)
SELECT
    row_number() OVER (ORDER BY m.medicationrequest_id),
    xp.person_id,
    0                           AS drug_concept_id,   -- see header
    m.start_date,
    m.start_datetime,
    m.start_date                AS drug_exposure_end_date,      -- DERIVED, see header
    m.start_datetime            AS drug_exposure_end_datetime,  -- DERIVED
    NULL                        AS verbatim_end_date,  -- NULL because the source had none
    32817                       AS drug_type_concept_id,
    NULL, NULL, NULL, NULL,
    m.sig,
    NULL, NULL, NULL,
    xv.visit_occurrence_id,
    NULL,
    m.code                      AS drug_source_value,
    NULL, NULL, NULL
FROM v_medication_request m
JOIN xref_person xp ON xp.full_url = m.subject_reference
LEFT JOIN xref_visit xv ON xv.full_url = m.encounter_reference
WHERE m.start_date IS NOT NULL AND m.code IS NOT NULL;
