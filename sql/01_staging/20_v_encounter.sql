-- v_encounter - one typed row per FHIR Encounter. 1:1 with stg_encounter.
--
-- CONDITIONAL REFERENCES. Synthea writes provider/org/location links not as
-- urn:uuid but as a conditional reference by business identifier:
--
--     Organization?identifier=https://github.com/synthetichealth/synthea|4705a8fd-...
--     Practitioner?identifier=http://hl7.org/fhir/sid/us-npi|9999951590
--
-- so resolving them is a string split on '|' and a match against the target's
-- identifier[0].value - not a UUID lookup. split_part(s, '|', 2) takes the token
-- after the pipe. Measured: this resolves 100% of 60,015 encounters for both
-- organization and practitioner, which is why care_site_id and provider_id are
-- populated rather than NULL.
--
-- Every datetime is converted from its recorded offset to America/New_York before the
-- date is taken. See 10_v_patient.sql for why.

CREATE OR REPLACE VIEW v_encounter AS
SELECT
    e.encounter_id,
    e.full_url,
    e.subject_reference,
    e.status,

    json_extract_string(e.class_json, '$.code')            AS class_code,
    json_extract_string(e.type_json, '$[0].coding[0].code')    AS type_code,
    json_extract_string(e.type_json, '$[0].coding[0].display') AS type_display,

    e.period_start                                          AS period_start_raw,
    e.period_start::TIMESTAMPTZ AT TIME ZONE 'America/New_York'          AS start_datetime,
    (e.period_start::TIMESTAMPTZ AT TIME ZONE 'America/New_York')::DATE  AS start_date,
    e.period_end::TIMESTAMPTZ AT TIME ZONE 'America/New_York'            AS end_datetime,
    (e.period_end::TIMESTAMPTZ AT TIME ZONE 'America/New_York')::DATE    AS end_date,

    -- token after the '|' in the conditional reference
    split_part(e.service_provider_reference, '|', 2)        AS care_site_ident,
    split_part(json_extract_string(e.participant_json, '$[0].individual.reference'), '|', 2)
                                                            AS provider_ident,

    e.resource_json
FROM stg_encounter e;
