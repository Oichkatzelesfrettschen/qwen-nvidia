#!/usr/bin/env python3
"""
Check consistency between mutable current-state documentation and the
machine-readable authority surfaces. The registry, the tuple ledger, the
quarantine ledger, the closure ledger, and the validation-class ledger are
the authorities; README.md and TASK_TRACKER.md are the prose surfaces this
gate holds to them, so an expectation here is derived from a ledger rather
than snapshotted into this script.

The authorities carry distinctions this gate preserves rather than
flattens. A quarantine row names a scope and a runtime mode, so a profile
quarantine is not a model quarantine and a router-child exclusion is not a
standalone one. A switch policy is a registry field on every row rather
than one checkpoint's property. A validated tuple qualifies an extension
arm only at the depth and cache triple the row's primary tuple already
holds, so a shallow second geometry does not satisfy a deep row's coverage.
A closure identity carries a role, so a digest mentioned under the wrong
role fails rather than passing on presence.
"""

import sys
import os
import pathlib
import subprocess
import re

# The serving backend this repository is authoritative for. The nested
# validator reads QWEN_SERVING_BACKEND, so the value is set here rather than
# inherited: an ambient override would otherwise decide what the gate admits.
AUTHORITATIVE_BACKEND = "cuda"

# The promotion summary's own schema. A summary that parses is not a summary
# that states an outcome, so the header and the terminal checks are required
# rather than assumed.
SERVING_SUMMARY_HEADER = ["check", "result", "detail"]
SERVING_SUMMARY_REQUIRED_CHECKS = {
    "launch", "health", "roster", "teardown", "serving_device",
}
SERVING_SUMMARY_RESULTS = {"accepted", "observed", "skipped"}


def parse_tsv(file_path):
    rows = []
    header = None
    if not os.path.exists(file_path):
        return None, None
    with open(file_path, "r", encoding="utf-8") as f:
        for line_num, line in enumerate(f, start=1):
            line_str = line.strip()
            if not line_str or line_str.startswith("#"):
                # The column header is the final comment line shaped
                # '# name\tname\t...'; later header comments replace earlier
                # ones so prose comments containing a tab do not win.
                candidate = line.lstrip("#").strip()
                if "\t" in candidate and re.match(r"^[a-z_]+\t", candidate):
                    header = [col.strip() for col in candidate.split("\t")]
                continue
            parts = [col.strip() for col in line.split("\t")]
            rows.append((line_num, parts))
    return header, rows


def rows_as_dicts(header, rows, report_error, label):
    result = []
    for lnum, parts in rows:
        if header and len(parts) == len(header):
            result.append((lnum, dict(zip(header, parts))))
        else:
            report_error(
                f"{label} row at line {lnum} has {len(parts)} fields, "
                f"expected {len(header) if header else 'a parsed header'}")
    return result


def load_ledger(repo_root, name, report_error, required_columns):
    """Return the rows of one authority ledger, or an empty list."""
    path = repo_root / "scripts" / name
    header, rows = parse_tsv(path)
    if rows is None or not header:
        report_error(f"scripts/{name} missing, empty, or missing column "
                     "header")
        return []
    missing = [c for c in required_columns if c not in header]
    if missing:
        report_error(f"scripts/{name} header does not name "
                     f"{', '.join(missing)}")
        return []
    return [row for _, row in rows_as_dicts(header, rows, report_error,
                                            f"scripts/{name}")]


def normalize_ws(text):
    return " ".join(text.split())


