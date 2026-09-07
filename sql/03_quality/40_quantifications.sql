-- Quantifications - reported, not pass/fail.
--
-- These have no threshold because there is no correct value to hold them to. The
-- measurement IS the result.

-- ---------------------------------------------------------------------- Q-01
-- Rows whose calendar date changes depending on whether you convert the timezone or
-- truncate the raw string. This is the single most important number in the repo: it
-- is what happens when an ETL ignores timezone, measured rather than asserted.
DROP TABLE IF EXISTS q01_timezone_shift;
CREATE TABLE q01_timezone_shift AS
WITH src AS (
    SELECT 'Observation.effective'  AS domain, effective_datetime AS ts FROM stg_observation
    UNION ALL SELECT 'Encounter.start',   period_start      FROM stg_encounter
    UNION ALL SELECT 'Encounter.end',     period_end        FROM stg_encounter
    UNION ALL SELECT 'Condition.onset',   onset_datetime    FROM stg_condition
    UNION ALL SELECT 'MedicationRequest.authoredOn', authored_on FROM stg_medicationrequest
    UNION ALL SELECT 'Patient.deceased',  deceased_datetime FROM stg_patient
)
SELECT
    domain,
    count(*) AS rows_evaluated,
    count(*) FILTER (
        WHERE substr(ts, 1, 10)::DATE
           <> (ts::TIMESTAMPTZ AT TIME ZONE 'America/New_York')::DATE
    ) AS rows_shifted_one_day,
    round(100.0 * count(*) FILTER (
        WHERE substr(ts, 1, 10)::DATE
           <> (ts::TIMESTAMPTZ AT TIME ZONE 'America/New_York')::DATE
    ) / count(*), 2) AS pct_shifted
FROM src WHERE ts IS NOT NULL
GROUP BY domain;

-- ---------------------------------------------------------------------- Q-02
-- Vocabulary coverage, reported BY DISTINCT CODE and BY ROW separately. The two
-- differ sharply in general, and quoting only the flattering one misrepresents it.
DROP TABLE IF EXISTS q02_code_coverage;
CREATE TABLE q02_code_coverage AS
WITH d AS (
    SELECT 'Condition (SNOMED)' AS domain, condition_source_value AS code,
           condition_concept_id AS concept_id FROM condition_occurrence
    UNION ALL SELECT 'Drug (RxNorm)', drug_source_value, drug_concept_id FROM drug_exposure
    UNION ALL SELECT 'Measurement (LOINC)', measurement_source_value, measurement_concept_id FROM measurement
    UNION ALL SELECT 'Visit (v3-ActCode)', split_part(visit_source_value,'|',1), visit_concept_id FROM visit_occurrence
    UNION ALL SELECT 'Person race (OMB)', race_source_value, race_concept_id FROM person
    UNION ALL SELECT 'Person ethnicity (OMB)', ethnicity_source_value, ethnicity_concept_id FROM person
)
SELECT
    domain,
    count(DISTINCT code)                                     AS distinct_codes,
    count(DISTINCT code) FILTER (WHERE concept_id <> 0)      AS distinct_codes_mapped,
    round(100.0 * count(DISTINCT code) FILTER (WHERE concept_id <> 0)
          / nullif(count(DISTINCT code), 0), 1)              AS pct_codes_mapped,
    count(*)                                                 AS rows_total,
    count(*) FILTER (WHERE concept_id <> 0)                  AS rows_mapped,
    round(100.0 * count(*) FILTER (WHERE concept_id <> 0)
          / nullif(count(*), 0), 1)                          AS pct_rows_mapped
FROM d
GROUP BY domain;

-- ---------------------------------------------------------------------- Q-03
-- The long tail, by row count. This IS the finding, not a gap in it.
-- The display-name lookups are collapsed to ONE ROW PER CODE first. Joining the fact
-- table straight to a view keyed on code multiplies every row by the number of source
-- rows sharing that code - a cartesian blow-up that reported 63 million rows in a
-- 38,668-row domain. Aggregate first, then join.
DROP TABLE IF EXISTS q03_top_unmapped;
CREATE TABLE q03_top_unmapped AS
WITH disp AS (
    SELECT 'Condition (SNOMED)' AS domain, code, any_value(code_display) AS display
    FROM v_condition GROUP BY code
    UNION ALL
    SELECT 'Drug (RxNorm)', code, any_value(code_display)
    FROM v_medication_request GROUP BY code
    UNION ALL
    SELECT 'Measurement (LOINC)', code, any_value(code_display)
    FROM v_observation GROUP BY code
),
counts AS (
    SELECT 'Condition (SNOMED)' AS domain, condition_source_value AS code, count(*) AS n_rows
    FROM condition_occurrence WHERE condition_concept_id = 0 GROUP BY code
    UNION ALL
    SELECT 'Drug (RxNorm)', drug_source_value, count(*)
    FROM drug_exposure WHERE drug_concept_id = 0 GROUP BY drug_source_value
    UNION ALL
    SELECT 'Measurement (LOINC)', measurement_source_value, count(*)
    FROM measurement WHERE measurement_concept_id = 0 GROUP BY measurement_source_value
)
SELECT c.domain, c.code, d.display, c.n_rows,
       row_number() OVER (PARTITION BY c.domain ORDER BY c.n_rows DESC) AS rank
FROM counts c
LEFT JOIN disp d ON d.domain = c.domain AND d.code = c.code
QUALIFY rank <= 25;

-- ---------------------------------------------------------------------- Q-04
-- CodeableConcepts where coding[] held more than one entry and we took [0],
-- discarding the rest. Small here; would not be small on real data.
DROP TABLE IF EXISTS q04_multi_coding;
CREATE TABLE q04_multi_coding AS
SELECT 'Condition' AS domain, count(*) AS rows_total,
       count(*) FILTER (WHERE coding_count > 1) AS rows_multi_coding
FROM v_condition
UNION ALL
SELECT 'Observation', count(*), count(*) FILTER (WHERE coding_count > 1) FROM v_observation;

-- ---------------------------------------------------------------------- Q-06
-- Granularity loss on race and ethnicity: distinct source values in, distinct OMOP
-- concepts out. Where these differ, source detail was collapsed.
DROP TABLE IF EXISTS q06_granularity;
CREATE TABLE q06_granularity AS
SELECT 'race' AS field, count(DISTINCT race_source_value) AS distinct_source_values,
       count(DISTINCT race_concept_id) AS distinct_target_concepts,
       count(DISTINCT race_source_value) FILTER (WHERE race_concept_id = 0) AS source_values_lost
FROM person
UNION ALL
SELECT 'ethnicity', count(DISTINCT ethnicity_source_value), count(DISTINCT ethnicity_concept_id),
       count(DISTINCT ethnicity_source_value) FILTER (WHERE ethnicity_concept_id = 0)
FROM person
UNION ALL
SELECT 'gender', count(DISTINCT gender_source_value), count(DISTINCT gender_concept_id),
       count(DISTINCT gender_source_value) FILTER (WHERE gender_concept_id = 0)
FROM person;
