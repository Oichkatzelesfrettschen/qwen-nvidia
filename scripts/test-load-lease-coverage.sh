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

    classify_open=$(classify_statement 'workload_lease_open()' \
        "$classify_start" "$classify_weights" "$classify_file")
    classify_acquire=$(classify_statement 'workload_lease_acquire()' \
        "$classify_start" "$classify_weights" "$classify_file")

    # workload_lease_acquire returns true while the descriptor is closed, so an
    # acquire ahead of its own open admits every load silently.
    if [ -n "$classify_open" ] && [ -n "$classify_acquire" ] &&
        [ "$classify_open" -lt "$classify_acquire" ]; then
        printf 'covered open=%s acquire=%s weights=%s\n' \
            "$classify_open" "$classify_acquire" "$classify_weights"
    else
        printf 'uncovered open=%s acquire=%s weights=%s\n' \
            "${classify_open:-absent}" "${classify_acquire:-absent}" "$classify_weights"
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
        if (!workload_lease_acquire()) { return false; }' ''
    self_test_write after-upload.cpp '' \
        '        if (!workload_lease_open()) { return false; }
        if (!workload_lease_acquire()) { return false; }'
    self_test_write comment-only.cpp \
        '        // workload_lease_acquire() would go here
        // workload_lease_open() would go here' ''
    self_test_write block-comment.cpp \
        '        /* workload_lease_open() and
           workload_lease_acquire() belong here */' ''
    self_test_write string-literal.cpp \
        '        SRV_INF("%s", "workload_lease_open() workload_lease_acquire()");' ''
    self_test_write acquire-before-open.cpp \
        '        if (!workload_lease_acquire()) { return false; }
        if (!workload_lease_open()) { return false; }' ''

    self_test_expect() {
        self_test_answer=$(classify_load_coverage "$self_test_root/$1")
        case $self_test_answer in
        "$2"*) pass "predicate_self_test $1=$2" ;;
        *) fail "predicate_self_test $1 expected=$2 read=$self_test_answer" ;;
        esac
    }

    self_test_expect covered.cpp covered
    self_test_expect after-upload.cpp uncovered
    self_test_expect comment-only.cpp uncovered
    self_test_expect block-comment.cpp uncovered
    self_test_expect string-literal.cpp uncovered
    self_test_expect acquire-before-open.cpp uncovered
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

            # The doctrine bounds the lease acquire on a deadline, because the
            # owner lock above it refuses at once and an unbounded wait below
            # turns a refusal into a stall. A blocking flock is the shape that
            # breaks it, so the check reads the call rather than a name.
            blocking_flock=$(grep -c '^[[:space:]]*[^/[:space:]].*flock([^)]*LOCK_EX)' \
                "$patched_file" || true)
            if [ "$blocking_flock" -eq 0 ]; then
                pass 'lease_wait_bounded no flock call blocks without LOCK_NB'
            else
                reach_state=refused
                fail "lease_wait_bounded=no blocking_flock_calls=$blocking_flock -- a load behind a generation stalls its request"
            fi
        fi
    fi
fi

# The served stage. A fixture owner holds the lease, the server is started
# against a model it has yet to load, and the load waits rather than
# allocating; the release then admits it and the model answers.
served_server=${QWEN_LEASE_TEST_SERVER:-}
served_model=${QWEN_LEASE_TEST_MODEL:-}
if [ -z "$served_server" ] || [ ! -x "$served_server" ]; then
    served_reason=no_patched_server
    skip served "$served_reason"
elif [ -z "$served_model" ] || [ ! -f "$served_model" ]; then
    served_reason=no_model
    skip served "$served_reason"
elif ! command -v setsid >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    served_reason=no_flock_or_setsid
    skip served "$served_reason"