def threshold_values(text, quant):
    """Every numeric value a threshold clause binds to the named quant type.

    A clause is the run of one sentence fragment that names the quant and the
    word 'threshold' or the 'at <word-number>' spelling, so a digit sitting in
    an unrelated token such as an evidence path stays out of the match.
    """
    words = {"four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
             "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
             "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16}
    values = []
    for match in re.finditer(
            rf"{quant}(?:\s+MMVQ)?\s+threshold(?:\s+(?:of|at))?\s+(\d+)\b",
            text, re.IGNORECASE):
        values.append(int(match.group(1)))
    for match in re.finditer(
            rf"{quant}\s+at\s+({'|'.join(words)})\b", text, re.IGNORECASE):
        values.append(words[match.group(1).lower()])
    return values


# Each closure role carries one canonical README statement binding a digest to
# that role. A presence check accepts a document that swaps two digests under
# each other's role labels, because both identities remain somewhere on the
# page; matching the digest inside the role clause is what makes the swap fail.
ROLE_STATEMENTS = {
    "promoted": r"served closure is configuration `?([0-9a-f]{12})`?",
    "rollback": (r"configuration `?([0-9a-f]{12})`? is retained as the "
                 r"rollback target"),
    "diagnostic": (r"configuration `?([0-9a-f]{12})`? is retained as the "
                   r"[^.`]*diagnostic closure"),
}


def check_role_statement(role, expected_digest, readme_norm, report_error):
    """Require README to name this digest inside its own role clause."""
    pattern = ROLE_STATEMENTS.get(role)
    if pattern is None:
        report_error(f"scripts/serving-closures.tsv names role '{role}', for "
                     "which this gate carries no README role statement")
        return
    match = re.search(pattern, readme_norm, re.IGNORECASE)
    if not match:
        report_error(f"README.md carries no {role}-closure statement naming a "
                     "configuration digest")
    elif match.group(1) != expected_digest:
        report_error(f"README.md {role}-closure statement names "
                     f"{match.group(1)}, but the closure ledger records "
                     f"{expected_digest} as {role}")


def documented_quarantine_set(readme_norm):
    """The model-scope quarantine subjects README states, or None.

    The statement is a complete set claim rather than a membership one, so the
    gate reads every identifier it names and compares the whole set: a second
    model-scope row added to the ledger has to appear here or the prose is
    stale.
    """
    match = re.search(
        r"active model quarantine set in `?scripts/quarantine\.tsv`? "
        r"consists of ([^.]+)\.", readme_norm)
    if not match:
        return None
    return set(re.findall(r"`([^`]+)`", match.group(1)))


def check_serving_summary(path, report_error):
    """Require the promotion summary to state an outcome, not merely exist."""
    header, rows = parse_tsv(path)
    if rows is None:
        report_error(f"{path.name} missing or unreadable under "
                     f"{path.parent}")
        return
    # The summary's header is its first data-shaped line rather than a
    # comment, so parse_tsv returns it as a row.
    if not rows:
        report_error(f"{path} carries no rows")
        return
    first = rows[0][1]
    if first != SERVING_SUMMARY_HEADER:
        report_error(f"{path} header reads {first}, expected "
                     f"{SERVING_SUMMARY_HEADER}")
        return
    seen = {}
    for lnum, parts in rows[1:]:
        if len(parts) < 2:
            report_error(f"{path} row at line {lnum} has {len(parts)} "
                         "fields, expected at least 2")
            continue
        name, result = parts[0], parts[1]
        if name in seen:
            report_error(f"{path} repeats check '{name}' at lines "
                         f"{seen[name]} and {lnum}")
        seen[name] = lnum
        if result not in SERVING_SUMMARY_RESULTS:
            report_error(f"{path} check '{name}' carries result "
                         f"'{result}', outside "
                         f"{sorted(SERVING_SUMMARY_RESULTS)}")
    missing = sorted(SERVING_SUMMARY_REQUIRED_CHECKS - set(seen))
    if missing:
        report_error(f"{path} omits required checks: {', '.join(missing)}")
    for name in ("launch", "health", "roster", "teardown", "serving_device"):
        lnum = seen.get(name)
        if lnum is None:
            continue
        result = dict((p[0], p[1]) for _, p in rows[1:] if len(p) >= 2)[name]
        if result != "accepted":
            report_error(f"{path} check '{name}' reads '{result}', "
                         "expected 'accepted'")
    # The serving device is the repository's own authority claim, so the
    # detail is read rather than the result alone.
    for _, parts in rows[1:]:
        if parts and parts[0] == "serving_device" and len(parts) >= 3:
            if "CUDA0" not in parts[2]:
                report_error(f"{path} serving_device detail does not name "
                             f"CUDA0: {parts[2]}")


def main():
    repo_root = (pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1
                 else pathlib.Path(__file__).parent.parent.resolve())

    failures = []

    def report_error(msg):
        failures.append(msg)
        print(f"authority_consistency: ERROR: {msg}", file=sys.stderr)

    # 1. The underlying validators run first: the tuple ledger against the
    # registry, and the sanitization rules over the evidence tree. The child
    # environment names the backend rather than inheriting one, so an
    # ambient QWEN_SERVING_BACKEND cannot decide what the nested validator
    # admits.
    # One scrubbed environment serves both children: each reads
    # QWEN_SERVING_BACKEND, so an ambient override would otherwise decide
    # what either validator admits.
    env = os.environ.copy()
    for name in ("QWEN_MODEL_REGISTRY", "QWEN_VALIDATED_TUPLES",
                 "QWEN_SERVING_BACKEND"):
        env.pop(name, None)
    env["QWEN_MODEL_REGISTRY"] = str(repo_root / "scripts" / "models.tsv")
    env["QWEN_VALIDATED_TUPLES"] = str(
        repo_root / "scripts" / "validated-tuples.tsv")
    env["QWEN_SERVING_BACKEND"] = AUTHORITATIVE_BACKEND

    check_tuples_script = repo_root / "scripts" / "check-validated-tuples.sh"
    if check_tuples_script.exists():
        res = subprocess.run([str(check_tuples_script)], cwd=str(repo_root),
                             env=env, capture_output=True, text=True)
        if res.returncode != 0:
            report_error("check-validated-tuples.sh failed: "
                         f"{res.stderr.strip() or res.stdout.strip()}")
    else:
        report_error("scripts/check-validated-tuples.sh missing")

    check_nvidia_script = repo_root / "scripts" / "check-nvidia-authority.sh"
    if check_nvidia_script.exists():
        res = subprocess.run([str(check_nvidia_script), str(repo_root)],
                             cwd=str(repo_root), env=env,
                             capture_output=True, text=True)
        if res.returncode != 0:
            report_error("check-nvidia-authority.sh failed: "
                         f"{res.stderr.strip() or res.stdout.strip()}")
    else:
        report_error("scripts/check-nvidia-authority.sh missing")

    readme_path = repo_root / "README.md"
    if not readme_path.exists():
        report_error("README.md missing")
        readme_text = ""
    else:
        readme_text = readme_path.read_text(encoding="utf-8")
    readme_norm = normalize_ws(readme_text)

    # 2. Build closures, by role, from the closure ledger. The evidence path,
    # the digest, and the role all come from the ledger, so a new rollback
    # target or a second diagnostic closure enters this gate by gaining a row.
    closures = load_ledger(
        repo_root, "serving-closures.tsv", report_error,
        ["role", "configuration_id", "evidence_path", "backend_set",
         "architecture", "ptx_images", "status"])
    closures_by_role = {}
    for row in closures:
        closures_by_role.setdefault(row["role"], []).append(row)

    for role in ("promoted", "rollback", "diagnostic"):
        if role not in closures_by_role:
            report_error(f"scripts/serving-closures.tsv names no {role} "
                         "closure")
    if len(closures_by_role.get("promoted", [])) > 1:
        report_error("scripts/serving-closures.tsv names more than one "
                     "promoted closure; exactly one closure serves")

    for role, rows in closures_by_role.items():
        for row in rows:
            digest = row["configuration_id"]
            if not re.fullmatch(r"[0-9a-f]{12}", digest):
                report_error(f"scripts/serving-closures.tsv {role} "
                             f"configuration_id '{digest}' is not twelve "
                             "hex characters")
                continue
            evidence = repo_root / row["evidence_path"]
            if not (evidence / "README.md").exists():
                report_error(f"Missing {role} configuration evidence under "
                             f"{row['evidence_path']}/")
            if digest not in readme_text:
                report_error(f"README.md does not reference the {role} "
                             f"configuration {digest}")
                continue
            # Presence establishes the identity is on the page; the role
            # statement establishes which role the page gives it.
            check_role_statement(role, digest, readme_norm, report_error)

    # The promoted closure alone carries a serving summary, and the summary
    # states an outcome rather than merely existing.
    for row in closures_by_role.get("promoted", []):
        check_serving_summary(
            repo_root / row["evidence_path"] / "serving-summary.tsv",
            report_error)
        # The served-closure statement names the promoted digest by role, so
        # a README keeping it only as a rollback or historical mention fails.
        served_match = re.search(
            r"served closure is configuration `?([0-9a-f]{12})`?",
            readme_norm)
        if not served_match:
            report_error("README.md carries no served-closure statement "
                         "naming a configuration digest")
        elif served_match.group(1) != row["configuration_id"]:
            report_error("README.md served-closure statement names "
                         f"{served_match.group(1)}, but the closure ledger "
                         f"promotes {row['configuration_id']}")
        # A CUDA-only closure serves no Vulkan device, so the prose must not
        # present the promoted process as reaching one.
        if row["backend_set"] == "cuda":
            for stale in (
                    r"Vulkan\w*\s+is\s+the\s+fallback\s+the\s+same\s+binary",
                    r"Vulkan\s+as\s+the\s+fallback\s+the\s+same\s+binary",
                    r"the\s+same\s+binary\s+carries\s+both\s+backends",
                    r"one\s+binary\s+carrying\s+the\s+CUDA\s+and\s+Vulkan"):
                found = re.search(stale, readme_norm, re.IGNORECASE)
                if found:
                    report_error(
                        "README.md presents the promoted CUDA-only closure "
                        f"as carrying a Vulkan fallback: '{found.group(0)}'")

    # MMVQ threshold claims: every clause binding a value to the quant type
    # must state the promoted value, so one stale clause beside one correct
    # clause still rejects.
    q6k_values = threshold_values(readme_norm, "Q6_K")
    if not q6k_values or any(v != 10 for v in q6k_values):
        report_error("README.md Q6_K MMVQ threshold clauses read "
                     f"{q6k_values or 'absent'}, expected every clause at 10")
    q80_values = threshold_values(readme_norm, "Q8_0")
    if not q80_values or any(v != 16 for v in q80_values):
        report_error("README.md Q8_0 MMVQ threshold clauses read "
                     f"{q80_values or 'absent'}, expected every clause at 16")

    # 3. Quarantine state, keyed by scope, subject, and runtime mode. A row's
    # unique id may differ from the checkpoint it removes, so membership
    # reads `subject`; and a profile-scope or router-child-scope row removes
    # one tuple rather than the checkpoint, so the scope travels with it.
    quarantine_tsv = repo_root / "scripts" / "quarantine.tsv"
    q_header, q_rows = parse_tsv(quarantine_tsv)
    active_quarantines = set()
    if q_rows is None:
        report_error("scripts/quarantine.tsv missing or unreadable")
    elif not q_header or "subject" not in q_header or "scope" not in q_header:
        report_error("scripts/quarantine.tsv header does not name both a "
                     "scope and a subject column")
    else:
        for _, row in rows_as_dicts(q_header, q_rows, report_error,
                                    "scripts/quarantine.tsv"):
            active_quarantines.add((row["scope"], row["subject"],
                                    row.get("runtime_mode", "any")))

    def quarantined_at(scope, subject):
        return any(s == scope and subj == subject
                   for s, subj, _ in active_quarantines)

    # A model-scope row removes the checkpoint entirely; a profile-scope row
    # does not, so the readmission claim is judged against model scope alone.
    if quarantined_at("model", "qwen38-9b-distill"):
        report_error("qwen38-9b-distill carries a model-scope quarantine in "
                     "scripts/quarantine.tsv but README.md documents it as "
                     "readmitted")

    if ("quarantine.tsv excludes the 9B distill" in readme_text
            or "excludes the 9B distill from router service" in readme_text):
        report_error("README.md contains stale text claiming "
                     "qwen38-9b-distill is quarantined")

    # README states the model-scope quarantine set as a complete set, so the
    # comparison runs both ways: a documented subject absent from the ledger is
    # a stale exclusion, and a ledger subject absent from the prose is a
    # quarantine the document does not disclose.
    ledger_model_scope = {subj for scope, subj, _ in active_quarantines
                          if scope == "model"}
    documented = documented_quarantine_set(readme_norm)
    if documented is None:
        report_error("README.md carries no active model quarantine set "
                     "statement naming scripts/quarantine.tsv")
    elif documented != ledger_model_scope:
        report_error(
            "README.md documents the model-scope quarantine set as "
            f"{sorted(documented) or 'empty'}; scripts/quarantine.tsv carries "
            f"{sorted(ledger_model_scope) or 'no model-scope row'}")

    # The registry.
    models_tsv = repo_root / "scripts" / "models.tsv"
    m_header, m_rows = parse_tsv(models_tsv)
    models_dict = {}
    if m_rows is None or not m_header:
        report_error("scripts/models.tsv missing, empty, or missing column "
                     "header")
    else:
        for lnum, row in rows_as_dicts(m_header, m_rows, report_error,
                                       "scripts/models.tsv"):
            models_dict[row["id"]] = (lnum, row)

    # 4. Switch policy, derived: every row departing from the `lru` default
    # is a documented serving constraint, so a new evict-first checkpoint
    # enters this check by its registry field rather than by being named here.
    non_default_switch = {
        model_id: row.get("switch_policy", "-")
        for model_id, (_, row) in models_dict.items()
        if row.get("switch_policy", "lru") != "lru"
    }
    if not non_default_switch:
        report_error("scripts/models.tsv carries no non-default "
                     "switch_policy row; the router transition documentation "
                     "has no registry subject")
    for model_id, policy in sorted(non_default_switch.items()):
        if model_id not in readme_norm:
            report_error(f"README.md does not document {model_id}, which "
                         f"carries switch_policy '{policy}'")
        if policy not in readme_norm:
            report_error(f"README.md does not document the '{policy}' switch "
                         f"policy that {model_id} carries")
    # A roster holding any evict-first row serves one child at a time, so the
    # constraint is documented wherever such a row exists.
    if any(p == "evict-first" for p in non_default_switch.values()):
        if "QWEN_ROUTER_MAX=1" not in readme_text:
            report_error("README.md does not document the QWEN_ROUTER_MAX=1 "
                         "constraint an evict-first roster requires")
        # A generic two-child launch example beside an evict-first roster
        # contradicts the constraint the same document states.
        if re.search(r"QWEN_ROUTER_MAX=2[^\n]*qwen-launch", readme_text):
            if "router-compact-pair" not in readme_text:
                report_error(
                    "README.md shows a QWEN_ROUTER_MAX=2 launch beside an "
                    "evict-first roster without naming the compact-pair "
                    "mode the two-child figure applies to")

    evict_evidence = repo_root / "evidence" / "ada" / "evict-first-9b-readmission"
    if not (evict_evidence / "README.md").exists():
        report_error("Missing readmission evidence under "
                     "evidence/ada/evict-first-9b-readmission/")

    # 5. Validated filled depths, derived from the registry rather than
    # snapshotted here: every row claiming a numeric validated_filled_depth
    # must hold a validated CUDA tuple at that depth and its own submission
    # geometry, so a later measurement that legitimately moves both files
    # passes without editing this gate.
    expected_depths = {}
    for model_id, (lnum, row) in models_dict.items():
        depth = row.get("validated_filled_depth", "-")
        if depth.isdigit():
            expected_depths[model_id] = {
                "depth": depth,
                "batch": row.get("batch", "-"),
                "ubatch": row.get("ubatch", "-"),
                "cache_k": row.get("cache_type_k", "-"),
                "cache_v": row.get("cache_type_v", "-"),
                "flash": row.get("flash_attention", "-"),
            }

    if not expected_depths:
        report_error("scripts/models.tsv claims no numeric "
                     "validated_filled_depth; the depth-validation campaign "
                     "record has no registry subject")

    tuples_tsv = repo_root / "scripts" / "validated-tuples.tsv"
    t_header, t_rows = parse_tsv(tuples_tsv)
    validated_tuples_map = {}
    if t_rows is None or not t_header:
        report_error("scripts/validated-tuples.tsv missing, empty, or "
                     "missing column header")
    else:
        for _, row in rows_as_dicts(t_header, t_rows, report_error,
                                    "scripts/validated-tuples.tsv"):
            if row.get("status") == "validated":
                validated_tuples_map.setdefault(row["model_id"], []).append({
                    "depth": row.get("context", row.get("depth", "-")),
                    "batch": row.get("batch", "-"),
                    "ubatch": row.get("ubatch", "-"),
                    "cache_k": row.get("cache_k", "-"),
                    "cache_v": row.get("cache_v", "-"),
                    "flash": row.get("flash_attention", "-"),
                    "backend": row.get("backend", "-"),
                })

    def matches_primary(tuple_row, expected, *, ignore=()):
        for field in ("depth", "batch", "ubatch", "cache_k", "cache_v",
                      "flash"):
            if field in ignore:
                continue
            if tuple_row[field] != expected[field]:
                return False
        return True

    for model_id, expected in expected_depths.items():
        rows = validated_tuples_map.get(model_id, [])
        if not any(r["backend"] == AUTHORITATIVE_BACKEND
                   and matches_primary(r, expected) for r in rows):
            report_error("scripts/validated-tuples.tsv lacks a validated "
                         f"{AUTHORITATIVE_BACKEND} tuple for {model_id} at "
                         f"depth {expected['depth']}, batch "
                         f"{expected['batch']}, ubatch {expected['ubatch']}, "
                         f"cache {expected['cache_k']}/{expected['cache_v']}, "
                         f"flash attention {expected['flash']}")

    # 6. TASK_TRACKER.md against the ledger-derived open-work state. The
    # document is a required surface, so its absence is a failure rather than
    # a skipped section.
    classes = load_ledger(
        repo_root, "validation-classes.tsv", report_error,
        ["class_id", "representative_model", "second_geometry", "vulkan_arm"])
    for row in classes:
        model_id = row["representative_model"]
        if model_id not in models_dict:
            report_error(f"scripts/validation-classes.tsv names "
                         f"{model_id}, absent from scripts/models.tsv")

    task_tracker_path = repo_root / "TASK_TRACKER.md"
    if not task_tracker_path.exists():
        report_error("TASK_TRACKER.md missing")
    else:
        tt_text = task_tracker_path.read_text(encoding="utf-8")
        tt_norm = normalize_ws(tt_text)

        # Coverage is judged over the declared classes rather than over every
        # row carrying a numeric depth, and an extension arm counts only at
        # the class's own validated depth and cache triple: a shallow second
        # geometry measures a different question than the one the campaign
        # asks.
        second_geometry_open = []
        vulkan_open = []
        for row in classes:
            model_id = row["representative_model"]
            expected = expected_depths.get(model_id)
            if expected is None:
                # A class whose representative holds no numeric depth has its
                # primary arm open, which the depth check above reports.
                continue
            rows = validated_tuples_map.get(model_id, [])
            geometries = {
                (r["batch"], r["ubatch"]) for r in rows
                if r["backend"] == AUTHORITATIVE_BACKEND
                and matches_primary(r, expected, ignore=("batch", "ubatch"))
            }
            vulkan_arms = [
                r for r in rows
                if r["backend"] == "vulkan" and matches_primary(r, expected)
            ]
            if row["second_geometry"] == "required" and len(geometries) < 2:
                second_geometry_open.append(model_id)
            if row["vulkan_arm"] == "required" and not vulkan_arms:
                vulkan_open.append(model_id)

        # Each extension is judged on its own, because the two close at
        # different times: reading them together lets a tracker keep claiming
        # a finished arm is open for as long as the other arm remains open,
        # which is the direction prose drifts in.
        for phrase, still_open, label in (
                ("second submission geometry per class", second_geometry_open,
                 "second geometry"),
                ("Vulkan-backend arms", vulkan_open, "Vulkan arm")):
            present = phrase in tt_norm
            if still_open and not present:
                report_error(
                    f"TASK_TRACKER.md omits the open {label} statement; "
                    f"open for {still_open}")
            elif not still_open and present:
                report_error(
                    f"TASK_TRACKER.md still states the {label} as open work; "
                    "every required class in "
                    "scripts/validation-classes.tsv holds it")

        # Per-model depth statements are reconciled rather than left to drift:
        # a tracker naming a depth for a registry row must name the depth the
        # registry claims.
        for model_id, expected in expected_depths.items():
            for match in re.finditer(
                    rf"{re.escape(model_id)} at (\d+)", tt_norm):
                if match.group(1) != expected["depth"]:
                    report_error(
                        f"TASK_TRACKER.md states {model_id} at "
                        f"{match.group(1)}; scripts/models.tsv claims "
                        f"validated_filled_depth {expected['depth']}")

    # 7. The coding lane's three-way execution consistency: a profile that may
    # execute requires the runtime it names to be admitted, the model's own
    # execution grant, and readable full-chain evidence. The rule holds for
    # every validator-gated profile rather than for one named row.
    coding_profiles = load_ledger(
        repo_root, "coding-profiles.tsv", report_error,
        ["profile_id", "model_id", "runtime_id", "execution_policy"])
    coding_runtimes = {
        row["id"]: row for row in load_ledger(
            repo_root, "coding-runtimes.tsv", report_error,
            ["id", "execution_policy", "validation_evidence"])
    }
    for profile in coding_profiles:
        if profile["execution_policy"] != "validator-gated":
            continue
        runtime = coding_runtimes.get(profile["runtime_id"])
        if runtime is None:
            report_error(f"coding profile {profile['profile_id']} names "
                         f"runtime {profile['runtime_id']}, absent from "
                         "scripts/coding-runtimes.tsv")
            continue
        if runtime["execution_policy"] != "validator-gated":
            report_error(
                f"coding profile {profile['profile_id']} is validator-gated "
                f"while its runtime {profile['runtime_id']} reads "
                f"'{runtime['execution_policy']}'")
        model_id = profile["model_id"]
        registry_row = models_dict.get(model_id, (0, {}))[1]
        grant = registry_row.get("guarded_tool_execution", "-")
        if grant != "validator-gated":
            report_error(
                f"coding profile {profile['profile_id']} is validator-gated "
                f"while {model_id} carries guarded_tool_execution "
                f"'{grant}' in scripts/models.tsv")
        evidence = runtime.get("validation_evidence", "-")
        if evidence == "-" or not (repo_root / evidence).exists():
            report_error(
                f"runtime {profile['runtime_id']} is validator-gated with "
                f"unreadable validation evidence '{evidence}'")

    # 8. Serving backend.
    if "CUDA0" not in readme_text:
        report_error("README.md does not assert CUDA0 serving authority")

    if failures:
        print(f"check_authority_consistency=rejected failures={len(failures)}",
              file=sys.stderr)
        sys.exit(1)

    print("check_authority_consistency=accepted")
    sys.exit(0)


if __name__ == "__main__":
    main()
