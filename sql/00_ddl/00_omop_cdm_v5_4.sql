-- OMOP CDM v5.4 - target tables
--
-- Scope: the five clinical tables in the brief, plus death (OMOP models death in its
-- own table, and the required plausibility checks PLA-02..PLA-06 need it), plus
-- care_site and provider as dimension tables so that visit_occurrence.care_site_id
-- and provider_id resolve to something rather than dangling as bare integers.
--
-- Two deliberate departures from a production OMOP deploy:
--
-- 1. NO PRIMARY KEY OR FOREIGN KEY CONSTRAINTS. OHDSI ships constraints as a separate
--    post-load script, and here that separation is load-bearing: if the database
--    enforced uniqueness on person_id, check CON-02 could never fail and would be
--    measuring nothing. Leaving them unenforced keeps the conformance checks honest.
--
-- 2. NOT NULL IS KEPT, because it is part of "correctly typed" - and because it forces
--    the reject path. A row that cannot supply a required field cannot be inserted,
--    so it must be routed to etl_rejects with a reason rather than landing as a NULL.
--    Consequence when reading results: conformance checks on NOT NULL columns are
--    expected to report 0 failures, and the interesting number is the matching reject
--    count. The two must be read together or the pipeline looks cleaner than it is.
--
-- location is NOT created. Patient address is not mapped (out of scope), so
-- person.location_id and care_site.location_id stay NULL. Recorded as a documented
-- exclusion in the loss report, not a silent gap.

DROP TABLE IF EXISTS person;
CREATE TABLE person (
    person_id                   BIGINT      NOT NULL,
    gender_concept_id           INTEGER     NOT NULL,
    year_of_birth               INTEGER     NOT NULL,
    month_of_birth              INTEGER,
    day_of_birth                INTEGER,
    birth_datetime              TIMESTAMP,
    race_concept_id             INTEGER     NOT NULL,
    ethnicity_concept_id        INTEGER     NOT NULL,
    location_id                 BIGINT,
    provider_id                 BIGINT,
    care_site_id                BIGINT,
    person_source_value         VARCHAR,
    gender_source_value         VARCHAR,
    gender_source_concept_id    INTEGER,
    race_source_value           VARCHAR,
    race_source_concept_id      INTEGER,
    ethnicity_source_value      VARCHAR,
    ethnicity_source_concept_id INTEGER
);

DROP TABLE IF EXISTS death;
CREATE TABLE death (
    person_id               BIGINT  NOT NULL,
    death_date              DATE    NOT NULL,
    death_datetime          TIMESTAMP,
    death_type_concept_id   INTEGER,
    cause_concept_id        INTEGER,
    cause_source_value      VARCHAR,
    cause_source_concept_id INTEGER
);

DROP TABLE IF EXISTS visit_occurrence;
CREATE TABLE visit_occurrence (
    visit_occurrence_id           BIGINT    NOT NULL,
    person_id                     BIGINT    NOT NULL,
    visit_concept_id              INTEGER   NOT NULL,
    visit_start_date              DATE      NOT NULL,
    visit_start_datetime          TIMESTAMP,
    visit_end_date                DATE      NOT NULL,
    visit_end_datetime            TIMESTAMP,
    visit_type_concept_id         INTEGER   NOT NULL,
    provider_id                   BIGINT,
    care_site_id                  BIGINT,
    visit_source_value            VARCHAR,
    visit_source_concept_id       INTEGER,
    admitted_from_concept_id      INTEGER,
    admitted_from_source_value    VARCHAR,
    discharged_to_concept_id      INTEGER,
    discharged_to_source_value    VARCHAR,
    preceding_visit_occurrence_id BIGINT
);

