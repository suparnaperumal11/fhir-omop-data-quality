-- v_care_site / v_provider - the dimension sources.
--
-- These come from the hospitalInformation and practitionerInformation bundles, not
-- from patient bundles. Their business identifier is what the Encounter conditional
-- references point at, so identifier[0].value is the join key, not the resource id.

CREATE OR REPLACE VIEW v_care_site AS
SELECT
    o.organization_id,
    o.full_url,
    o.name                                                    AS care_site_name,
    json_extract_string(o.identifier_json, '$[0].value')      AS care_site_ident,
    json_extract_string(o.address_json, '$[0].city')          AS city,
    json_extract_string(o.address_json, '$[0].state')         AS state
FROM stg_organization o;

CREATE OR REPLACE VIEW v_provider AS
SELECT
    p.practitioner_id,
    p.full_url,
    -- Practitioner.name is an array of HumanName objects, not a string.
    COALESCE(
        json_extract_string(p.name_col, '$[0].family'),
        ''
    ) AS family_name,
    json_extract_string(p.name_col, '$[0].given[0]')          AS given_name,
    json_extract_string(p.identifier_json, '$[0].value')      AS provider_ident,
    json_extract_string(p.identifier_json, '$[0].system')     AS provider_ident_system
FROM (SELECT practitioner_id, full_url, identifier_json,
             json_extract(resource_json, '$.name') AS name_col
      FROM stg_practitioner) p;
