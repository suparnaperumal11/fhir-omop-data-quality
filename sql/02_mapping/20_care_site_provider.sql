-- care_site <- Organization,  provider <- Practitioner
--
-- Dimension tables. They exist so that visit_occurrence.care_site_id and provider_id
-- resolve to something rather than dangling as bare integers.
--
-- Joined by business identifier, not resource id, because that is what the Encounter
-- conditional references carry. See 20_v_encounter.sql.
--
-- Drops: place_of_service_concept_id and specialty_concept_id stay NULL. Both require
-- vocabulary concepts we cannot attest to, and Synthea's Organization carries no
-- place-of-service code anyway.

DELETE FROM care_site;
DELETE FROM provider;

CREATE OR REPLACE TABLE xref_care_site AS
SELECT row_number() OVER (ORDER BY care_site_ident) AS care_site_id,
       care_site_ident, organization_id
FROM v_care_site;

CREATE OR REPLACE TABLE xref_provider AS
SELECT row_number() OVER (ORDER BY provider_ident) AS provider_id,
       provider_ident, practitioner_id
FROM v_provider;

INSERT INTO care_site
    (care_site_id, care_site_name, place_of_service_concept_id, location_id,
     care_site_source_value, place_of_service_source_value)
SELECT x.care_site_id, c.care_site_name, NULL, NULL, c.care_site_ident, NULL
FROM v_care_site c
JOIN xref_care_site x ON x.care_site_ident = c.care_site_ident;

INSERT INTO provider
    (provider_id, provider_name, npi, dea, specialty_concept_id, care_site_id,
     year_of_birth, gender_concept_id, provider_source_value,
     specialty_source_value, specialty_source_concept_id,
     gender_source_value, gender_source_concept_id)
SELECT
    x.provider_id,
    trim(COALESCE(p.given_name,'') || ' ' || COALESCE(p.family_name,'')),
    CASE WHEN p.provider_ident_system LIKE '%us-npi' THEN p.provider_ident END,
    NULL, NULL, NULL, NULL, NULL,
    p.provider_ident,
    NULL, NULL, NULL, NULL
FROM v_provider p
JOIN xref_provider x ON x.provider_ident = p.provider_ident;
