-- Conformance checks. Thresholds all 0% - these are guarantees the ETL controls.
--
-- READ THESE WITH THE REJECT COUNTS. Because the DDL declares NOT NULL, a row that
-- could not supply a required field was never inserted; it went to etl_rejects. So a
-- clean conformance section does not mean nothing went wrong - it means whatever went
-- wrong was diverted rather than admitted. Conformance measures what got IN.

DELETE FROM dq_results WHERE category = 'Conformance';

-- CON-01  person_id NOT NULL and unique
INSERT INTO dq_results
SELECT 'CON-01', 'person_id is NOT NULL and unique', 'Conformance', 'person.person_id',
       count(*),
       count(*) - count(DISTINCT person_id) + count(*) FILTER (WHERE person_id IS NULL),
       0.0
FROM person;

-- CON-02  primary key unique in every target table
INSERT INTO dq_results
SELECT 'CON-02', 'Primary key unique in every target table', 'Conformance', 'all six tables',
       (SELECT count(*) FROM person) + (SELECT count(*) FROM visit_occurrence)
     + (SELECT count(*) FROM condition_occurrence) + (SELECT count(*) FROM drug_exposure)
     + (SELECT count(*) FROM measurement) + (SELECT count(*) FROM death),
       (SELECT count(*) - count(DISTINCT person_id)             FROM person)
     + (SELECT count(*) - count(DISTINCT visit_occurrence_id)    FROM visit_occurrence)
     + (SELECT count(*) - count(DISTINCT condition_occurrence_id) FROM condition_occurrence)
     + (SELECT count(*) - count(DISTINCT drug_exposure_id)       FROM drug_exposure)
     + (SELECT count(*) - count(DISTINCT measurement_id)         FROM measurement)
     + (SELECT count(*) - count(DISTINCT person_id)              FROM death),
       0.0;

-- CON-03  person_id on every clinical row resolves to a person
INSERT INTO dq_results
WITH clinical AS (
    SELECT person_id FROM visit_occurrence
    UNION ALL SELECT person_id FROM condition_occurrence
    UNION ALL SELECT person_id FROM drug_exposure
    UNION ALL SELECT person_id FROM measurement
)
SELECT 'CON-03', 'person_id on clinical rows resolves to a person', 'Conformance',
       '4 clinical tables',
       count(*), count(*) FILTER (WHERE p.person_id IS NULL), 0.0
FROM clinical c LEFT JOIN person p ON p.person_id = c.person_id;

-- CON-04  visit_occurrence_id, where non-NULL, resolves to a visit
INSERT INTO dq_results
WITH linked AS (
    SELECT visit_occurrence_id FROM condition_occurrence WHERE visit_occurrence_id IS NOT NULL
    UNION ALL SELECT visit_occurrence_id FROM drug_exposure WHERE visit_occurrence_id IS NOT NULL
    UNION ALL SELECT visit_occurrence_id FROM measurement   WHERE visit_occurrence_id IS NOT NULL
)
SELECT 'CON-04', 'Non-NULL visit_occurrence_id resolves to a visit', 'Conformance',
       '3 clinical tables',
       count(*), count(*) FILTER (WHERE v.visit_occurrence_id IS NULL), 0.0
FROM linked l LEFT JOIN visit_occurrence v ON v.visit_occurrence_id = l.visit_occurrence_id;

-- CON-05  gender_concept_id in the permitted set
INSERT INTO dq_results
SELECT 'CON-05', 'gender_concept_id in {8507, 8532, 0}', 'Conformance', 'person.gender_concept_id',
       count(*), count(*) FILTER (WHERE gender_concept_id NOT IN (8507, 8532, 0)), 0.0
FROM person;

