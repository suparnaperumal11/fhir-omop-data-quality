-- v_condition - one typed row per FHIR Condition. 1:1 with stg_condition.
--
-- TWO START DATES. Condition carries onsetDateTime (clinical onset) and recordedDate
-- (when it was entered). OMOP condition_start_date means onset, so we take
-- onsetDateTime. In Synthea the two are frequently identical, which means choosing
-- the wrong one would produce correct-looking output and would not surface in testing.
-- Both are exposed here so the choice is visible rather than buried.
--
-- coding_count is carried through deliberately. Taking coding[0] of an array with more
-- than one entry is a decision to discard the rest, and quantification Q-04 counts how
-- often we made it.

CREATE OR REPLACE VIEW v_condition AS
SELECT
    c.condition_id,
    c.full_url,
    c.subject_reference,
    c.encounter_reference,

    json_extract_string(c.code_json, '$.coding[0].code')     AS code,
    json_extract_string(c.code_json, '$.coding[0].display')  AS code_display,
    json_extract_string(c.code_json, '$.coding[0].system')   AS code_system,
    json_array_length(json_extract(c.code_json, '$.coding')) AS coding_count,

    json_extract_string(c.category_json, '$[0].coding[0].code')          AS category_code,
    json_extract_string(c.clinical_status_json, '$.coding[0].code')      AS clinical_status,
    json_extract_string(c.verification_status_json, '$.coding[0].code')  AS verification_status,

    c.onset_datetime                                             AS onset_raw,
    c.onset_datetime::TIMESTAMPTZ AT TIME ZONE 'America/New_York'            AS start_datetime,
    (c.onset_datetime::TIMESTAMPTZ AT TIME ZONE 'America/New_York')::DATE    AS start_date,
    c.abatement_datetime::TIMESTAMPTZ AT TIME ZONE 'America/New_York'        AS end_datetime,
    (c.abatement_datetime::TIMESTAMPTZ AT TIME ZONE 'America/New_York')::DATE AS end_date,
    -- exposed but NOT used for condition_start_date; see header
    (c.recorded_date::TIMESTAMPTZ AT TIME ZONE 'America/New_York')::DATE     AS recorded_date,

    c.resource_json
FROM stg_condition c;
