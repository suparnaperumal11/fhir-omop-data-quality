-- Loss analysis. The deliverable.
--
-- Answers: what proportion of clinical data survives the mapping, and what exactly
-- is lost?
--
-- THREE BUCKETS, NEVER COLLAPSED:
--   1. Structured and computable    - loaded with a real concept_id. A researcher can
--                                     query it by concept.
--   2. Structured but not computable- loaded with concept_id = 0 and a populated
--                                     *_source_value. Present, auditable, and INVISIBLE
--                                     to any concept-based cohort query.
--   3. Could not be structured      - in etl_rejects. Never reached the CDM.
--
-- Out-of-scope rows are reported separately from all three. They were correctly routed
-- elsewhere, not lost, and folding them into bucket 3 would overstate the loss figure.
--
-- Bucket 2 is the one that misleads. A pipeline reporting "100% of rows loaded" while
-- every row carries concept_id = 0 has moved data without making it usable. The gap
-- between bucket 1 and bucket 2 is the difference between a dataset that answers a
-- research question and one that merely appears to.

DROP TABLE IF EXISTS loss_by_domain;
CREATE TABLE loss_by_domain AS
WITH per_domain AS (
    SELECT
        'Condition -> condition_occurrence' AS domain,
        (SELECT count(*) FROM stg_condition)                                            AS source_rows,
        (SELECT count(*) FROM condition_occurrence)                                     AS target_rows,
        (SELECT count(*) FROM condition_occurrence WHERE condition_concept_id <> 0)     AS bucket1_computable,
        (SELECT count(*) FROM condition_occurrence WHERE condition_concept_id  = 0)     AS bucket2_not_computable,
        (SELECT count(DISTINCT source_id) FROM etl_rejects WHERE target_table='condition_occurrence') AS bucket3_rejected,
        (SELECT count(DISTINCT source_id) FROM etl_out_of_scope WHERE source_resource_type='Condition') AS out_of_scope
    UNION ALL SELECT
        'MedicationRequest -> drug_exposure',
        (SELECT count(*) FROM stg_medicationrequest),
        (SELECT count(*) FROM drug_exposure),
        (SELECT count(*) FROM drug_exposure WHERE drug_concept_id <> 0),
        (SELECT count(*) FROM drug_exposure WHERE drug_concept_id  = 0),
        (SELECT count(DISTINCT source_id) FROM etl_rejects WHERE target_table='drug_exposure'),
        (SELECT count(DISTINCT source_id) FROM etl_out_of_scope WHERE source_resource_type='MedicationRequest')
    UNION ALL SELECT
        'Observation -> measurement',
        (SELECT count(*) FROM stg_observation),
        (SELECT count(*) FROM measurement),
        (SELECT count(*) FROM measurement WHERE measurement_concept_id <> 0),
        (SELECT count(*) FROM measurement WHERE measurement_concept_id  = 0),
        (SELECT count(DISTINCT source_id) FROM etl_rejects WHERE target_table='measurement'),
        (SELECT count(DISTINCT source_id) FROM etl_out_of_scope WHERE source_resource_type='Observation')
    UNION ALL SELECT
        'Encounter -> visit_occurrence',
        (SELECT count(*) FROM stg_encounter),
        (SELECT count(*) FROM visit_occurrence),
        (SELECT count(*) FROM visit_occurrence WHERE visit_concept_id <> 0),
        (SELECT count(*) FROM visit_occurrence WHERE visit_concept_id  = 0),
        (SELECT count(DISTINCT source_id) FROM etl_rejects WHERE target_table='visit_occurrence'),
        0
    UNION ALL SELECT
        'Patient -> person',
        (SELECT count(*) FROM stg_patient),
        (SELECT count(*) FROM person),
        (SELECT count(*) FROM person WHERE race_concept_id <> 0),
        (SELECT count(*) FROM person WHERE race_concept_id  = 0),
        (SELECT count(DISTINCT source_id) FROM etl_rejects WHERE target_table='person'),
        0
)
SELECT
    domain, source_rows, target_rows,
    target_rows - (source_rows - bucket3_rejected - out_of_scope) AS expansion_rows,
    bucket1_computable, bucket2_not_computable, bucket3_rejected, out_of_scope,
    round(100.0 * bucket1_computable / nullif(target_rows, 0), 2) AS pct_computable,
    round(100.0 * bucket2_not_computable / nullif(target_rows, 0), 2) AS pct_loaded_but_not_computable,
    -- reconciliation must hold: source = mapped + rejected + out_of_scope
    source_rows - bucket3_rejected - out_of_scope
        - (target_rows - (target_rows - (source_rows - bucket3_rejected - out_of_scope))) AS reconciliation_residual
FROM per_domain;

-- Reject reasons per domain. Empty is a result too: zero rejects across 695,394 source
-- rows says Synthea emits structurally well-formed FHIR, not that the reject path is
-- untested - the path exists and is exercised by the same predicates that count them.
DROP TABLE IF EXISTS loss_reject_reasons;
CREATE TABLE loss_reject_reasons AS
SELECT target_table, reason_code, count(*) AS n_rows
FROM etl_rejects GROUP BY target_table, reason_code;

DROP TABLE IF EXISTS loss_out_of_scope_reasons;
CREATE TABLE loss_out_of_scope_reasons AS
SELECT correct_omop_table, reason, count(*) AS n_rows
FROM etl_out_of_scope GROUP BY correct_omop_table, reason;

-- Headline: one row, the number the whole project exists to produce.
DROP TABLE IF EXISTS loss_headline;
CREATE TABLE loss_headline AS
SELECT
    sum(source_rows)                                   AS source_rows_in_scope_domains,
    sum(out_of_scope)                                  AS routed_elsewhere,
    sum(bucket3_rejected)                              AS could_not_structure,
    sum(target_rows)                                   AS rows_loaded_to_cdm,
    sum(bucket1_computable)                            AS computable,
    sum(bucket2_not_computable)                        AS loaded_but_not_computable,
    round(100.0 * sum(bucket1_computable) / nullif(sum(target_rows), 0), 2) AS pct_computable
FROM loss_by_domain;
