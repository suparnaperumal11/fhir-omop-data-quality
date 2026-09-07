-- v_patient - one typed row per FHIR Patient.
--
-- Maps:     stg_patient (raw JSON) -> clean typed columns
-- Assumes:  nothing about array ordering; see the sub-extension note below
-- Drops:    nothing. This view is 1:1 with stg_patient and must stay that way.
--
-- SQL NOTES (this file is the gentlest introduction in the repo, so the idioms used
-- everywhere else are explained here once):
--
--   WITH name AS (...)   A "CTE", or common table expression. A named intermediate
--                        result you can refer to below, like assigning to a variable.
--                        Used throughout this repo instead of nested subqueries
--                        because each step gets a name and can be read in order.
--
--   unnest(list)         Turns one row containing a list into many rows, one per
--                        element. FHIR nests arrays everywhere; this is how we get
--                        from "a patient with 7 extensions" to "7 rows".
--
--   x, unnest(...) AS e  A lateral join. For each row of x, expand its list. The
--                        comma is an implicit CROSS JOIN; because the right side
--                        refers to the left, it runs per row.
--
--   max(c) FILTER (...)  A conditional aggregate. Collapses many rows back to one,
--                        taking c only from rows matching the condition. This is how
--                        we pivot "one row per extension" back into "one row per
--                        patient, with a race column and an ethnicity column".
--
--   AT TIME ZONE         Converts an instant to wall-clock time in a named zone.
--                        See the timezone note below - this is the single most
--                        consequential expression in the whole pipeline.

CREATE OR REPLACE VIEW v_patient AS

-- Step 1: explode each patient's extension array into one row per extension.
WITH ext AS (
    SELECT
        p.patient_id,
        json_extract_string(e.value, '$.url') AS ext_url,
        e.value                               AS ext_json
    FROM stg_patient p,
         unnest(json_extract(p.extension_json, '$[*]')) AS e(value)
),

-- Step 2: explode the SUB-extension array inside the race/ethnicity extensions.
--
-- We deliberately do NOT write $.extension[0].valueCoding.code here. In this dataset
-- ombCategory does happen to be element 0 with 'text' second - but that is an
-- accident of how Synthea writes the file, not a guarantee of US Core. Reading by
-- position would work today and break silently on data that ordered them differently.
-- We match on the sub-extension's url instead, which is what actually identifies it.
sub AS (
    SELECT
        x.patient_id,
        x.ext_url,
        json_extract_string(s.value, '$.url')                  AS sub_url,
        json_extract_string(s.value, '$.valueCoding.code')     AS code,
        json_extract_string(s.value, '$.valueCoding.display')  AS display
    FROM ext x,
         unnest(json_extract(x.ext_json, '$.extension[*]')) AS s(value)
    WHERE x.ext_url LIKE '%us-core-race'
       OR x.ext_url LIKE '%us-core-ethnicity'
),

-- Step 3: pivot back to one row per patient.
demographics AS (
    SELECT
        patient_id,
        max(code)    FILTER (WHERE ext_url LIKE '%us-core-race'      AND sub_url = 'ombCategory') AS race_code,
        max(display) FILTER (WHERE ext_url LIKE '%us-core-race'      AND sub_url = 'ombCategory') AS race_display,
        max(code)    FILTER (WHERE ext_url LIKE '%us-core-ethnicity' AND sub_url = 'ombCategory') AS ethnicity_code,
        max(display) FILTER (WHERE ext_url LIKE '%us-core-ethnicity' AND sub_url = 'ombCategory') AS ethnicity_display
    FROM sub
    GROUP BY patient_id
)

SELECT
    p.patient_id,
    p.full_url,
    p.gender                                        AS gender_source_value,
    p.birth_date::DATE                              AS birth_date,

    -- birth_date is a date with no time component, so there is no timezone to convert.
    -- Midnight local is the only defensible reading of a date-only field.
    p.birth_date::TIMESTAMP                         AS birth_datetime,

    -- TIMEZONE CONVERSION. Every timestamp Synthea wrote carries the offset of the
    -- machine that generated it (+05:30, Asia/Kolkata) rather than the patients'
    -- Massachusetts local time. Casting to TIMESTAMPTZ reads the offset correctly and
    -- gives us the true instant; AT TIME ZONE then expresses that instant as New York
    -- wall-clock time, which is what a clinical date in this cohort means.
    --
    -- Truncating the raw string instead would bake a Kolkata calendar date into a
    -- Massachusetts cohort. 42% of rows land on a different day depending on which
    -- you choose - measured in check Q-01, not asserted.
    p.deceased_datetime                             AS deceased_raw,
    p.deceased_datetime::TIMESTAMPTZ
        AT TIME ZONE 'America/New_York'             AS deceased_datetime,
    (p.deceased_datetime::TIMESTAMPTZ
        AT TIME ZONE 'America/New_York')::DATE      AS deceased_date,

    d.race_code,
    d.race_display,
    d.ethnicity_code,
    d.ethnicity_display

-- LEFT JOIN, not an inner join. A patient missing the race extension entirely must
-- still appear here with NULLs - an inner join would silently delete them, which is
-- exactly the class of loss this project exists to measure.
FROM stg_patient p
LEFT JOIN demographics d ON d.patient_id = p.patient_id;
