-- ETL audit tables. The most interesting artifacts in the repo.
--
-- TWO TABLES, NOT ONE, AND DELIBERATELY SO.
--
-- etl_rejects       - rows we could not map. Real loss.
-- etl_out_of_scope  - rows correctly routed elsewhere. NOT loss.
--
-- Survey and social-history Observations belong in OMOP's observation table, which is
-- outside this project's scope. They were not lost; they were sent somewhere we do not
-- build. Folding them into the reject count would overstate the loss figure, and a
-- single table with a disposition flag makes that mistake easy to commit by accident.
-- Two tables make conflating them an active choice rather than a slip.
--
-- etl_expansion tracks legitimate one-to-many mapping (a blood pressure panel becoming
-- a systolic row and a diastolic row). Without it the reconciliation identity
-- source = mapped + rejected fails, and an expansion is indistinguishable from a
-- duplicate.

DROP TABLE IF EXISTS etl_rejects;
CREATE TABLE etl_rejects (
    reject_id            BIGINT,
    source_resource_type VARCHAR NOT NULL,  -- FHIR resourceType
    source_id            VARCHAR,           -- resource.id
    source_full_url      VARCHAR,           -- urn:uuid: form, joins back to staging
    target_table         VARCHAR NOT NULL,  -- OMOP table it was headed for
    reason_code          VARCHAR NOT NULL,  -- controlled vocabulary, see below
    reason_detail        VARCHAR,           -- the specific value that failed
    source_row_json      JSON               -- full original resource, for audit
);

-- reason_code controlled values. Kept short and mutually exclusive so that
-- "top reasons per domain" in the loss analysis is a clean group-by.
--
--   MISSING_REQUIRED_FIELD  source lacks a field OMOP declares NOT NULL
--   UNRESOLVED_REFERENCE    subject/encounter reference points at nothing we staged
--   NO_SOURCE_CODE          resource carried no code at all
--   UNPARSEABLE_DATE        datetime string could not be parsed
--   IMPLAUSIBLE_DATE        parsed but clinically impossible (e.g. before birth)
--   NO_TARGET_COLUMN        data exists but OMOP has nowhere to put it
--
-- Note what is NOT a reject reason: failing to map a source code to an OMOP concept.
-- That row still loads, with concept_id = 0 and its *_source_value populated. It is
-- bucket 2 - structured but not computable - and counting it as a reject would
-- misrepresent both numbers.

DROP TABLE IF EXISTS etl_out_of_scope;
CREATE TABLE etl_out_of_scope (
    source_resource_type VARCHAR NOT NULL,
    source_id            VARCHAR,
    source_full_url      VARCHAR,
    correct_omop_table   VARCHAR NOT NULL,  -- where it SHOULD go in a full CDM
    reason               VARCHAR NOT NULL
);

DROP TABLE IF EXISTS etl_expansion;
CREATE TABLE etl_expansion (
    source_resource_type VARCHAR NOT NULL,
    source_id            VARCHAR,
    target_table         VARCHAR NOT NULL,
    n_target_rows        INTEGER NOT NULL,  -- >1 means this source row expanded
    expansion_reason     VARCHAR NOT NULL
);