DROP TABLE IF EXISTS condition_occurrence;
CREATE TABLE condition_occurrence (
    condition_occurrence_id       BIGINT    NOT NULL,
    person_id                     BIGINT    NOT NULL,
    condition_concept_id          INTEGER   NOT NULL,
    condition_start_date          DATE      NOT NULL,
    condition_start_datetime      TIMESTAMP,
    condition_end_date            DATE,
    condition_end_datetime        TIMESTAMP,
    condition_type_concept_id     INTEGER   NOT NULL,
    condition_status_concept_id   INTEGER,
    stop_reason                   VARCHAR,
    provider_id                   BIGINT,
    visit_occurrence_id           BIGINT,
    visit_detail_id               BIGINT,
    condition_source_value        VARCHAR,
    condition_source_concept_id   INTEGER,
    condition_status_source_value VARCHAR
);

DROP TABLE IF EXISTS drug_exposure;
CREATE TABLE drug_exposure (
    drug_exposure_id              BIGINT    NOT NULL,
    person_id                     BIGINT    NOT NULL,
    drug_concept_id               INTEGER   NOT NULL,
    drug_exposure_start_date      DATE      NOT NULL,
    drug_exposure_start_datetime  TIMESTAMP,
    drug_exposure_end_date        DATE      NOT NULL,
    drug_exposure_end_datetime    TIMESTAMP,
    verbatim_end_date             DATE,
    drug_type_concept_id          INTEGER   NOT NULL,
    stop_reason                   VARCHAR,
    refills                       INTEGER,
    quantity                      DOUBLE,
    days_supply                   INTEGER,
    sig                           VARCHAR,
    route_concept_id              INTEGER,
    lot_number                    VARCHAR,
    provider_id                   BIGINT,
    visit_occurrence_id           BIGINT,
    visit_detail_id               BIGINT,
    drug_source_value             VARCHAR,
    drug_source_concept_id        INTEGER,
    route_source_value            VARCHAR,
    dose_unit_source_value        VARCHAR
);

DROP TABLE IF EXISTS measurement;
CREATE TABLE measurement (
    measurement_id                BIGINT    NOT NULL,
    person_id                     BIGINT    NOT NULL,
    measurement_concept_id        INTEGER   NOT NULL,
    measurement_date              DATE      NOT NULL,
    measurement_datetime          TIMESTAMP,
    measurement_time              VARCHAR,
    measurement_type_concept_id   INTEGER   NOT NULL,
    operator_concept_id           INTEGER,
    value_as_number               DOUBLE,
    value_as_concept_id           INTEGER,
    unit_concept_id               INTEGER,
    range_low                     DOUBLE,
    range_high                    DOUBLE,
    provider_id                   BIGINT,
    visit_occurrence_id           BIGINT,
    visit_detail_id               BIGINT,
    measurement_source_value      VARCHAR,
    measurement_source_concept_id INTEGER,
    unit_source_value             VARCHAR,
    unit_source_concept_id        INTEGER,
    value_source_value            VARCHAR,
    measurement_event_id          BIGINT,
    meas_event_field_concept_id   INTEGER
);

-- ---------------------------------------------------------------- dimensions

DROP TABLE IF EXISTS care_site;
CREATE TABLE care_site (
    care_site_id                  BIGINT  NOT NULL,
    care_site_name                VARCHAR,
    place_of_service_concept_id   INTEGER,
    location_id                   BIGINT,
    care_site_source_value        VARCHAR,
    place_of_service_source_value VARCHAR
);

DROP TABLE IF EXISTS provider;
CREATE TABLE provider (
    provider_id                 BIGINT  NOT NULL,
    provider_name               VARCHAR,
    npi                         VARCHAR,
    dea                         VARCHAR,
    specialty_concept_id        INTEGER,
    care_site_id                BIGINT,
    year_of_birth               INTEGER,
    gender_concept_id           INTEGER,
    provider_source_value       VARCHAR,
    specialty_source_value      VARCHAR,
    specialty_source_concept_id INTEGER,
    gender_source_value         VARCHAR,
    gender_source_concept_id    INTEGER
);
