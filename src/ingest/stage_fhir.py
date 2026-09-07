"""Stage Synthea FHIR bundles into DuckDB. Flatten only - no transformation.

Scalars are copied verbatim (datetime strings keep their original offset).
Every array or nested object is kept as a JSON column so that extraction
decisions - "take coding[0] of N" - happen in SQL where they can be counted.
Each row also carries resource_json, the complete original resource.

Usage:  python src/ingest/stage_fhir.py [fhir_dir] [duckdb_path]
"""

import glob
import json
import os
import sys
from collections import Counter

import duckdb
import pandas as pd

FHIR_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join("output", "fhir")
DB_PATH = sys.argv[2] if len(sys.argv) > 2 else os.path.join("data", "fhir_omop.duckdb")

NON_PATIENT_PREFIXES = ("hospitalInformation", "practitionerInformation")
FLUSH_EVERY = 40  # bundles


def j(v):
    """JSON-encode a nested value; None stays None so SQL sees a real NULL."""
    return None if v is None else json.dumps(v, separators=(",", ":"))


def ref(node):
    """Pull the raw reference string, verbatim. Format is decided in SQL."""
    if isinstance(node, dict):
        r = node.get("reference")
        return r if isinstance(r, str) else None
    return None


# ---------------------------------------------------------------- extractors
# Each returns a dict whose keys match the DDL column order exactly.

def x_patient(r, full_url, src):
    return dict(
        patient_id=r.get("id"), full_url=full_url,
        gender=r.get("gender"), birth_date=r.get("birthDate"),
        deceased_datetime=r.get("deceasedDateTime"),
        multiple_birth_boolean=r.get("multipleBirthBoolean"),
        marital_status_json=j(r.get("maritalStatus")),
        extension_json=j(r.get("extension")),
        identifier_json=j(r.get("identifier")),
        address_json=j(r.get("address")),
        name_json=j(r.get("name")),
        telecom_json=j(r.get("telecom")),
        communication_json=j(r.get("communication")),
        resource_json=j(r), source_file=src,
    )


def x_encounter(r, full_url, src):
    period = r.get("period") or {}
    return dict(
        encounter_id=r.get("id"), full_url=full_url,
        subject_reference=ref(r.get("subject")),
        status=r.get("status"),
        class_json=j(r.get("class")),
        type_json=j(r.get("type")),
        period_start=period.get("start"), period_end=period.get("end"),
        reason_code_json=j(r.get("reasonCode")),
        participant_json=j(r.get("participant")),
        location_json=j(r.get("location")),
        service_provider_reference=ref(r.get("serviceProvider")),
        identifier_json=j(r.get("identifier")),
        resource_json=j(r), source_file=src,
    )


def x_condition(r, full_url, src):
    return dict(
        condition_id=r.get("id"), full_url=full_url,
        subject_reference=ref(r.get("subject")),
        encounter_reference=ref(r.get("encounter")),
        clinical_status_json=j(r.get("clinicalStatus")),
        verification_status_json=j(r.get("verificationStatus")),
        category_json=j(r.get("category")),
        code_json=j(r.get("code")),
        onset_datetime=r.get("onsetDateTime"),
        abatement_datetime=r.get("abatementDateTime"),
        recorded_date=r.get("recordedDate"),
        resource_json=j(r), source_file=src,
    )


def x_medicationrequest(r, full_url, src):
    return dict(
        medicationrequest_id=r.get("id"), full_url=full_url,
        subject_reference=ref(r.get("subject")),
        encounter_reference=ref(r.get("encounter")),
        status=r.get("status"), intent=r.get("intent"),
        authored_on=r.get("authoredOn"),
        medication_codeable_concept_json=j(r.get("medicationCodeableConcept")),
        medication_reference=ref(r.get("medicationReference")),
        requester_reference=ref(r.get("requester")),
        category_json=j(r.get("category")),
        dosage_instruction_json=j(r.get("dosageInstruction")),
        reason_code_json=j(r.get("reasonCode")),
        reason_reference_json=j(r.get("reasonReference")),
        resource_json=j(r), source_file=src,
    )


