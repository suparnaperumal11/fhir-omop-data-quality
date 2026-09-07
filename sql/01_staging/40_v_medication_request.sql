-- v_medication_request - one typed row per FHIR MedicationRequest.
--
-- TWO WAYS OF NAMING A DRUG. 80% of MedicationRequests carry the RxNorm code inline
-- in medicationCodeableConcept; the other 20% carry medicationReference pointing at a
-- separate Medication resource. Reading only the inline form would lose one drug
-- exposure in five, and lose them non-randomly - Synthea uses the reference form for
-- particular administration types, so the missing fifth would be a biased sample, not
-- a random one. That is the most dangerous kind of loss: invisible in aggregate.
--
-- COALESCE below tries the inline code first and falls back to the resolved reference.
-- medication_source is carried through so the loss report can show the split.
--
-- NO END DATE EXISTS. MedicationRequest has authoredOn and nothing else - no duration,
-- no end. OMOP drug_exposure_end_date is NOT NULL. The derivation (end = start) lives
-- in the mapping file, labelled, not hidden here.

CREATE OR REPLACE VIEW v_medication_request AS
SELECT
    m.medicationrequest_id,
    m.full_url,
    m.subject_reference,
    m.encounter_reference,
    m.status,
    m.intent,

    COALESCE(
        json_extract_string(m.medication_codeable_concept_json, '$.coding[0].code'),
        json_extract_string(med.code_json, '$.coding[0].code')
    ) AS code,
    COALESCE(
        json_extract_string(m.medication_codeable_concept_json, '$.coding[0].display'),
        json_extract_string(med.code_json, '$.coding[0].display')
    ) AS code_display,

    CASE
        WHEN m.medication_codeable_concept_json IS NOT NULL THEN 'inline'
        WHEN med.medication_id IS NOT NULL                  THEN 'resolved_reference'
        WHEN m.medication_reference IS NOT NULL             THEN 'unresolved_reference'
        ELSE 'no_medication'
    END AS medication_source,

    m.authored_on                                                     AS authored_raw,
    m.authored_on::TIMESTAMPTZ AT TIME ZONE 'America/New_York'         AS start_datetime,
    (m.authored_on::TIMESTAMPTZ AT TIME ZONE 'America/New_York')::DATE AS start_date,

    json_extract_string(m.dosage_instruction_json, '$[0].text')       AS sig,
    m.resource_json

FROM stg_medicationrequest m
-- LEFT JOIN so a MedicationRequest whose reference cannot be resolved still appears,
-- flagged as unresolved_reference, instead of vanishing.
LEFT JOIN stg_medication med
       ON med.full_url = m.medication_reference;
