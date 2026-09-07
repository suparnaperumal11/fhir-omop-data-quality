-- v_observation - normalised Observation rows, ONE PER FUTURE MEASUREMENT.
--
-- This view is deliberately NOT 1:1 with stg_observation. It is the only place in the
-- pipeline where one source row legitimately becomes more than one output row, and
-- that is tracked explicitly rather than being allowed to look like duplication.
--
-- WHY. 23.7% of Observations have no valueQuantity. 18.3% carry valueCodeableConcept,
-- and 158-per-6-patients (about 5.4%) carry NO value[x] at all - they hold component[]
-- instead. Those are blood pressure panels (2 components: systolic and diastolic) and
-- PRAPARE social-determinant surveys (21 components). A parser reading only scalar
-- values makes blood pressure - one of the most-used variables in clinical research -
-- silently invisible.
--
-- Systolic and diastolic are distinct LOINC concepts and OMOP models them as separate
-- measurement rows, so a BP panel becomes two rows. That expansion is recorded in
-- etl_expansion and reported as Q-05, because 15,632 panels turning into 31,264 rows
-- would otherwise look like a reconciliation failure or a duplicate bug.
--
-- value_kind on each row says which branch produced it, so the loss report can show
-- the composition rather than a single blended number.

CREATE OR REPLACE VIEW v_observation AS

-- Branch 1: observations carrying a scalar value. One row in, one row out.
WITH scalar_obs AS (
    SELECT
        o.observation_id,
        o.full_url,
        o.subject_reference,
        o.encounter_reference,
        json_extract_string(o.category_json, '$[0].coding[0].code')  AS category_code,
        json_extract_string(o.code_json, '$.coding[0].code')         AS code,
        json_extract_string(o.code_json, '$.coding[0].display')      AS code_display,
        json_array_length(json_extract(o.code_json, '$.coding'))     AS coding_count,
        o.effective_datetime                                          AS effective_raw,
        CASE
            WHEN o.value_quantity_json        IS NOT NULL THEN 'valueQuantity'
            WHEN o.value_codeable_concept_json IS NOT NULL THEN 'valueCodeableConcept'
            WHEN o.value_string               IS NOT NULL THEN 'valueString'
        END                                                           AS value_kind,
        TRY_CAST(json_extract_string(o.value_quantity_json, '$.value') AS DOUBLE) AS value_as_number,
        json_extract_string(o.value_quantity_json, '$.unit')          AS unit_source_value,
        COALESCE(
            json_extract_string(o.value_codeable_concept_json, '$.coding[0].code'),
            o.value_string,
            json_extract_string(o.value_quantity_json, '$.value')
        )                                                             AS value_source_value,
        0                                                             AS component_seq,
        o.resource_json
    FROM stg_observation o
    WHERE o.value_quantity_json IS NOT NULL
       OR o.value_codeable_concept_json IS NOT NULL
       OR o.value_string IS NOT NULL
),

-- Branch 2: observations with no scalar value, expanded one row per component.
-- The component carries its OWN LOINC code (8480-6 systolic, 8462-4 diastolic), which
-- is why these are separate measurements and not attributes of the panel.
component_obs AS (
    SELECT
        o.observation_id,
        o.full_url,
        o.subject_reference,
        o.encounter_reference,
        json_extract_string(o.category_json, '$[0].coding[0].code')      AS category_code,
        json_extract_string(c.value, '$.code.coding[0].code')            AS code,
        json_extract_string(c.value, '$.code.coding[0].display')         AS code_display,
        json_array_length(json_extract(c.value, '$.code.coding'))        AS coding_count,
        o.effective_datetime                                              AS effective_raw,
        'component'                                                       AS value_kind,
        TRY_CAST(json_extract_string(c.value, '$.valueQuantity.value') AS DOUBLE) AS value_as_number,
        json_extract_string(c.value, '$.valueQuantity.unit')             AS unit_source_value,
        COALESCE(
            json_extract_string(c.value, '$.valueCodeableConcept.coding[0].code'),
            json_extract_string(c.value, '$.valueQuantity.value')
        )                                                                 AS value_source_value,
        row_number() OVER (PARTITION BY o.observation_id ORDER BY c.value::VARCHAR) AS component_seq,
        o.resource_json
    FROM stg_observation o,
         unnest(json_extract(o.component_json, '$[*]')) AS c(value)
    WHERE o.value_quantity_json IS NULL
      AND o.value_codeable_concept_json IS NULL
      AND o.value_string IS NULL
      AND o.component_json IS NOT NULL
)

SELECT
    *,
    effective_raw::TIMESTAMPTZ AT TIME ZONE 'America/New_York'          AS measurement_datetime,
    (effective_raw::TIMESTAMPTZ AT TIME ZONE 'America/New_York')::DATE  AS measurement_date
FROM (
    SELECT * FROM scalar_obs
    UNION ALL
    SELECT * FROM component_obs
);
