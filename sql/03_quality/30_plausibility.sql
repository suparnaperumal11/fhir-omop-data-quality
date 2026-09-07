-- Plausibility checks - clinically impossible or internally contradictory values.
--
-- These are the checks the mapping deliberately does NOT pre-filter for. An ETL that
-- drops the rows its own quality checks look for makes those checks pass by
-- construction, which is worse than failing them.
--
-- PLA-03..PLA-06 exercise the 112 deceased patients.

DELETE FROM dq_results WHERE category = 'Plausibility';

-- PLA-01  age at any event < 120 years
INSERT INTO dq_results
WITH ev AS (
    SELECT person_id, visit_start_date d FROM visit_occurrence
    UNION ALL SELECT person_id, condition_start_date FROM condition_occurrence
    UNION ALL SELECT person_id, drug_exposure_start_date FROM drug_exposure
    UNION ALL SELECT person_id, measurement_date FROM measurement
)
SELECT 'PLA-01', 'Age at event < 120 years', 'Plausibility', 'all clinical tables',
       count(*), count(*) FILTER (WHERE date_diff('year', p.birth_datetime::DATE, ev.d) >= 120), 0.0
FROM ev JOIN person p USING (person_id);

-- PLA-02  death not before birth
INSERT INTO dq_results
SELECT 'PLA-02', 'death_date on or after birth', 'Plausibility', 'death.death_date',
       count(*), count(*) FILTER (WHERE d.death_date < p.birth_datetime::DATE), 0.0
FROM death d JOIN person p USING (person_id);

-- PLA-03..06  no clinical event after death
INSERT INTO dq_results
SELECT 'PLA-03', 'No condition starting after death', 'Plausibility', 'condition_occurrence',
       count(*), count(*) FILTER (WHERE c.condition_start_date > d.death_date), 0.0
FROM condition_occurrence c JOIN death d USING (person_id);

INSERT INTO dq_results
SELECT 'PLA-04', 'No drug exposure starting after death', 'Plausibility', 'drug_exposure',
       count(*), count(*) FILTER (WHERE x.drug_exposure_start_date > d.death_date), 0.0
FROM drug_exposure x JOIN death d USING (person_id);

INSERT INTO dq_results
SELECT 'PLA-05', 'No measurement after death', 'Plausibility', 'measurement',
       count(*), count(*) FILTER (WHERE m.measurement_date > d.death_date), 0.0
FROM measurement m JOIN death d USING (person_id);

INSERT INTO dq_results
SELECT 'PLA-06', 'No visit starting after death', 'Plausibility', 'visit_occurrence',
       count(*), count(*) FILTER (WHERE v.visit_start_date > d.death_date), 0.0
FROM visit_occurrence v JOIN death d USING (person_id);

-- PLA-07..09  interval sanity
INSERT INTO dq_results
SELECT 'PLA-07', 'visit_end_date >= visit_start_date', 'Plausibility', 'visit_occurrence',
       count(*), count(*) FILTER (WHERE visit_end_date < visit_start_date), 0.0
FROM visit_occurrence;

INSERT INTO dq_results
SELECT 'PLA-08', 'condition_end_date >= condition_start_date', 'Plausibility', 'condition_occurrence',
       count(*), count(*) FILTER (WHERE condition_end_date < condition_start_date), 0.0
FROM condition_occurrence WHERE condition_end_date IS NOT NULL;

INSERT INTO dq_results
SELECT 'PLA-09', 'drug_exposure_end_date >= start_date', 'Plausibility', 'drug_exposure',
       count(*), count(*) FILTER (WHERE drug_exposure_end_date < drug_exposure_start_date), 0.0
FROM drug_exposure;

-- PLA-10  no event before birth
INSERT INTO dq_results
WITH ev AS (
    SELECT person_id, visit_start_date d FROM visit_occurrence
    UNION ALL SELECT person_id, condition_start_date FROM condition_occurrence
    UNION ALL SELECT person_id, drug_exposure_start_date FROM drug_exposure
    UNION ALL SELECT person_id, measurement_date FROM measurement
)
SELECT 'PLA-10', 'Every event on or after birth', 'Plausibility', 'all clinical tables',
       count(*), count(*) FILTER (WHERE ev.d < p.birth_datetime::DATE), 0.0
FROM ev JOIN person p USING (person_id);

-- PLA-11  lab and vital values within physiological range
-- Ranges are deliberately wide: the aim is to catch impossible values, not unusual
-- ones. Joined on measurement_source_value because measurement_concept_id is 0 for
-- every row - which is itself a demonstration of what unmapped concepts cost you.
INSERT INTO dq_results
WITH ranges(code, lo, hi) AS (
    VALUES ('8302-2', 30.0, 250.0),    ('29463-7', 0.5, 350.0),
           ('39156-5', 8.0, 100.0),    ('8480-6', 40.0, 300.0),
           ('8462-4', 20.0, 200.0),    ('8867-4', 20.0, 300.0),
           ('9279-1', 4.0, 80.0),      ('2339-0', 10.0, 1500.0),
           ('2160-0', 0.1, 25.0),      ('718-7', 2.0, 25.0)
)
SELECT 'PLA-11', 'Lab/vital value within physiological range', 'Plausibility',
       'measurement.value_as_number',
       count(*), count(*) FILTER (WHERE m.value_as_number < r.lo OR m.value_as_number > r.hi), 1.0
FROM measurement m JOIN ranges r ON r.code = m.measurement_source_value
WHERE m.value_as_number IS NOT NULL;

-- PLA-12  measurement falls inside its linked visit
INSERT INTO dq_results
SELECT 'PLA-12', 'measurement_date within its linked visit period', 'Plausibility',
       'measurement vs visit_occurrence',
       count(*),
       count(*) FILTER (WHERE m.measurement_date < v.visit_start_date
                           OR m.measurement_date > v.visit_end_date), 5.0
FROM measurement m JOIN visit_occurrence v USING (visit_occurrence_id);