def x_observation(r, full_url, src):
    return dict(
        observation_id=r.get("id"), full_url=full_url,
        subject_reference=ref(r.get("subject")),
        encounter_reference=ref(r.get("encounter")),
        status=r.get("status"),
        category_json=j(r.get("category")),
        code_json=j(r.get("code")),
        effective_datetime=r.get("effectiveDateTime"),
        issued=r.get("issued"),
        value_quantity_json=j(r.get("valueQuantity")),
        value_codeable_concept_json=j(r.get("valueCodeableConcept")),
        value_string=r.get("valueString"),
        component_json=j(r.get("component")),
        resource_json=j(r), source_file=src,
    )


def x_medication(r, full_url, src):
    return dict(
        medication_id=r.get("id"), full_url=full_url,
        status=r.get("status"), code_json=j(r.get("code")),
        resource_json=j(r), source_file=src,
    )


def _named(r, full_url, src, id_key):
    return {
        id_key: r.get("id"), "full_url": full_url,
        "name": r.get("name") if isinstance(r.get("name"), str) else j(r.get("name")),
        "identifier_json": j(r.get("identifier")),
        "address_json": j(r.get("address")),
        "telecom_json": j(r.get("telecom")),
        "resource_json": j(r), "source_file": src,
    }


EXTRACTORS = {
    "Patient": ("stg_patient", x_patient),
    "Encounter": ("stg_encounter", x_encounter),
    "Condition": ("stg_condition", x_condition),
    "MedicationRequest": ("stg_medicationrequest", x_medicationrequest),
    "Observation": ("stg_observation", x_observation),
    "Medication": ("stg_medication", x_medication),
    "Organization": ("stg_organization", lambda r, f, s: _named(r, f, s, "organization_id")),
    "Practitioner": ("stg_practitioner", lambda r, f, s: _named(r, f, s, "practitioner_id")),
    "Location": ("stg_location", lambda r, f, s: _named(r, f, s, "location_id")),
}

DDL = {
    "stg_patient": """
        patient_id VARCHAR, full_url VARCHAR, gender VARCHAR, birth_date VARCHAR,
        deceased_datetime VARCHAR, multiple_birth_boolean BOOLEAN,
        marital_status_json JSON, extension_json JSON, identifier_json JSON,
        address_json JSON, name_json JSON, telecom_json JSON, communication_json JSON,
        resource_json JSON, source_file VARCHAR""",
    "stg_encounter": """
        encounter_id VARCHAR, full_url VARCHAR, subject_reference VARCHAR, status VARCHAR,
        class_json JSON, type_json JSON, period_start VARCHAR, period_end VARCHAR,
        reason_code_json JSON, participant_json JSON, location_json JSON,
        service_provider_reference VARCHAR, identifier_json JSON,
        resource_json JSON, source_file VARCHAR""",
    "stg_condition": """
        condition_id VARCHAR, full_url VARCHAR, subject_reference VARCHAR,
        encounter_reference VARCHAR, clinical_status_json JSON, verification_status_json JSON,
        category_json JSON, code_json JSON, onset_datetime VARCHAR,
        abatement_datetime VARCHAR, recorded_date VARCHAR,
        resource_json JSON, source_file VARCHAR""",
    "stg_medicationrequest": """
        medicationrequest_id VARCHAR, full_url VARCHAR, subject_reference VARCHAR,
        encounter_reference VARCHAR, status VARCHAR, intent VARCHAR, authored_on VARCHAR,
        medication_codeable_concept_json JSON, medication_reference VARCHAR,
        requester_reference VARCHAR, category_json JSON, dosage_instruction_json JSON,
        reason_code_json JSON, reason_reference_json JSON,
        resource_json JSON, source_file VARCHAR""",
    "stg_observation": """
        observation_id VARCHAR, full_url VARCHAR, subject_reference VARCHAR,
        encounter_reference VARCHAR, status VARCHAR, category_json JSON, code_json JSON,
        effective_datetime VARCHAR, issued VARCHAR, value_quantity_json JSON,
        value_codeable_concept_json JSON, value_string VARCHAR, component_json JSON,
        resource_json JSON, source_file VARCHAR""",
    "stg_medication": """
        medication_id VARCHAR, full_url VARCHAR, status VARCHAR, code_json JSON,
        resource_json JSON, source_file VARCHAR""",
    "stg_organization": """
        organization_id VARCHAR, full_url VARCHAR, name VARCHAR, identifier_json JSON,
        address_json JSON, telecom_json JSON, resource_json JSON, source_file VARCHAR""",
    "stg_practitioner": """
        practitioner_id VARCHAR, full_url VARCHAR, name VARCHAR, identifier_json JSON,
        address_json JSON, telecom_json JSON, resource_json JSON, source_file VARCHAR""",
    "stg_location": """
        location_id VARCHAR, full_url VARCHAR, name VARCHAR, identifier_json JSON,
        address_json JSON, telecom_json JSON, resource_json JSON, source_file VARCHAR""",
    "stg_resource_census": """
        source_file VARCHAR, bundle_kind VARCHAR, resource_type VARCHAR,
        n_resources BIGINT, staged BOOLEAN""",
}


