#!/bin/sh
# Hold reconstruct-closure-source.sh to what it claims: a matching digest reads
# match=yes, a mismatching one reads match=no without ending the run, a patch
# that fails to apply is named rather than silently producing a partial tree,
# and a control that misses refuses the whole run so an environment change
# cannot be reported as a subject's provenance verdict.
#
# The fixture is a git repository of two files, so every reading is exact and
# the test needs neither the pinned llama.cpp tree nor a device.
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
reconstructor="$script_directory/reconstruct-closure-source.sh"
[ -x "$reconstructor" ] || { printf 'reconstructor is absent: %s\n' "$reconstructor" >&2; exit 1; }

temporary_directory=$(mktemp -d)
cleanup() { chmod -R u+w "$temporary_directory" 2>/dev/null || true
            rm -rf "$temporary_directory"; }
trap cleanup EXIT INT TERM

failures=0
check() {
    check_label=$1
    check_expected=$2
    check_actual=$3
    if [ "$check_expected" = "$check_actual" ]; then
        printf 'ok %s %s\n' "$check_label" "$check_actual"
    else
        printf 'FAIL %s expected=%s actual=%s\n' "$check_label" "$check_expected" "$check_actual"
        failures=$((failures + 1))
    fi
}

fixture_repository="$temporary_directory/source"
mkdir -p "$fixture_repository"
git -C "$fixture_repository" init --quiet
git -C "$fixture_repository" config user.email fixture@example.invalid
git -C "$fixture_repository" config user.name fixture
printf 'alpha\n' > "$fixture_repository/alpha.txt"
printf 'beta\n' > "$fixture_repository/beta.txt"
git -C "$fixture_repository" add alpha.txt beta.txt
git -C "$fixture_repository" commit --quiet -m 'fixture base'
fixture_pin=$(git -C "$fixture_repository" rev-parse HEAD)

# Two patches, one touching each file, so an apply order is observable and a
# subset is a distinct tree rather than a relabeling of the same one.
patch_directory="$temporary_directory/patches"
mkdir -p "$patch_directory"
cat > "$patch_directory/touch-alpha.patch" <<'PATCH'
--- a/alpha.txt
+++ b/alpha.txt
@@ -1 +1 @@
-alpha
+alpha changed
PATCH
cat > "$patch_directory/touch-beta.patch" <<'PATCH'
--- a/beta.txt
+++ b/beta.txt
@@ -1 +1 @@
-beta
+beta changed
PATCH
# A patch whose context cannot be found, so the refusal path is exercised.
cat > "$patch_directory/unappliable.patch" <<'PATCH'
--- a/alpha.txt
+++ b/alpha.txt
@@ -1 +1 @@
-content that is absent from the fixture
+replacement
PATCH

digest_of() {
    digest_work=$(mktemp -d "$temporary_directory/probe.XXXXXX")
    rmdir "$digest_work"
    printf 'subject\tprobe\t%s\t-\t%s\n' "$patch_directory" "$1" > "$temporary_directory/probe.tsv"
    printf 'control\tprobe-control\t%s\t-\t%s\n' "$patch_directory" "$1" >> "$temporary_directory/probe.tsv"
    "$reconstructor" "$fixture_repository" "$fixture_pin" "$digest_work" \
        "$temporary_directory/probe.tsv" 2>/dev/null |
        awk -F'\t' '/^reconstruction\trole=subject/ { sub(/^digest=/, "", $4); print $4 }'
}

alpha_digest=$(digest_of 'touch-alpha')
both_digest=$(digest_of 'touch-alpha touch-beta')

# A one-patch tree and a two-patch tree are distinct, which is what makes a
# match a statement about content rather than about the procedure running.
if [ "$alpha_digest" = "$both_digest" ]; then
    printf 'FAIL fixture_discriminates two subsets produced one digest\n'
    failures=$((failures + 1))
else
    printf 'ok fixture_discriminates alpha=%s both=%s\n' \
        "$(printf '%s' "$alpha_digest" | cut -c1-12)" \
        "$(printf '%s' "$both_digest" | cut -c1-12)"
