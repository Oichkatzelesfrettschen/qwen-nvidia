#!/bin/sh
# Hold the compute lease across the paths that allocate on CUDA0 during a model
# load. The lease admits one active device workload, and a load uploads weights
# and a projector to the device, so a load outside the lease puts a router
# child's allocation beside an image generation the lease exists to separate it
# from.
#
# The reach stage applies patches/llama-server-vulkan-workload-lease.patch to a
# copy of the pinned source and reads the resulting file, so coverage follows
# the order of the call sites the compiler would see rather than which hunk a
# line arrived in. The served stage drives a real llama-server against a held
# lease. Each stage names its own terminal state, and the script reports
# accepted only where both ran and passed.
set -eu

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    printf '  QWEN_LLAMA_SOURCE names the pinned llama.cpp tree\n' >&2
    printf '  QWEN_LEASE_TEST_SERVER names a patched llama-server\n' >&2
    printf '  QWEN_LEASE_TEST_MODEL names a GGUF it can decode with\n' >&2
    printf '  QWEN_LEASE_TEST_MMPROJ names a projector for the second arm\n' >&2
    printf '  QWEN_LEASE_TEST_PORT sets the port the arm serves on\n' >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
source_directory=${QWEN_LLAMA_SOURCE:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
context_source=$source_directory/tools/server/server-context.cpp
patch_file=$repository_directory/patches/llama-server-vulkan-workload-lease.patch
serving_port=${QWEN_LEASE_TEST_PORT:-18114}
temporary_directory=$(mktemp -d)
holder_group=''
server_pid=''
reach_state=not_run
reach_reason=''
served_state=not_run
served_reason=''
failures=0

cleanup() {
    if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    # flock in command mode forks its command, so the descriptor the lock
    # attaches to lives in a descendant. The holder runs under setsid and the
    # whole group is signalled, which is what releases the lock before the
    # directory holding its file is removed.
    release_holder
    rm -rf "$temporary_directory"
}

# The holder's lock lives in a descendant of the flock command, so the group is
# signalled and the wait runs until the group is gone. The pid is kept until
# then, since clearing it early loses the handle the wait needs.
release_holder() {
    [ -n "$holder_group" ] || return 0
    kill "-$holder_group" 2>/dev/null || true
    wait "$holder_group" 2>/dev/null || true
    holder_wait=0
    while kill -0 "-$holder_group" 2>/dev/null && [ "$holder_wait" -lt 100 ]; do
        holder_wait=$((holder_wait + 1))
        sleep 0.1
    done
    if kill -0 "-$holder_group" 2>/dev/null; then
        printf 'FAIL served the fixture holder survived its signal group=%s\n' \
            "$holder_group" >&2
    fi
    holder_group=''
}
trap 'cleanup' EXIT
trap 'cleanup; exit 143' HUP INT TERM

fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf 'ok %s\n' "$1"
}

skip() {
    printf 'not_run %s reason=%s\n' "$1" "$2"
}