-- CON-06  every *_concept_id is NOT NULL (0 is permitted and meaningful; NULL is not)
INSERT INTO dq_results
SELECT 'CON-06', 'Required *_concept_id columns are NOT NULL', 'Conformance', 'all six tables',
       (SELECT count(*) FROM person) + (SELECT count(*) FROM visit_occurrence)
     + (SELECT count(*) FROM condition_occurrence) + (SELECT count(*) FROM drug_exposure)
     + (SELECT count(*) FROM measurement),
       (SELECT count(*) FROM person WHERE gender_concept_id IS NULL OR race_concept_id IS NULL
                                        OR ethnicity_concept_id IS NULL)
     + (SELECT count(*) FROM visit_occurrence     WHERE visit_concept_id IS NULL     OR visit_type_concept_id IS NULL)
     + (SELECT count(*) FROM condition_occurrence WHERE condition_concept_id IS NULL OR condition_type_concept_id IS NULL)
     + (SELECT count(*) FROM drug_exposure        WHERE drug_concept_id IS NULL      OR drug_type_concept_id IS NULL)
     + (SELECT count(*) FROM measurement          WHERE measurement_concept_id IS NULL OR measurement_type_concept_id IS NULL),
       0.0;

-- CON-07  source datetime strings that were present but did not parse
-- Measured at the source, not the target: a string that failed to parse never became
-- a row, so checking the target would find nothing by construction.
INSERT INTO dq_results
WITH raw AS (
    SELECT effective_datetime AS s FROM stg_observation
    UNION ALL SELECT period_start FROM stg_encounter
    UNION ALL SELECT period_end   FROM stg_encounter
    UNION ALL SELECT onset_datetime FROM stg_condition
    UNION ALL SELECT authored_on    FROM stg_medicationrequest
    UNION ALL SELECT deceased_datetime FROM stg_patient
)
SELECT 'CON-07', 'Source datetime strings parse to a valid timestamp', 'Conformance',
       'all source datetimes',
       count(*), count(*) FILTER (WHERE TRY_CAST(s AS TIMESTAMPTZ) IS NULL), 0.0
FROM raw WHERE s IS NOT NULL;

-- CON-08  *_datetime falls on the same calendar day as its *_date
-- This is the timezone check. It passes only because conversion happens before the
-- date is taken; naive string truncation would fail it on 42% of rows.
INSERT INTO dq_results
WITH pairs AS (
    SELECT visit_start_date d, visit_start_datetime t FROM visit_occurrence
    UNION ALL SELECT visit_end_date, visit_end_datetime FROM visit_occurrence
    UNION ALL SELECT condition_start_date, condition_start_datetime FROM condition_occurrence
    UNION ALL SELECT drug_exposure_start_date, drug_exposure_start_datetime FROM drug_exposure
    UNION ALL SELECT measurement_date, measurement_datetime FROM measurement
    UNION ALL SELECT death_date, death_datetime FROM death
)
SELECT 'CON-08', '*_datetime falls on the same day as *_date', 'Conformance', 'all six tables',
       count(*), count(*) FILTER (WHERE t::DATE <> d), 0.0
FROM pairs WHERE t IS NOT NULL AND d IS NOT NULL;

-- CON-09  *_source_value populated wherever the source carried a code
INSERT INTO dq_results
SELECT 'CON-09', '*_source_value populated where a source code existed', 'Conformance',
       'condition, drug, measurement',
       (SELECT count(*) FROM condition_occurrence) + (SELECT count(*) FROM drug_exposure)
     + (SELECT count(*) FROM measurement),
       (SELECT count(*) FROM condition_occurrence WHERE condition_source_value IS NULL)
     + (SELECT count(*) FROM drug_exposure        WHERE drug_source_value IS NULL)
     + (SELECT count(*) FROM measurement          WHERE measurement_source_value IS NULL),
       0.0;

-- CON-10  visit_concept_id belongs to the OMOP Visit domain (or is 0)
INSERT INTO dq_results
SELECT 'CON-10', 'visit_concept_id in the Visit domain', 'Conformance',
       'visit_occurrence.visit_concept_id',
       count(*),
       count(*) FILTER (WHERE v.visit_concept_id <> 0 AND c.concept_id IS NULL),
       0.0
FROM visit_occurrence v
LEFT JOIN concept c ON c.concept_id = v.visit_concept_id AND c.domain_id = 'Visit';

-- CON-11  unit_concept_id NOT NULL where a UCUM unit was present
INSERT INTO dq_results
SELECT 'CON-11', 'unit_concept_id set where a unit was supplied', 'Conformance',
       'measurement.unit_concept_id',
       count(*), count(*) FILTER (WHERE unit_concept_id IS NULL), 0.0
FROM measurement WHERE unit_source_value IS NOT NULL;