fi

run_manifest() {
    run_work=$(mktemp -d "$temporary_directory/run.XXXXXX")
    rmdir "$run_work"
    run_status=0
    "$reconstructor" "$fixture_repository" "$fixture_pin" "$run_work" "$1" \
        > "$temporary_directory/run.out" 2>"$temporary_directory/run.err" || run_status=$?
    printf '%s' "$run_status"
}

# A control that reproduces, one subject that matches and one that does not.
cat > "$temporary_directory/mixed.tsv" <<MANIFEST
control	known-good	$patch_directory	$alpha_digest	touch-alpha
subject	matching	$patch_directory	$both_digest	touch-alpha touch-beta
subject	missing	$patch_directory	$alpha_digest	touch-alpha touch-beta
MANIFEST
check mixed_run_status 0 "$(run_manifest "$temporary_directory/mixed.tsv")"
check mixed_subject_matches 1 \
    "$(grep -c 'role=subject.*match=yes' "$temporary_directory/run.out")"
check mixed_subject_misses 1 \
    "$(grep -c 'role=subject.*match=no' "$temporary_directory/run.out")"
check mixed_terminal accepted \
    "$(awk '/^reconstruction=/ { sub(/^reconstruction=/, ""); print $1 }' "$temporary_directory/run.out")"

# A control that fails to reproduce refuses the run whatever the subjects read.
cat > "$temporary_directory/broken.tsv" <<MANIFEST
control	broken-control	$patch_directory	$both_digest	touch-alpha
subject	matching	$patch_directory	$both_digest	touch-alpha touch-beta
MANIFEST
check broken_control_status 1 "$(run_manifest "$temporary_directory/broken.tsv")"
check broken_control_reason 'reconstruction=refused reason=control_did_not_reproduce' \
    "$(cat "$temporary_directory/run.err")"

# A manifest carrying no control refuses rather than reporting subjects alone.
cat > "$temporary_directory/nocontrol.tsv" <<MANIFEST
subject	matching	$patch_directory	$both_digest	touch-alpha touch-beta
MANIFEST
check no_control_status 1 "$(run_manifest "$temporary_directory/nocontrol.tsv")"
check no_control_reason 'reconstruction=refused reason=no_control_row' \
    "$(cat "$temporary_directory/run.err")"

# A patch that cannot apply is named on its row rather than producing a digest
# over a partially patched tree.
cat > "$temporary_directory/refused.tsv" <<MANIFEST
control	known-good	$patch_directory	$alpha_digest	touch-alpha
subject	unappliable	$patch_directory	-	touch-alpha unappliable
subject	absent	$patch_directory	-	touch-alpha not-a-patch
MANIFEST
check refused_run_status 0 "$(run_manifest "$temporary_directory/refused.tsv")"
check refused_names_patch 1 \
    "$(grep -c 'label=unappliable.*digest=refused:unappliable' "$temporary_directory/run.out")"
check absent_names_patch 1 \
    "$(grep -c 'label=absent.*digest=absent:not-a-patch' "$temporary_directory/run.out")"

# A populated work directory is refused, so a run never reads a tree an earlier
# run left behind.
populated_work="$temporary_directory/populated"
mkdir -p "$populated_work/reconstruction-clone"
populated_status=0
"$reconstructor" "$fixture_repository" "$fixture_pin" "$populated_work" \
    "$temporary_directory/mixed.tsv" >/dev/null 2>&1 || populated_status=$?
check populated_work_refused 2 "$populated_status"

# The source repository is never written to: reconstruction happens in a clone.
check source_repository_clean '' "$(git -C "$fixture_repository" status --porcelain)"
check source_repository_head "$fixture_pin" "$(git -C "$fixture_repository" rev-parse HEAD)"

if [ "$failures" -eq 0 ]; then
    printf 'test_reconstruct_closure_source=accepted\n'
    exit 0
fi
printf 'test_reconstruct_closure_source=failed failures=%s\n' "$failures" >&2
exit 1