# One reader for every predicate below: the first statement line in a range
# that names a string, with line comments, block comments, and string literals
# removed, since text naming a call site executes nothing. The reading is
# textual over the patched file rather than a compiled control-flow analysis:
# a call reached through a preprocessor branch this host compiles out would
# still count, which is why the served stage measures what a request behind a
# held lease receives.
classify_statement() {
    awk -v name="$1" -v start="$2" -v limit="$3" '
        {
            line = $0
            # Block-comment state carries across lines, so a call named
            # inside /* */ is excluded wherever the delimiters sit.
            if (in_block) {
                if (index(line, "*/") > 0) {
                    sub(/^.*\*\//, "", line)
                    in_block = 0
                } else { next }
            }
            while (index(line, "/*") > 0) {
                head = substr(line, 1, index(line, "/*") - 1)
                rest = substr(line, index(line, "/*") + 2)
                if (index(rest, "*/") > 0) {
                    sub(/^.*\*\//, "", rest)
                    line = head rest
                } else { line = head; in_block = 1; break }
            }
            if (index(line, "//") > 0) {
                line = substr(line, 1, index(line, "//") - 1)
            }
            # A call inside a string literal is text the compiler stores
            # rather than a call it emits.
            gsub(/"[^"]*"/, "", line)
            if (NR < start || NR >= limit) { next }
            if (index(line, name) > 0) { print NR; exit }
        }' "$4"
}

# The reach predicate over one file. It prints `covered` where an open and an
# acquire both appear as statements inside load_model ahead of the first device
# allocation, and `uncovered` otherwise, so an acquire that sits after the
# upload or in another function answers the same way a missing one does.
# Line comments, block comments, and string literals are excluded, since text
# naming a call site executes nothing. The reading is textual over the patched
# file rather than a compiled control-flow analysis: a call reached through a
# preprocessor branch this host compiles out would still count, which is why
# the served stage measures what a request behind a held lease receives.
classify_load_coverage() {
    classify_file=$1

    classify_start=$(grep -n -- 'bool load_model(common_params & params)' \
        "$classify_file" | head -1 | cut -d: -f1)
    classify_weights=$(grep -n -- 'llama_init = common_init_from_params(params_base);' \
        "$classify_file" | head -1 | cut -d: -f1)

    if [ -z "$classify_start" ] || [ -z "$classify_weights" ] ||
        [ "$classify_start" -ge "$classify_weights" ]; then
        printf 'unreadable\n'
        return 0
    fi



    classify_open=$(classify_statement 'workload_lease_open()' \
        "$classify_start" "$classify_weights" "$classify_file")
    # The acquire is matched by prefix, because the load path and the decode
    # path call two functions with two wait semantics and the reach stage has
    # to name which one the load took.
    classify_acquire=$(classify_statement 'workload_lease_acquire' \
        "$classify_start" "$classify_weights" "$classify_file")

    # workload_lease_acquire returns true while the descriptor is closed, so an
    # acquire ahead of its own open admits every load silently.
    if [ -n "$classify_open" ] && [ -n "$classify_acquire" ] &&
        [ "$classify_open" -lt "$classify_acquire" ]; then
        classify_name=$(sed -n "${classify_acquire}p" "$classify_file" |
            sed -n 's/.*\(workload_lease_acquire[a-z_]*\)(.*/\1/p')
        printf 'covered open=%s acquire=%s calls=%s weights=%s\n' \
            "$classify_open" "$classify_acquire" "${classify_name:-unnamed}" \
            "$classify_weights"
    else
        printf 'uncovered open=%s acquire=%s weights=%s\n' \
            "${classify_open:-absent}" "${classify_acquire:-absent}" "$classify_weights"
    fi
}

# The sleeping refusal. server_queue::start_loop treats a negative idle interval
# as sleeping off and every other value as sleeping on, and a wake reaches
# load_model through a void callback that clears the queue's sleeping flag
# whatever the wake returned, so a lease-holding server refuses the
# configuration ahead of the acquire rather than covering a state it cannot
# report a refusal through. The refusal is read where the acquire is read: as a
# statement inside load_model ahead of the first upload, and ahead of the
# acquire, since a refusal beneath the acquire takes the lease and gives it back.
classify_sleep_refusal() {
    classify_file=$1

    classify_start=$(grep -n -- 'bool load_model(common_params & params)' \
        "$classify_file" | head -1 | cut -d: -f1)
    classify_weights=$(grep -n -- 'llama_init = common_init_from_params(params_base);' \
        "$classify_file" | head -1 | cut -d: -f1)

    if [ -z "$classify_start" ] || [ -z "$classify_weights" ] ||
        [ "$classify_start" -ge "$classify_weights" ]; then
        printf 'unreadable\n'
        return 0
    fi

    classify_refusal=$(classify_statement 'sleep_idle_seconds' \
        "$classify_start" "$classify_weights" "$classify_file")
    classify_acquire=$(classify_statement 'workload_lease_acquire' \
        "$classify_start" "$classify_weights" "$classify_file")

    # Naming the field is not refusing on it: `(void) params.sleep_idle_seconds;`
    # reads the same as a guard unless the statement is required to leave the
    # function. The refusal's own block carries that return, so it is read
    # inside the block rather than anywhere after it.
    classify_leaves=''
    if [ -n "$classify_refusal" ] && [ -n "$classify_acquire" ]; then
        # The window ends at the acquire, so the return the acquire's own
        # refusal carries never stands in for the sleeping one.
        classify_window=$((classify_refusal + 6))
        if [ "$classify_window" -gt "$classify_acquire" ]; then
            classify_window=$classify_acquire
        fi
        classify_leaves=$(classify_statement 'return false' "$classify_refusal" \
            "$classify_window" "$classify_file")
    fi

    if [ -n "$classify_refusal" ] && [ -n "$classify_acquire" ] &&
        [ -n "$classify_leaves" ] &&
        [ "$classify_refusal" -lt "$classify_acquire" ] &&
        [ "$classify_leaves" -lt "$classify_acquire" ]; then
        printf 'refuses refusal=%s returns=%s acquire=%s\n' \
            "$classify_refusal" "$classify_leaves" "$classify_acquire"
    else
        printf 'admits refusal=%s returns=%s acquire=%s\n' \
            "${classify_refusal:-absent}" "${classify_leaves:-absent}" \
            "${classify_acquire:-absent}"
    fi
}

# The completion boundary. llama_decode queues its graph and returns, so a
# release taken at that boundary hands the lease on while the kernels run. The
# predicate reads the call sites outside the two definitions in file order and
# requires a synchronize ahead of every release with no release between them, so
# a second release site added without its own synchronize answers uncovered.
classify_release_after_sync() {
    classify_file=$1

    classify_order=$(awk '
        {
            line = $0
            if (in_block) {
                if (index(line, "*/") > 0) { sub(/^.*\*\//, "", line); in_block = 0 } else { next }
            }
            while (index(line, "/*") > 0) {
                head = substr(line, 1, index(line, "/*") - 1)
                rest = substr(line, index(line, "/*") + 2)
                if (index(rest, "*/") > 0) { sub(/^.*\*\//, "", rest); line = head rest }
                else { line = head; in_block = 1; break }
            }
            if (index(line, "//") > 0) { line = substr(line, 1, index(line, "//") - 1) }
            gsub(/"[^"]*"/, "", line)
            # The definitions declare a return type; the call sites do not.
            # A member function header opens at one indent inside the class,
            # so it separates the scope of one call site from the next: a
            # synchronize in destroy covers no release in update_slots.
            if (line ~ /^    [A-Za-z_][A-Za-z0-9_:<>* &]*[ *&]([A-Za-z_][A-Za-z0-9_]*)\(.*\)[ ]*\{/) {
                scope = NR
            }
            if (line ~ /workload_lease_sync_device\(\)/ && line !~ /void[[:space:]]+workload_lease_sync_device/) {
                printf "sync %s %s\n", NR, scope
            }
            if (line ~ /workload_lease_release\(\)/ && line !~ /bool[[:space:]]+workload_lease_release/) {
                printf "release %s %s\n", NR, scope
            }
        }' "$classify_file")

    classify_verdict=$(printf '%s\n' "$classify_order" | awk '
        $1 == "sync"    { armed = 1; armed_scope = $3 }
        $1 == "release" {
            releases = releases + 1
            if (!armed || armed_scope != $3) { bad = bad " " $2 }
            armed = 0
        }
        END {
            if (releases == 0) { print "absent"; exit }
            if (bad != "") { printf "unsynchronized%s\n", bad; exit }
            printf "synchronized releases=%s\n", releases
        }')

    printf '%s\n' "$classify_verdict"
}

# The unlock reports what the kernel confirmed. flock(LOCK_UN) fails before it
# changes anything, so a failure leaves the lock held: the failure branch has to
# leave the function ahead of the assignment that says the lease went back, or
# the next acquire returns true on a hold the kernel declined to give up.
classify_release_preserves_hold() {
    classify_file=$1

    classify_start=$(grep -n -- 'bool workload_lease_release()' "$classify_file" |
        head -1 | cut -d: -f1)
    if [ -z "$classify_start" ]; then
        printf 'absent\n'
        return 0
    fi

    classify_end=$(awk -v start="$classify_start" '
        NR < start { next }
        {
            line = $0; opens = gsub(/\{/, "{", line)
            line = $0; closes = gsub(/\}/, "}", line)
            depth = depth + opens - closes
            seen = seen || opens > 0
            if (seen && depth <= 0) { print NR; exit }
        }' "$classify_file")
    [ -n "$classify_end" ] || classify_end=$classify_start

    classify_unlock=$(classify_statement 'LOCK_UN' "$classify_start" \
        "$((classify_end + 1))" "$classify_file")
    classify_cleared=$(classify_statement 'workload_lease_held = false' \
        "$classify_start" "$((classify_end + 1))" "$classify_file")
    # The return is read at the depth the failure block itself opens, so a
    # return nested inside a latch that admits one log line reads absent: that
    # body leaves the second failure to fall through to the assignment.
    classify_returns=$(awk -v start="$classify_unlock" -v limit="$((classify_end + 1))" '
        NR < start || NR >= limit { next }
        {
            line = $0
            if (index(line, "//") > 0) { line = substr(line, 1, index(line, "//") - 1) }
            gsub(/"[^"]*"/, "", line)
            before = depth
            opens = gsub(/\{/, "{", line)
            line = $0
            if (index(line, "//") > 0) { line = substr(line, 1, index(line, "//") - 1) }
            gsub(/"[^"]*"/, "", line)
            closes = gsub(/\}/, "}", line)
            depth = depth + opens - closes
            if (before == 1 && depth >= 1 && index($0, "return false") > 0) {
                print NR
                exit
            }
        }' "$classify_file")

    if [ -n "$classify_unlock" ] && [ -n "$classify_returns" ] &&
        [ -n "$classify_cleared" ] &&
        [ "$classify_unlock" -lt "$classify_returns" ] &&
        [ "$classify_returns" -lt "$classify_cleared" ]; then
        printf 'preserved unlock=%s refusal=%s cleared=%s\n' \
            "$classify_unlock" "$classify_returns" "$classify_cleared"
    else
        printf 'cleared unlock=%s refusal=%s cleared=%s\n' \
            "${classify_unlock:-absent}" "${classify_returns:-absent}" \
            "${classify_cleared:-absent}"
    fi
}

# The predicate answers a synthetic covered file and three synthetic uncovered
# ones before it answers the real one, because a classifier that reads hunk
# membership rather than executed order calls an acquire placed after the
# upload covered.
self_test_predicate() {
    self_test_root=$temporary_directory/self-test
    mkdir -p "$self_test_root"

    self_test_write() {
        {
            printf '    bool load_model(common_params & params) {\n'
            printf '%s\n' "$2"
            printf '        llama_init = common_init_from_params(params_base);\n'
            printf '%s\n' "$3"
            printf '    }\n'
        } >"$self_test_root/$1"
    }

    self_test_write covered.cpp \
        '        if (!workload_lease_open()) { return false; }
        if (!workload_lease_acquire_bounded()) { return false; }' ''
    self_test_write after-upload.cpp '' \
        '        if (!workload_lease_open()) { return false; }
        if (!workload_lease_acquire_bounded()) { return false; }'
    self_test_write comment-only.cpp \
        '        // workload_lease_acquire() would go here
        // workload_lease_open() would go here' ''
    self_test_write block-comment.cpp \
        '        /* workload_lease_open() and
           workload_lease_acquire() belong here */' ''
    self_test_write string-literal.cpp \
        '        SRV_INF("%s", "workload_lease_open() workload_lease_acquire()");' ''
    self_test_write acquire-before-open.cpp \
        '        if (!workload_lease_acquire_bounded()) { return false; }
        if (!workload_lease_open()) { return false; }' ''

    self_test_expect_with() {
        self_test_answer=$("$1" "$self_test_root/$2")
        case $self_test_answer in
        "$3"*) pass "predicate_self_test $1 $2=$3" ;;
        *) fail "predicate_self_test $1 $2 expected=$3 read=$self_test_answer" ;;
        esac
    }

    self_test_expect() {
        self_test_expect_with classify_load_coverage "$1" "$2"
    }

    self_test_expect covered.cpp covered
    self_test_expect after-upload.cpp uncovered
    self_test_expect comment-only.cpp uncovered
    self_test_expect block-comment.cpp uncovered
    self_test_expect string-literal.cpp uncovered
    self_test_expect acquire-before-open.cpp uncovered

    # Each predicate added since answers a body that satisfies it and one that
    # does not, because an ordering read over line numbers is the same
    # brittleness class as the hunk membership this stage replaced.
    self_test_write sleep-refused.cpp \
        '        if (!workload_lease_open()) { return false; }
        if (workload_lease_descriptor >= 0 && params.sleep_idle_seconds >= 0) { return false; }
        if (!workload_lease_acquire_bounded()) { return false; }' ''
    self_test_write sleep-after-acquire.cpp \
        '        if (!workload_lease_open()) { return false; }
        if (!workload_lease_acquire_bounded()) { return false; }
        if (params.sleep_idle_seconds >= 0) { return false; }' ''
    self_test_write sleep-admitted.cpp \
        '        if (!workload_lease_open()) { return false; }
        if (!workload_lease_acquire_bounded()) { return false; }' ''

    self_test_expect_with classify_sleep_refusal sleep-refused.cpp refuses
    self_test_expect_with classify_sleep_refusal sleep-after-acquire.cpp admits
    self_test_expect_with classify_sleep_refusal sleep-admitted.cpp admits

    self_test_release() {
        {
            printf '    void workload_lease_sync_device() {\n'
            printf '        llama_synchronize(ctx_tgt);\n'
            printf '    }\n'
            printf '    bool workload_lease_release() {\n'
            printf '%s\n' "$3"
            printf '    }\n'
            printf '    void destroy() {\n'
            printf '%s\n' "$2"
            printf '    }\n'
        } >"$self_test_root/$1"
    }

    self_test_release_body_ok='        if (flock(workload_lease_descriptor, LOCK_UN) != 0) {
            return false;
        }
        workload_lease_held = false;
        return true;'
    self_test_release_body_clears='        if (flock(workload_lease_descriptor, LOCK_UN) != 0) {
            SRV_ERR("release failed");
        }
        workload_lease_held = false;
        return false;'

    self_test_release sync-then-release.cpp \
        '        workload_lease_sync_device();
        workload_lease_release();' "$self_test_release_body_ok"
    self_test_release release-alone.cpp \
        '        workload_lease_release();' "$self_test_release_body_ok"
    self_test_release second-release-unsynced.cpp \
        '        workload_lease_sync_device();
        workload_lease_release();
        workload_lease_release();' "$self_test_release_body_ok"
    self_test_release clears-on-failure.cpp \
        '        workload_lease_sync_device();
        workload_lease_release();' "$self_test_release_body_clears"
    self_test_release_body_latched='        if (flock(workload_lease_descriptor, LOCK_UN) != 0) {
            if (!workload_lease_release_failed) {
                workload_lease_release_failed = true;
                return false;
            }
        }
        workload_lease_held = false;
        return true;'
    self_test_release latched-return.cpp \
        '        workload_lease_sync_device();
        workload_lease_release();' "$self_test_release_body_latched"

    self_test_expect_with classify_release_after_sync sync-then-release.cpp synchronized
    self_test_expect_with classify_release_after_sync release-alone.cpp unsynchronized
    self_test_expect_with classify_release_after_sync second-release-unsynced.cpp unsynchronized
    self_test_expect_with classify_release_preserves_hold sync-then-release.cpp preserved
    self_test_expect_with classify_release_preserves_hold clears-on-failure.cpp cleared
    self_test_expect_with classify_release_preserves_hold latched-return.cpp cleared
}

# The reach stage. The patch touches one file, so a copy of that file under the
# path the diff names is the whole tree it needs.
if [ ! -f "$context_source" ]; then
    reach_reason=no_pinned_source:$context_source
    skip reach "$reach_reason"
elif [ ! -f "$patch_file" ]; then
    reach_state=refused
    fail "reach patch_missing=$patch_file"
elif ! command -v patch >/dev/null 2>&1; then
    reach_reason=no_patch_command
    skip reach "$reach_reason"
else
    patched_tree=$temporary_directory/patched
    mkdir -p "$patched_tree/tools/server"
    cp "$context_source" "$patched_tree/tools/server/server-context.cpp"
    if ! (cd "$patched_tree" && patch -p1 --forward --silent <"$patch_file"); then
        reach_state=refused
        fail 'reach the lease patch no longer applies to the pinned source'
    else
        patched_file=$patched_tree/tools/server/server-context.cpp
        reach_state=accepted

        # Every position below is read from the patched file, so an added call
        # site is compared against the allocations by line number rather than
        # by the hunk it arrived in.
        line_of() {
            grep -n -- "$1" "$patched_file" | head -1 | cut -d: -f1
        }

        load_model_line=$(line_of 'bool load_model(common_params & params)')
        weights_line=$(line_of 'llama_init = common_init_from_params(params_base);')
        projector_line=$(line_of 'mctx = mtmd_init_from_file(')
        # The draft context is the third allocation the load performs, and the
        # coverage predicate measures against the first of the three, so their
        # order is asserted rather than assumed.
        spec_line=$(line_of 'spec_init = common_speculative_init_from_params(')
        # load_model carries two is_resume guards, so the one that skips
        # init() is found from the guarded call rather than from the flag.
        init_call_line=$(line_of 'return init();')

        if [ -z "$load_model_line" ] || [ -z "$weights_line" ] ||
            [ -z "$projector_line" ]; then
            reach_state=refused
            fail 'reach the patched source names no load path to measure'
        else
            # load_model's extent by brace depth, so a function reordered above
            # or below it moves nothing here.
            load_model_end=$(awk -v start="$load_model_line" '
                NR < start { next }
                {
                    line = $0
                    opens = gsub(/\{/, "{", line)
                    line = $0
                    closes = gsub(/\}/, "}", line)
                    depth = depth + opens - closes
                    seen = seen || opens > 0
                    if (seen && depth <= 0) { print NR; exit }
                }' "$patched_file")
            [ -n "$load_model_end" ] || load_model_end=$weights_line

            printf 'load_path load_model=%s..%s weights=%s projector=%s\n' \
                "$load_model_line" "$load_model_end" "$weights_line" "$projector_line"

            self_test_predicate

            coverage=$(classify_load_coverage "$patched_file")
            case $coverage in
            covered*) pass "load_path_covered $coverage" ;;
            *)
                reach_state=refused
                fail "load_path_covered=no $coverage -- the model and projector upload outside the lease"
                ;;
            esac

            # The predicate above measures the acquire against the weights, so
            # the weights have to be the earliest of the three allocations for
            # that reading to cover the projector and the draft context too.
            if [ -n "$spec_line" ] && [ "$weights_line" -lt "$projector_line" ] &&
                [ "$weights_line" -lt "$spec_line" ]; then
                pass "load_allocations_ordered weights=$weights_line projector=$projector_line spec=$spec_line"
            else
                reach_state=refused
                fail "load_allocations_ordered=no weights=$weights_line projector=$projector_line spec=${spec_line:-absent} -- the coverage reading measures against the wrong allocation"
            fi

            sleep_refusal=$(classify_sleep_refusal "$patched_file")
            case $sleep_refusal in
            refuses*) pass "sleep_refused_before_acquire $sleep_refusal" ;;
            *)
                reach_state=refused
                fail "sleep_refused_before_acquire=no $sleep_refusal -- a wake under the lease reports its refusal through a void callback"
                ;;
            esac

            release_sync=$(classify_release_after_sync "$patched_file")
            case $release_sync in
            synchronized*) pass "release_after_device_completion $release_sync" ;;
            *)
                reach_state=refused
                fail "release_after_device_completion=no $release_sync -- a release at a host return hands the lease on with graphs in flight"
                ;;
            esac

            release_hold=$(classify_release_preserves_hold "$patched_file")
            case $release_hold in
            preserved*) pass "release_failure_preserves_hold $release_hold" ;;
            *)
                reach_state=refused
                fail "release_failure_preserves_hold=no $release_hold -- a refused unlock would report a lease the kernel still holds as given back"
                ;;
            esac

            # handle_sleeping_state reaches load_model with is_resume true, and
            # the guarded call is what a wake skips, so the guard is read
            # rather than the flag's declaration.
            if [ -n "$init_call_line" ] && [ "$init_call_line" -gt 1 ] &&
                sed -n "$((init_call_line - 1))p" "$patched_file" |
                grep -q 'if (!is_resume)'; then
                pass "resume_skips_init guard=$((init_call_line - 1)) init_call=$init_call_line"
            else
                reach_state=refused
                fail 'resume_skips_init the guarded init() call moved, so the resume path needs rereading'
            fi

            # The bound is a property of the function the load path calls
            # rather than of the file. The decode pass blocks on purpose --
            # update_slots re-enters only when a task arrives, so a pass that
            # gave up would strand its request -- while a load has a caller
            # that carries a refusal and takes a deadline instead. The check
            # therefore reads the called function's own body.
            acquire_name=$(printf '%s\n' "$coverage" |
                sed -n 's/.*calls=\([a-z_]*\).*/\1/p')
            acquire_definition=$(grep -n "bool $acquire_name(" "$patched_file" |
                head -1 | cut -d: -f1)
            if [ -z "$acquire_name" ] || [ -z "$acquire_definition" ]; then
                reach_state=refused
                fail "lease_wait_bounded the load path calls ${acquire_name:-nothing} and the file defines no such acquire"
            else
                acquire_end=$(awk -v start="$acquire_definition" '
                    NR < start { next }
                    {
                        line = $0; opens = gsub(/\{/, "{", line)
                        line = $0; closes = gsub(/\}/, "}", line)
                        depth = depth + opens - closes
                        seen = seen || opens > 0
                        if (seen && depth <= 0) { print NR; exit }
                    }' "$patched_file")
                [ -n "$acquire_end" ] || acquire_end=$acquire_definition
                blocking_flock=$(awk -v start="$acquire_definition" -v end="$acquire_end" '
                    NR >= start && NR <= end &&
                        $0 ~ /flock\([^)]*LOCK_EX\)/ &&
                        $0 !~ /^[[:space:]]*\/\// { count = count + 1 }
                    END { print count + 0 }' "$patched_file")
                if [ "$blocking_flock" -eq 0 ]; then
                    pass "lease_wait_bounded $acquire_name=$acquire_definition..$acquire_end blocks on no flock"
                else
                    reach_state=refused
                    fail "lease_wait_bounded=no $acquire_name blocks on $blocking_flock flock call(s) -- a load behind a generation stalls its request"
                fi
            fi
        fi
    fi
fi

# The served stage. Six arms, each naming its own hold, its own deadline, and
# its own required outcome, because a refusal and a successful wait are two
# behaviors and one arm that accepts either measures neither. Elapsed time is
# read from /proc/uptime rather than the wall clock, since a clock step under
# NTP moves a deadline the kernel does not honor.
served_server=${QWEN_LEASE_TEST_SERVER:-}
served_model=${QWEN_LEASE_TEST_MODEL:-}
served_mmproj=${QWEN_LEASE_TEST_MMPROJ:-}
if [ -z "$served_server" ] || [ ! -x "$served_server" ]; then
    served_reason=no_patched_server
    skip served "$served_reason"
elif [ -z "$served_model" ] || [ ! -f "$served_model" ]; then
    served_reason=no_model
    skip served "$served_reason"
elif ! command -v setsid >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    served_reason=no_flock_or_setsid
    skip served "$served_reason"
elif ! command -v curl >/dev/null 2>&1; then
    served_reason=no_curl
    skip served "$served_reason"
else
    served_state=accepted
    lease_path=$temporary_directory/vulkan-workload.lock
    hold_serial=0
    server_serial=0
    server_log=$temporary_directory/server.0.log
    : >"$lease_path"

    # The load allowance covers the whole startup: the lease wait the arm
    # configures, the load the device performs, and a readiness margin. An arm
    # whose allowance fell under its own deadline would read a correct wait as a
    # refusal, so each arm prints the three terms it ran under.
    load_seconds=${QWEN_LEASE_LOAD_S:-90}
    readiness_margin=${QWEN_LEASE_MARGIN_S:-20}

    served_monotonic() {
        awk '{ printf "%d\n", $1 }' /proc/uptime
    }

    # The fixture holder's lock lives in a descendant of the shell that takes
    # it, so the group is what gets signalled and the state file is what proves
    # the lock reached the kernel.
    hold_lease() {
        hold_serial=$((hold_serial + 1))
        holder_state=$temporary_directory/holder-state.$hold_serial
        : >"$holder_state"
        setsid sh -c 'exec 9>"$1"; flock -x 9; printf 'held' >"$2"; sleep "$3"' \
            holder "$lease_path" "$holder_state" "$1" &
        holder_group=$!
        hold_waited=0
        while [ ! -s "$holder_state" ] && [ "$hold_waited" -lt 600 ]; do
            hold_waited=$((hold_waited + 1))
            sleep 0.1
        done
        [ -s "$holder_state" ]
    }

    start_server() {
        server_serial=$((server_serial + 1))
        server_log=$temporary_directory/server.$server_serial.log
        server_wait_s=$1
        shift
        QWEN_GPU_COMPUTE_LEASE=$lease_path \
        QWEN_VULKAN_WORKLOAD_LOCK=$lease_path \
        QWEN_GPU_COMPUTE_LEASE_WAIT_S=$server_wait_s \
        LLAMA_NO_CPU_FALLBACK=1 \
            "$served_server" --model "$served_model" "$@" \
            --host 127.0.0.1 --port "$serving_port" \
            --device CUDA0 -ot '.*=CUDA0' -ngl 99 \
            >"$server_log" 2>&1 &
        server_pid=$!
    }

    stop_server() {
        [ -n "$server_pid" ] || return 0
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=''
    }

    # served, exited, or absent inside the deadline the caller names.
    poll_health() {
        poll_deadline=$(( $(served_monotonic) + $1 ))
        while [ "$(served_monotonic)" -lt "$poll_deadline" ]; do
            if [ -n "$server_pid" ] && ! kill -0 "$server_pid" 2>/dev/null; then
                printf 'exited\n'
                return 0
            fi
            if curl -fsS --max-time 2 \
                "http://127.0.0.1:$serving_port/health" >/dev/null 2>&1; then
                printf 'served\n'
                return 0
            fi
            sleep 0.2
        done
        printf 'absent\n'
    }

    answers() {
        curl -fsS --max-time 120 \
            -H 'Content-Type: application/json' \
            -d '{"prompt":"Reply with the word ok.","n_predict":8,"temperature":0}' \
            "http://127.0.0.1:$serving_port/completion" 2>/dev/null |
            grep -q '"content"'
    }

    # An unpatched server handed a lease path loads and answers exactly as one
    # that skipped the lease would, because the open returns true on an unset
    # name and every acquire returns true while the descriptor is closed. The
    # armed line is the positive control that the binary under test carries the
    # patch at all, and no arm below is read without it.
    arm_armed() {
        grep -q 'workload lease armed' "$server_log"
    }

    # Health staying absent under a hold is also what a server that ignored the
    # lease and uploaded slowly produces, so the log is read for the wait
    # itself: the acquire writes `waiting` before it blocks and `acquired ...
    # bound=deadline` after it takes the lease. The armed line proves the
    # descriptor opened; this pair proves the load waited on it.
    arm_waited_for_lease() {
        grep -q 'workload lease waiting' "$server_log" &&
            grep -q 'workload lease acquired.*bound=deadline' "$server_log"
    }

    # Arm A. The holder releases inside the configured deadline, so the same
    # process waits, loads, answers, and gives the lease back at its first idle
    # pass.
    arm_a_hold=${QWEN_LEASE_A_HOLD_S:-10}
    arm_a_wait=$((arm_a_hold + load_seconds + readiness_margin))
    printf 'served_arm=load_after_wait hold_s=%s wait_s=%s load_allowance_s=%s margin_s=%s\n' \
        "$arm_a_hold" "$arm_a_wait" "$load_seconds" "$readiness_margin"
    if ! hold_lease "$arm_a_hold"; then
        served_state=refused
        fail 'load_after_wait the fixture owner never took the lease'
    else
        arm_a_start=$(served_monotonic)
        start_server "$arm_a_wait"
        # The hold is short, so health inside it is the whole observation: a
        # server that answered here loaded beside the holder.
        arm_a_under_hold=$(poll_health "$((arm_a_hold - 2))")
        if ! arm_armed; then
            served_state=refused
            fail 'lease_armed the server under test never opened the lease -- the closure carries no lease patch'
        elif [ "$arm_a_under_hold" = served ]; then
            served_state=refused
            fail 'load_after_wait the model loaded and served under a held lease'
        else
            pass "lease_armed $(grep -m1 'workload lease armed' "$server_log" | sed 's/.*armed: //')"
            release_holder
            arm_a_after=$(poll_health "$((load_seconds + readiness_margin))")
            if [ "$arm_a_after" != served ]; then
                served_state=refused
                fail "load_after_wait the release admitted no load: $arm_a_after"
            else
                arm_a_elapsed=$(( $(served_monotonic) - arm_a_start ))
                if ! arm_waited_for_lease; then
                    served_state=refused
                    fail 'load_after_wait the load reached health without reporting a wait -- a slow upload reads the same as a protected one'
                elif answers; then
                    pass "load_after_wait waited, served, and answered elapsed_s=$arm_a_elapsed waited_ms=$(grep -m1 'workload lease acquired' "$server_log" | sed -n 's/.*waited_ms=\([0-9]*\).*/\1/p')"
                else
                    served_state=refused
                    fail 'load_after_wait the loaded server returned no completion'
                fi
                # An idle server holds nothing, so the lease is free between
                # the answer and the next request.
                arm_a_idle=0
                while [ "$arm_a_idle" -lt 100 ] &&
                    ! flock -n "$lease_path" true 2>/dev/null; do
                    arm_a_idle=$((arm_a_idle + 1))
                    sleep 0.1
                done
                if flock -n "$lease_path" true 2>/dev/null; then
                    pass "load_after_wait_releases idle_ms=$((arm_a_idle * 100))"
                else
                    served_state=refused
                    fail 'load_after_wait_releases the idle server kept the lease'
                fi
            fi
        fi
    fi

    # Arm B. The loaded server's decode is what the blocking acquire protects:
    # it waits behind a holder and resumes on the release without a second
    # request, which is the progress invariant a deadline on that call site
    # would break.
    if [ "$served_state" = accepted ] && [ -n "$server_pid" ]; then
        arm_b_hold=${QWEN_LEASE_B_HOLD_S:-12}
        printf 'served_arm=decode_waits hold_s=%s\n' "$arm_b_hold"
        if ! hold_lease "$arm_b_hold"; then
            served_state=refused
            fail 'decode_waits the fixture owner never took the lease'
        else
            arm_b_reply=$temporary_directory/decode-reply.json
            arm_b_done=$temporary_directory/decode-done
            : >"$arm_b_reply"
            (
                curl -fsS --max-time 180 \
                    -H 'Content-Type: application/json' \
                    -d '{"prompt":"Reply with the word ok.","n_predict":8,"temperature":0}' \
                    "http://127.0.0.1:$serving_port/completion" \
                    >"$arm_b_reply" 2>/dev/null || true
                printf 'done' >"$arm_b_done"
            ) &
            arm_b_client=$!

            arm_b_deadline=$(( $(served_monotonic) + arm_b_hold - 3 ))
            arm_b_early=no
            while [ "$(served_monotonic)" -lt "$arm_b_deadline" ]; do
                if [ -s "$arm_b_done" ]; then
                    arm_b_early=yes
                    break
                fi
                sleep 0.2
            done

            if [ "$arm_b_early" = yes ]; then
                served_state=refused
                fail 'decode_waits the request decoded while the fixture held the lease'
            else
                pass "decode_waits no decode inside the hold observed_s=$((arm_b_hold - 3))"
            fi

            release_holder
            arm_b_waited=0
            while [ ! -s "$arm_b_done" ] && [ "$arm_b_waited" -lt 1800 ]; do
                arm_b_waited=$((arm_b_waited + 1))
                sleep 0.1
            done
            wait "$arm_b_client" 2>/dev/null || true

            if grep -q '"content"' "$arm_b_reply" 2>/dev/null; then
                pass "decode_resumes_on_release resumed_ms=$((arm_b_waited * 100)) requests=1"
            else
                served_state=refused
                fail 'decode_resumes_on_release the waiting request never completed after the release'
            fi
        fi
    fi
    # Arm G. Arm E signals a server waiting inside load_model, where
    # server.cpp has yet to install its handlers at :489 and the default
    # disposition ends the process. A decode pass waits after that
    # installation, so this arm is where the handler's own path runs. What it
    # measures either way is the bound and the residue.
    if [ "$served_state" = accepted ] && [ -n "$server_pid" ]; then
        arm_g_hold=${QWEN_LEASE_G_HOLD_S:-120}
        printf 'served_arm=shutdown_while_decode_waits hold_s=%s\n' "$arm_g_hold"
        if ! hold_lease "$arm_g_hold"; then
            served_state=refused
            fail 'shutdown_while_decode_waits the fixture owner never took the lease'
        else
            arm_g_waits_before=$(grep -c 'workload lease waiting' "$server_log" || true)
            arm_g_reply=$temporary_directory/decode-signalled.json
            arm_g_done=$temporary_directory/decode-signalled-done
            : >"$arm_g_reply"
            (
                curl -fsS --max-time 90 \
                    -H 'Content-Type: application/json' \
                    -d '{"prompt":"Reply with the word ok.","n_predict":8,"temperature":0}' \
                    "http://127.0.0.1:$serving_port/completion" \
                    >"$arm_g_reply" 2>/dev/null || true
                printf 'done' >"$arm_g_done"
            ) &
            arm_g_client=$!

            # The log carries arm B's wait already, so the new one is counted
            # rather than matched.
            arm_g_ready=$(( $(served_monotonic) + 20 ))
            while [ "$(served_monotonic)" -lt "$arm_g_ready" ] &&
                [ "$(grep -c 'workload lease waiting' "$server_log" || true)" -le "$arm_g_waits_before" ]; do
                sleep 0.2
            done

            if [ "$(grep -c 'workload lease waiting' "$server_log" || true)" -le "$arm_g_waits_before" ]; then
                served_state=refused
                fail 'shutdown_while_decode_waits the decode pass never reported the wait it was to be interrupted in'
                release_holder
                stop_server
            else
                arm_g_start=$(served_monotonic)
                kill -TERM "$server_pid" 2>/dev/null || true
                arm_g_gone=no
                while [ $(( $(served_monotonic) - arm_g_start )) -lt 30 ]; do
                    if ! kill -0 "$server_pid" 2>/dev/null; then
                        arm_g_gone=yes
                        break
                    fi
                    sleep 0.2
                done
                arm_g_elapsed=$(( $(served_monotonic) - arm_g_start ))
                if [ "$arm_g_gone" != yes ]; then
                    kill -KILL "$server_pid" 2>/dev/null || true
                fi
                wait "$server_pid" 2>/dev/null || true
                server_pid=''
                wait "$arm_g_client" 2>/dev/null || true

                if [ "$arm_g_gone" != yes ]; then
                    served_state=refused
                    fail 'shutdown_while_decode_waits the server outlived its signal inside the decode wait'
                elif flock -n "$lease_path" true 2>/dev/null; then
                    served_state=refused
                    fail 'shutdown_while_decode_waits the fixture lock went free, so the wait was not the state that ended'
                else
                    pass "shutdown_while_decode_waits ended in ${arm_g_elapsed}s with the holder's lock intact"
                fi
                release_holder
            fi
        fi
    fi
    stop_server

    # Arm C. The holder outlives the deadline, so the load refuses by name and
    # allocates nothing: the refusal sits ahead of every loader line.
    arm_c_wait=${QWEN_LEASE_C_WAIT_S:-5}
    arm_c_hold=$((arm_c_wait + load_seconds + readiness_margin))
    printf 'served_arm=refused_on_deadline hold_s=%s wait_s=%s\n' "$arm_c_hold" "$arm_c_wait"
    if ! hold_lease "$arm_c_hold"; then
        served_state=refused
        fail 'refused_on_deadline the fixture owner never took the lease'
    else
        start_server "$arm_c_wait"
        arm_c_result=$(poll_health "$((arm_c_wait + readiness_margin))")
        if [ "$arm_c_result" != exited ]; then
            served_state=refused
            fail "refused_on_deadline the load did not end on its deadline: $arm_c_result"
            stop_server
        elif ! grep -q 'workload lease deadline reached without the lease' "$server_log"; then
            served_state=refused
            fail "refused_on_deadline the server ended for another reason: $(tail -1 "$server_log" | tr -d '\n' | cut -c1-120)"
        elif grep -q 'llama_model_loader\|load_tensors' "$server_log"; then
            served_state=refused
            fail 'refused_on_deadline the refusal followed a model upload rather than preceding it'
        else
            pass "refused_on_deadline named the deadline and uploaded nothing wait_s=$arm_c_wait"
        fi

        # Arm D. Recovery is an explicit fresh attempt rather than a retry
        # inside the refused process, because a server that ended on its
        # deadline cannot become healthy afterwards.
        release_holder
        printf 'served_arm=recovery_after_refusal wait_s=%s\n' "$arm_c_wait"
        start_server "$arm_c_wait"
        arm_d_result=$(poll_health "$((load_seconds + readiness_margin))")
        if [ "$arm_d_result" != served ] || ! answers; then
            served_state=refused
            fail "recovery_after_refusal the fresh attempt did not serve: $arm_d_result"
        else
            pass 'recovery_after_refusal a fresh attempt loaded and answered'
        fi
        stop_server
    fi

    # Arm E. A terminating signal ends a server waiting on the lease inside a
    # bound, and it leaves the holder's lock and no process behind.
    arm_e_wait=${QWEN_LEASE_E_WAIT_S:-600}
    arm_e_hold=$((arm_e_wait + 60))
    printf 'served_arm=shutdown_while_waiting hold_s=%s wait_s=%s\n' "$arm_e_hold" "$arm_e_wait"
    if ! hold_lease "$arm_e_hold"; then
        served_state=refused
        fail 'shutdown_while_waiting the fixture owner never took the lease'
    else
        start_server "$arm_e_wait"
        arm_e_waiting=0
        while [ "$arm_e_waiting" -lt 300 ] &&
            ! grep -q 'workload lease waiting' "$server_log"; do
            arm_e_waiting=$((arm_e_waiting + 1))
            sleep 0.1
        done
        if ! grep -q 'workload lease waiting' "$server_log"; then
            served_state=refused
            fail 'shutdown_while_waiting the server never reported the wait it was to be interrupted in'
            stop_server
        else
            arm_e_start=$(served_monotonic)
            kill -TERM "$server_pid" 2>/dev/null || true
            arm_e_gone=no
            while [ $(( $(served_monotonic) - arm_e_start )) -lt 30 ]; do
                if ! kill -0 "$server_pid" 2>/dev/null; then
                    arm_e_gone=yes
                    break
                fi
                sleep 0.2
            done
            arm_e_elapsed=$(( $(served_monotonic) - arm_e_start ))
            if [ "$arm_e_gone" != yes ]; then
                # The process outlived its bound, so it is killed before the
                # harness waits on it: a blocking wait here would hand the
                # failure an unbounded stall of its own.
                kill -KILL "$server_pid" 2>/dev/null || true
                wait "$server_pid" 2>/dev/null || true
                served_state=refused
                fail 'shutdown_while_waiting the waiting server outlived its signal'
            elif flock -n "$lease_path" true 2>/dev/null; then
                wait "$server_pid" 2>/dev/null || true
                server_pid=''
                served_state=refused
                fail 'shutdown_while_waiting the fixture lock went free, so the wait was not the state that ended'
            else
                wait "$server_pid" 2>/dev/null || true
                server_pid=''
                # server.cpp installs its SIGINT and SIGTERM handlers at :489,
                # after the load_model call at :465, so a signal inside the load
                # path's own wait carries the default disposition. The bound is
                # what this arm measures; the handler's EINTR path belongs to the
                # decode wait below.
                pass "shutdown_while_load_waits ended in ${arm_e_elapsed}s by default disposition, holder lock intact"
            fi
        fi
        release_holder
    fi

    # Arm F. A projector is a second device upload inside the same load, so the
    # admitted reviewer repeats arm A with it attached.
    if [ -z "$served_mmproj" ] || [ ! -f "$served_mmproj" ]; then
        # A five-arm run states five results, so the stage reports partial
        # rather than accepting a projector claim no arm measured.
        skip served_arm_projector no_mmproj
        if [ "$served_state" = accepted ]; then
            served_state=partial
            served_reason=projector_arm_not_run
        fi
    else
        arm_f_hold=${QWEN_LEASE_F_HOLD_S:-10}
        arm_f_wait=$((arm_f_hold + load_seconds + readiness_margin))
        printf 'served_arm=projector_load hold_s=%s wait_s=%s\n' "$arm_f_hold" "$arm_f_wait"
        if ! hold_lease "$arm_f_hold"; then
            served_state=refused
            fail 'projector_load the fixture owner never took the lease'
        else
            start_server "$arm_f_wait" --mmproj "$served_mmproj"
            arm_f_under_hold=$(poll_health "$((arm_f_hold - 2))")
            if [ "$arm_f_under_hold" = served ]; then
                served_state=refused
                fail 'projector_load the projector-bearing load served under a held lease'
                release_holder
            else
                release_holder
                arm_f_after=$(poll_health "$((load_seconds + readiness_margin))")
                if [ "$arm_f_after" = served ] && arm_waited_for_lease && answers; then
                    pass 'projector_load waited, loaded the projector, and answered'
                else
                    served_state=refused
                    fail "projector_load the release admitted no waiting projector-bearing load: $arm_f_after"
                fi
            fi
            stop_server
        fi
    fi
fi

if [ "$failures" -gt 0 ]; then
    printf 'load_lease_coverage=refused reach=%s served=%s failures=%s\n' \
        "$reach_state" "$served_state" "$failures"
    exit 1
fi

if [ "$reach_state" = accepted ] && [ "$served_state" = accepted ]; then
    printf 'load_lease_coverage=accepted reach=accepted served=accepted\n'
    exit 0
fi

# One stage passing states what it read and nothing about the other, so the
# terminal line carries both rather than promoting a partial run.
printf 'load_lease_coverage=partial reach=%s served=%s reach_reason=%s served_reason=%s\n' \
    "$reach_state" "$served_state" "${reach_reason:-none}" "${served_reason:-none}"
exit 0
