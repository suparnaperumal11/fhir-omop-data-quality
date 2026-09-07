-- Vocabulary seed - ATTESTED CONCEPTS ONLY.
--
-- This file contains every OMOP concept_id this pipeline will ever assign. It is
-- deliberately short, and its shortness is the project's central finding.
--
-- WHY SO FEW. Mapping a SNOMED condition code such as 444814009 (viral sinusitis) to
-- an OMOP concept_id requires the Athena vocabulary tables, which are several GB and
-- out of scope. Without them the only way to populate a clinical concept_id would be
-- to invent a plausible-looking integer. A wrong concept_id does not announce itself:
-- it silently produces a dataset that looks mapped, passes a row count, and answers a
-- research question incorrectly. So every clinical code below the demographic layer
-- gets concept_id = 0 with its *_source_value populated - recorded as unmapped, which
-- is a true statement, rather than mapped-to-something-wrong, which is not.
--
-- The concepts here are the closed, stable sets: OMOP's demographic and visit
-- concepts, which are part of the CDM specification itself rather than a downloaded
-- vocabulary release, and are stable across vocabulary versions.
--
-- WHAT IS DELIBERATELY ABSENT: no SNOMED condition concepts, no RxNorm drug concepts,
-- no LOINC measurement concepts. 259 + 189 + 238 distinct source codes across those
-- three domains, all landing at concept_id = 0. Checks CMP-04, CMP-05 and CMP-06 will
-- fail against their day-1 thresholds because of it. The thresholds were not relaxed.

DELETE FROM concept;
DELETE FROM source_to_concept_map;

-- ---------------------------------------------------------------- concepts
INSERT INTO concept
    (concept_id, concept_name, domain_id, vocabulary_id, concept_class_id,
     standard_concept, concept_code, valid_start_date, valid_end_date, invalid_reason)
VALUES
    -- Gender. OMOP CDM demographic concepts.
    (8507, 'MALE',   'Gender', 'Gender', 'Gender', 'S', 'M', DATE '1970-01-01', DATE '2099-12-31', NULL),
    (8532, 'FEMALE', 'Gender', 'Gender', 'Gender', 'S', 'F', DATE '1970-01-01', DATE '2099-12-31', NULL),

    -- Race. OMOP Race domain, aligned to the OMB categories Synthea emits.
    (8527, 'White',                                     'Race', 'Race', 'Race', 'S', '5',    DATE '1970-01-01', DATE '2099-12-31', NULL),
    (8516, 'Black or African American',                 'Race', 'Race', 'Race', 'S', '3',    DATE '1970-01-01', DATE '2099-12-31', NULL),
    (8515, 'Asian',                                     'Race', 'Race', 'Race', 'S', '2',    DATE '1970-01-01', DATE '2099-12-31', NULL),
    (8557, 'Native Hawaiian or Other Pacific Islander', 'Race', 'Race', 'Race', 'S', '4',    DATE '1970-01-01', DATE '2099-12-31', NULL),
    (8657, 'American Indian or Alaska Native',          'Race', 'Race', 'Race', 'S', '1',    DATE '1970-01-01', DATE '2099-12-31', NULL),

    -- Ethnicity. OMOP models ethnicity as a two-value domain, which is itself a
    -- granularity loss relative to source systems that carry detailed categories.
    (38003563, 'Hispanic or Latino',     'Ethnicity', 'Ethnicity', 'Ethnicity', 'S', 'Hispanic',    DATE '1970-01-01', DATE '2099-12-31', NULL),
    (38003564, 'Not Hispanic or Latino', 'Ethnicity', 'Ethnicity', 'Ethnicity', 'S', 'Not Hispanic', DATE '1970-01-01', DATE '2099-12-31', NULL),

    -- Visit. OMOP Visit domain.
    (9201,   'Inpatient Visit',       'Visit', 'Visit', 'Visit', 'S', 'IP', DATE '1970-01-01', DATE '2099-12-31', NULL),
    (9202,   'Outpatient Visit',      'Visit', 'Visit', 'Visit', 'S', 'OP', DATE '1970-01-01', DATE '2099-12-31', NULL),
    (9203,   'Emergency Room Visit',  'Visit', 'Visit', 'Visit', 'S', 'ER', DATE '1970-01-01', DATE '2099-12-31', NULL),
    (581476, 'Home Visit',            'Visit', 'Visit', 'Visit', 'S', 'HV', DATE '1970-01-01', DATE '2099-12-31', NULL),

    -- Type concept. Records the provenance of a row rather than its clinical meaning.
    (32817, 'EHR', 'Type Concept', 'Type Concept', 'Type Concept', 'S', 'OMOP4976890', DATE '1970-01-01', DATE '2099-12-31', NULL),

    -- The explicit "no mapping" concept. OMOP reserves 0 for exactly this, and using
    -- it is an assertion - "we looked and found nothing" - not an absence.
    (0, 'No matching concept', 'Metadata', 'None', 'Undefined', NULL, 'No matching concept', DATE '1970-01-01', DATE '2099-12-31', NULL);