else
    served_state=accepted
    lease_path=$temporary_directory/vulkan-workload.lock
    holder_state=$temporary_directory/holder-state
    : >"$lease_path"

    # The holder outlives the observation window by a wide margin, so an
    # absent health endpoint inside that window is read against a lease the
    # arm still holds rather than one that expired under it.
    hold_observe_seconds=${QWEN_LEASE_OBSERVE_S:-25}
    holder_seconds=$((hold_observe_seconds * 8 + 300))
    setsid sh -c 'exec 9>"$1"; flock -x 9; printf held >"$2"; sleep "$3"' \
        holder "$lease_path" "$holder_state" "$holder_seconds" &
    holder_group=$!

    waited=0
    while [ ! -s "$holder_state" ] && [ "$waited" -lt 100 ]; do
        waited=$((waited + 1))
        sleep 0.1
    done
    if [ ! -s "$holder_state" ]; then
        served_state=refused
        fail 'served the fixture owner never took the lease'
    else
        pass 'served fixture owner holds the lease'

        server_log=$temporary_directory/server.log
        QWEN_GPU_COMPUTE_LEASE=$lease_path \
        QWEN_VULKAN_WORKLOAD_LOCK=$lease_path \
        LLAMA_NO_CPU_FALLBACK=1 \
            "$served_server" --model "$served_model" \
            --host 127.0.0.1 --port "$serving_port" \
            --device CUDA0 -ot '.*=CUDA0' -ngl 99 \
            >"$server_log" 2>&1 &
        server_pid=$!

        # A load that waits for the lease reports no health inside the window a
        # load of this model needs without one, and the log states the wait.
        # The window is wall clock rather than an iteration count, because each
        # poll costs a curl timeout the count does not model.
        held_deadline=$(( $(date +%s) + hold_observe_seconds ))
        health_under_hold=absent
        while [ "$(date +%s)" -lt "$held_deadline" ]; do
            if ! kill -0 "$server_pid" 2>/dev/null; then
                health_under_hold=exited
                break
            fi
            if curl -fsS --max-time 2 \
                "http://127.0.0.1:$serving_port/health" >/dev/null 2>&1; then
                health_under_hold=served
                break
            fi
            sleep 0.2
        done

        # An observation drawn while the lease had already gone free measures
        # nothing about admission, so the hold is proved to have outlasted it.
        if flock -n "$lease_path" true 2>/dev/null; then
            served_state=refused
            fail 'served_load_admission the fixture lease went free inside the observation window'
            health_under_hold=lease_lost
        fi

        case $health_under_hold in
        served)
            served_state=refused
            fail 'served_load_admission the model loaded and served under a held lease'
            ;;
        lease_lost)
            ;;
        exited)
            # The patch logs `lease armed` before it loads anything, so a CUDA,
            # argument, or allocation failure after that line carries the word
            # too. Only a record of the acquire ending without the lease
            # distinguishes a refusal from an unrelated death.
            if grep -q 'workload lease wait ended without the lease\|workload lease failed\|workload lease deadline' \
                "$server_log"; then
                pass 'served_load_admission the load refused under a held lease and named the acquire'
            else
                served_state=refused
                fail "served_load_admission the server exited for another reason: $(tail -1 "$server_log" | tr -d '\n' | cut -c1-120)"
            fi
            ;;
        *)
            if grep -q 'workload lease waiting' "$server_log"; then
                pass 'served_load_admission the load waits and says so'
            else
                served_state=refused
                fail 'served_load_admission the load neither served, refused, nor logged a wait'
            fi
            ;;
        esac

        release_holder

        released_wait=0
        health_after_release=absent
        while [ "$released_wait" -lt 1200 ]; do
            if curl -fsS --max-time 2 \
                "http://127.0.0.1:$serving_port/health" >/dev/null 2>&1; then
                health_after_release=served
                break
            fi
            released_wait=$((released_wait + 1))
            sleep 0.1
        done

        if [ "$health_after_release" = served ]; then
            pass "served_load_after_release waited_ms=$((released_wait * 100))"
        else
            served_state=refused
            fail 'served_load_after_release the release admitted no load'
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
