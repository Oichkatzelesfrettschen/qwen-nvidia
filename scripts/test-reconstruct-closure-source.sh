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
fixture_config_before=$(git -C "$fixture_repository" config --local --list | sha256sum | cut -d ' ' -f 1)
fixture_refs_before=$(git -C "$fixture_repository" show-ref | sha256sum | cut -d ' ' -f 1)

# Two patches where the second's context is the first's result, so the apply
# order is observable: reversing them refuses rather than commuting to the same
# tree, which is what makes an ordered manifest a claim about order.
patch_directory="$temporary_directory/patches"
mkdir -p "$patch_directory"
cat > "$patch_directory/touch-alpha.patch" <<'PATCH'
--- a/alpha.txt
+++ b/alpha.txt
@@ -1 +1 @@
-alpha
+alpha changed
PATCH
cat > "$patch_directory/depends-on-alpha.patch" <<'PATCH'
--- a/alpha.txt
+++ b/alpha.txt
@@ -1 +1,2 @@
 alpha changed
+alpha extended
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

# The expected digests are computed here from plain git and sha256sum rather
# than from the reconstructor, so the suite is not its own oracle: a
# reconstructor that hashed with a different algorithm, staged differently, or
# skipped a patch would disagree with these values rather than define them.
independent_digest() {
    independent_tree="$temporary_directory/independent"
    rm -rf "$independent_tree"
    git -c core.fsmonitor=false clone --quiet --no-checkout --shared \
        "$fixture_repository" "$independent_tree"
    git -c core.fsmonitor=false -C "$independent_tree" checkout --quiet "$fixture_pin"
    for independent_patch in "$@"; do
        git -c core.fsmonitor=false -C "$independent_tree" apply \
            "$patch_directory/$independent_patch.patch" || return 1
    done
    git -c core.fsmonitor=false -C "$independent_tree" add -A >/dev/null 2>&1
    git -c core.fsmonitor=false -C "$independent_tree" diff --binary HEAD -- |
        sha256sum | cut -d ' ' -f 1
}

alpha_digest=$(independent_digest touch-alpha)
both_digest=$(independent_digest touch-alpha touch-beta)
dependent_digest=$(independent_digest touch-alpha depends-on-alpha)

# A digest is 64 lowercase hex characters. A reconstructor hashing with a
# shorter algorithm would still agree with itself and disagree here.
for digest_label in alpha both dependent; do
    case $digest_label in
        alpha) digest_value=$alpha_digest ;;
        both) digest_value=$both_digest ;;
        *) digest_value=$dependent_digest ;;
    esac
    case $digest_value in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
            printf 'ok digest_is_sha256 %s %s\n' "$digest_label" \
                "$(printf '%s' "$digest_value" | cut -c1-12)" ;;
        *)
            printf 'FAIL digest_is_sha256 %s value=%s\n' "$digest_label" "$digest_value"
            failures=$((failures + 1)) ;;
    esac
done

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

# --- order dependence: the second patch's context is the first's result, so a
# reversed manifest refuses rather than reaching the same tree
cat > "$temporary_directory/ordered.tsv" <<MANIFEST
control	known-good	$patch_directory	$alpha_digest	touch-alpha
subject	in-order	$patch_directory	$dependent_digest	touch-alpha depends-on-alpha
subject	reversed	$patch_directory	$dependent_digest	depends-on-alpha touch-alpha
MANIFEST
check ordered_run_status 0 "$(run_manifest "$temporary_directory/ordered.tsv")"
check order_in_order_matches 1 \
    "$(grep -c 'label=in-order.*match=yes' "$temporary_directory/run.out")"
check order_reversed_refuses 1 \
    "$(grep -c 'label=reversed.*digest=refused:depends-on-alpha' "$temporary_directory/run.out")"

# --- a subject never publishes a reading under a failed control, since a
# reader could quote a match out of a refused run
cat > "$temporary_directory/subject-first.tsv" <<MANIFEST
subject	early	$patch_directory	$both_digest	touch-alpha touch-beta
control	broken	$patch_directory	$both_digest	touch-alpha
MANIFEST
check subject_first_status 1 "$(run_manifest "$temporary_directory/subject-first.tsv")"
check subject_withheld_under_failed_control 0 \
    "$(grep -c 'role=subject' "$temporary_directory/run.out")"

# --- a manifest whose last row carries no terminating newline keeps that row
printf 'control\tknown-good\t%s\t%s\ttouch-alpha\n' "$patch_directory" "$alpha_digest" \
    > "$temporary_directory/unterminated.tsv"
printf 'subject\tfinal\t%s\t%s\ttouch-alpha touch-beta' "$patch_directory" "$both_digest" \
    >> "$temporary_directory/unterminated.tsv"
check unterminated_status 0 "$(run_manifest "$temporary_directory/unterminated.tsv")"
check unterminated_keeps_final_row 1 \
    "$(grep -c 'label=final.*match=yes' "$temporary_directory/run.out")"

# --- a patch token carrying a glob selects nothing from the caller's directory
cat > "$temporary_directory/glob.tsv" <<MANIFEST
control	known-good	$patch_directory	$alpha_digest	touch-alpha
subject	globbed	$patch_directory	-	touch-*
MANIFEST
check glob_status 0 "$(run_manifest "$temporary_directory/glob.tsv")"
check glob_is_a_literal_name 1 \
    "$(grep -c 'label=globbed.*digest=absent:touch-\*' "$temporary_directory/run.out")"

# --- an inherited GIT_INDEX_FILE must not aim the reconstruction at the source
# repository's index. That variable pointed at a live tree's index once erased
# its staged diff, which is the one copy of a candidate closure's identity.
git -C "$fixture_repository" checkout --quiet -- . 2>/dev/null || true
printf 'staged content\n' > "$fixture_repository/alpha.txt"
git -C "$fixture_repository" add alpha.txt
staged_index_before=$(git -C "$fixture_repository" ls-files -s | sha256sum | cut -d ' ' -f 1)
routed_work=$(mktemp -d "$temporary_directory/routed.XXXXXX"); rmdir "$routed_work"
GIT_INDEX_FILE="$fixture_repository/.git/index" \
    "$reconstructor" "$fixture_repository" "$fixture_pin" "$routed_work" \
    "$temporary_directory/mixed.tsv" >/dev/null 2>&1 || true
check source_index_preserved "$staged_index_before" \
    "$(git -C "$fixture_repository" ls-files -s | sha256sum | cut -d ' ' -f 1)"
check source_worktree_preserved 'staged content' "$(cat "$fixture_repository/alpha.txt")"
git -C "$fixture_repository" reset --quiet --hard "$fixture_pin"

# The source repository is never written to: reconstruction happens in a clone.
# HEAD, the working tree, the index, and the local configuration are each
# compared, because a check reading only HEAD and porcelain status passed while
# a configuration write went through.
check source_repository_clean '' "$(git -C "$fixture_repository" status --porcelain)"
check source_repository_head "$fixture_pin" "$(git -C "$fixture_repository" rev-parse HEAD)"
check source_repository_config "$fixture_config_before" \
    "$(git -C "$fixture_repository" config --local --list | sha256sum | cut -d ' ' -f 1)"
check source_repository_refs "$fixture_refs_before" \
    "$(git -C "$fixture_repository" show-ref | sha256sum | cut -d ' ' -f 1)"

if [ "$failures" -eq 0 ]; then
    printf 'test_reconstruct_closure_source=accepted\n'
    exit 0
fi
printf 'test_reconstruct_closure_source=failed failures=%s\n' "$failures" >&2
exit 1
