-- Data quality result tables.
--
-- Every check writes raw counts here - a denominator and a numerator - and NOTHING
-- ELSE. The percentage and the PASS/FAIL verdict are derived in v_dq_report, in one
-- place, so that the rule cannot drift between checks.
--
-- THE ZERO-DENOMINATOR RULE lives here too. A check evaluating 0 rows reports
-- NOT_EVALUATED, never PASS. An empty table must not be able to pass a quality check
-- by vacuous truth - that is how a broken pipeline produces a clean report.

DROP TABLE IF EXISTS dq_results;
CREATE TABLE dq_results (
    check_id       VARCHAR NOT NULL,
    check_name     VARCHAR NOT NULL,
    category       VARCHAR NOT NULL,
    target         VARCHAR NOT NULL,
    rows_evaluated BIGINT  NOT NULL,
    rows_failed    BIGINT  NOT NULL,
    threshold_pct  DOUBLE  NOT NULL
);

CREATE OR REPLACE VIEW v_dq_report AS
SELECT
    check_id, check_name, category, target,
    rows_evaluated,
    rows_failed,
    CASE WHEN rows_evaluated = 0 THEN NULL
         ELSE round(100.0 * rows_failed / rows_evaluated, 3) END AS pct_failed,
    threshold_pct,
    CASE
        WHEN rows_evaluated = 0                                        THEN 'NOT_EVALUATED'
        WHEN 100.0 * rows_failed / rows_evaluated <= threshold_pct     THEN 'PASS'
        ELSE 'FAIL'
    END AS status
FROM dq_results;
