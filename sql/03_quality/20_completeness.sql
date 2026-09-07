-- Completeness checks.
--
-- Thresholds here are TARGETS, not guarantees. A failure is a finding about the source
-- or about vocabulary coverage, not necessarily a defect in the pipeline.
--
-- CMP-04, CMP-05 and CMP-06 WILL FAIL, at roughly 100%. Every clinical code loads with
-- concept_id = 0 because resolving SNOMED/RxNorm/LOINC to OMOP concept_ids requires the
-- Athena vocabulary, which is out of scope. The thresholds (20/20/30%) were fixed on
-- day 1, before any mapping SQL existed, and have NOT been relaxed to accommodate that
-- decision. Lowering a threshold because you know you will miss it is how a quality
-- framework becomes decoration.

DELETE FROM dq_results WHERE category = 'Completeness';

INSERT INTO dq_results
SELECT 'CMP-01', 'birth_datetime populated', 'Completeness', 'person.birth_datetime',
       count(*), count(*) FILTER (WHERE birth_datetime IS NULL), 0.0 FROM person;

INSERT INTO dq_results
SELECT 'CMP-02', 'race_concept_id mapped (not 0)', 'Completeness', 'person.race_concept_id',
       count(*), count(*) FILTER (WHERE race_concept_id = 0), 5.0 FROM person;

INSERT INTO dq_results
SELECT 'CMP-03', 'ethnicity_concept_id mapped (not 0)', 'Completeness', 'person.ethnicity_concept_id',
       count(*), count(*) FILTER (WHERE ethnicity_concept_id = 0), 5.0 FROM person;

INSERT INTO dq_results
SELECT 'CMP-04', 'condition_concept_id mapped (not 0)', 'Completeness',
       'condition_occurrence.condition_concept_id',
       count(*), count(*) FILTER (WHERE condition_concept_id = 0), 20.0 FROM condition_occurrence;

INSERT INTO dq_results
SELECT 'CMP-05', 'drug_concept_id mapped (not 0)', 'Completeness', 'drug_exposure.drug_concept_id',
       count(*), count(*) FILTER (WHERE drug_concept_id = 0), 20.0 FROM drug_exposure;

INSERT INTO dq_results
SELECT 'CMP-06', 'measurement_concept_id mapped (not 0)', 'Completeness',
       'measurement.measurement_concept_id',
       count(*), count(*) FILTER (WHERE measurement_concept_id = 0), 30.0 FROM measurement;

INSERT INTO dq_results
SELECT 'CMP-07', 'visit_concept_id mapped (not 0)', 'Completeness',
       'visit_occurrence.visit_concept_id',
       count(*), count(*) FILTER (WHERE visit_concept_id = 0), 5.0 FROM visit_occurrence;

INSERT INTO dq_results
SELECT 'CMP-08', 'measurement has a value (number or concept)', 'Completeness',
       'measurement.value_as_*',
       count(*), count(*) FILTER (WHERE value_as_number IS NULL AND value_as_concept_id IS NULL),
       10.0 FROM measurement;

INSERT INTO dq_results
SELECT 'CMP-09', 'care_site_id populated', 'Completeness', 'visit_occurrence.care_site_id',
       count(*), count(*) FILTER (WHERE care_site_id IS NULL), 10.0 FROM visit_occurrence;

INSERT INTO dq_results
SELECT 'CMP-10', 'provider_id populated', 'Completeness', 'visit_occurrence.provider_id',
       count(*), count(*) FILTER (WHERE provider_id IS NULL), 10.0 FROM visit_occurrence;