def main():
    files = sorted(glob.glob(os.path.join(FHIR_DIR, "*.json")))
    if not files:
        sys.exit(f"No JSON found in {FHIR_DIR}")

    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    con = duckdb.connect(DB_PATH)

    cols = {}
    for tbl, body in DDL.items():
        con.execute(f"CREATE TABLE {tbl} ({body})")
        cols[tbl] = [c[0] for c in con.execute(f"DESCRIBE {tbl}").fetchall()]

    buf = {t: [] for t in DDL if t != "stg_resource_census"}
    census_rows = []
    seen_total = Counter()
    staged_total = Counter()

    def flush():
        for tbl, rows in buf.items():
            if not rows:
                continue
            df = pd.DataFrame(rows, columns=cols[tbl])
            con.register("_df", df)
            con.execute(f"INSERT INTO {tbl} SELECT * FROM _df")
            con.unregister("_df")
            rows.clear()

    for i, path in enumerate(files, 1):
        base = os.path.basename(path)
        kind = "reference" if base.startswith(NON_PATIENT_PREFIXES) else "patient"
        with open(path, encoding="utf-8") as fh:
            bundle = json.load(fh)

        per_file = Counter()
        for entry in bundle.get("entry", []):
            res = entry.get("resource") or {}
            rtype = res.get("resourceType")
            if not rtype:
                continue
            per_file[rtype] += 1
            seen_total[rtype] += 1
            target = EXTRACTORS.get(rtype)
            if target:
                tbl, fn = target
                buf[tbl].append(fn(res, entry.get("fullUrl"), base))
                staged_total[rtype] += 1

        for rtype, n in per_file.items():
            census_rows.append(dict(source_file=base, bundle_kind=kind,
                                    resource_type=rtype, n_resources=n,
                                    staged=rtype in EXTRACTORS))

        if i % FLUSH_EVERY == 0:
            flush()
            print(f"  ...{i}/{len(files)} bundles", flush=True)

    flush()
    df = pd.DataFrame(census_rows, columns=cols["stg_resource_census"])
    con.register("_df", df)
    con.execute("INSERT INTO stg_resource_census SELECT * FROM _df")
    con.unregister("_df")

    # ---- reconciliation: staged row counts must equal what the census saw
    print(f"\nBundles read: {len(files)}")
    print(f"{'resourceType':<26}{'seen':>10}{'staged':>10}{'in table':>10}  status")
    ok = True
    for rtype, n in sorted(seen_total.items(), key=lambda x: -x[1]):
        tbl = EXTRACTORS.get(rtype, (None,))[0]
        in_tbl = con.execute(f"SELECT count(*) FROM {tbl}").fetchone()[0] if tbl else 0
        if tbl:
            good = in_tbl == n
            ok &= good
            status = "OK" if good else "*** MISMATCH ***"
        else:
            status = "not staged (out of scope, counted)"
        print(f"{rtype:<26}{n:>10}{staged_total.get(rtype, 0):>10}{in_tbl:>10}  {status}")

    total_seen = sum(seen_total.values())
    total_staged = sum(staged_total.values())
    print(f"\n{'TOTAL':<26}{total_seen:>10}{total_staged:>10}")
    print(f"Staged {total_staged}/{total_seen} resources "
          f"({100*total_staged/total_seen:.1f}%); the remainder are out-of-scope "
          f"resource types, named and counted in stg_resource_census.")
    con.close()  # checkpoint before measuring, or the file reads as empty
    print(f"\nDatabase: {DB_PATH} ({os.path.getsize(DB_PATH)/1e6:.0f} MB)")
    if not ok:
        sys.exit("RECONCILIATION FAILED - staged rows do not match census")


if __name__ == "__main__":
    main()