-- ------------------------------------------------- source-to-concept mappings
-- One row per mapping decision, inspectable, rather than CASE statements scattered
-- through the mapping SQL.

INSERT INTO source_to_concept_map
    (source_code, source_concept_id, source_vocabulary_id, source_code_description,
     target_concept_id, target_vocabulary_id, valid_start_date, valid_end_date, invalid_reason)
VALUES
    -- FHIR administrative gender -> OMOP Gender.
    -- FHIR permits male | female | other | unknown. OMOP's Gender domain has two
    -- standard values. 'other' and 'unknown' therefore have nowhere to go and map to
    -- 0 - a real granularity loss, small here only because Synthea emits neither.
    ('male',   0, 'FHIR.administrative-gender', 'male',   8507, 'Gender', DATE '1970-01-01', DATE '2099-12-31', NULL),
    ('female', 0, 'FHIR.administrative-gender', 'female', 8532, 'Gender', DATE '1970-01-01', DATE '2099-12-31', NULL),

    -- US Core race (OMB categories, urn:oid:2.16.840.1.113883.6.238) -> OMOP Race.
    -- 'UNK' is left unmapped on purpose: OMOP has no standard Race concept meaning
    -- "unknown", and inventing one would convert missing data into a positive claim.
    ('2106-3', 0, 'US-Core.race', 'White',                                     8527, 'Race', DATE '1970-01-01', DATE '2099-12-31', NULL),
    ('2054-5', 0, 'US-Core.race', 'Black or African American',                 8516, 'Race', DATE '1970-01-01', DATE '2099-12-31', NULL),
    ('2028-9', 0, 'US-Core.race', 'Asian',                                     8515, 'Race', DATE '1970-01-01', DATE '2099-12-31', NULL),
    ('2076-8', 0, 'US-Core.race', 'Native Hawaiian or Other Pacific Islander', 8557, 'Race', DATE '1970-01-01', DATE '2099-12-31', NULL),
    ('1002-5', 0, 'US-Core.race', 'American Indian or Alaska Native',          8657, 'Race', DATE '1970-01-01', DATE '2099-12-31', NULL),

    -- US Core ethnicity -> OMOP Ethnicity.
    ('2135-2', 0, 'US-Core.ethnicity', 'Hispanic or Latino',     38003563, 'Ethnicity', DATE '1970-01-01', DATE '2099-12-31', NULL),
    ('2186-5', 0, 'US-Core.ethnicity', 'Not Hispanic or Latino', 38003564, 'Ethnicity', DATE '1970-01-01', DATE '2099-12-31', NULL),

    -- FHIR v3-ActCode encounter class -> OMOP Visit.
    -- 'VR' (virtual) is NOT mapped. OMOP's telehealth representation is not part of
    -- the stable CDM concept set and I will not assert an id I cannot attest to.
    -- 122 encounters are affected and are reported as unmapped rather than guessed.
    ('AMB',  0, 'FHIR.v3-ActCode', 'ambulatory',       9202,   'Visit', DATE '1970-01-01', DATE '2099-12-31', NULL),
    ('EMER', 0, 'FHIR.v3-ActCode', 'emergency',        9203,   'Visit', DATE '1970-01-01', DATE '2099-12-31', NULL),
    ('IMP',  0, 'FHIR.v3-ActCode', 'inpatient',        9201,   'Visit', DATE '1970-01-01', DATE '2099-12-31', NULL),
    ('HH',   0, 'FHIR.v3-ActCode', 'home health',      581476, 'Visit', DATE '1970-01-01', DATE '2099-12-31', NULL);
