#!/bin/sh
set -eu

# summarize-dispatch-census.py joins one arm's census.tsv rows to its
# requests.tsv windows, reads each row's phase from its own src0 name and
# ne11, and folds a graph_replay row into graph_replays rather than
# dispatch_launches. This fixture writes two synthetic arm directories under
# a temporary output directory -- one carrying a full census and requests
# pair, one carrying census.tsv alone -- and runs the real summarizer over
# them, so every join, phase, and aggregation rule is read from its own
# TSV output rather than from the source that computed it.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
summarizer=$script_directory/summarize-dispatch-census.py
work_directory=$(mktemp -d)
trap 'rm -rf -- "$work_directory"' EXIT HUP INT TERM

output_directory=$work_directory/output
arm_directory=$output_directory/T0-fake-text
empty_arm_directory=$output_directory/T1-no-requests
mkdir -p "$arm_directory" "$empty_arm_directory"

# requests.tsv: r1 is a text request with no "image" in its label, r2 is an
# image request. Windows do not overlap, so a row outside both joins
# "outside" rather than the nearer one.
printf 'request_id\tlabel\tt_start_ns\tt_end_ns\tstatus\tprompt_n\tpredicted_n\tprompt_ms\tpredicted_ms\tcontent_chars\n' \
    >"$arm_directory/requests.tsv"
printf 'r1\ttext-prefill\t100\t200\tok\t512\t64\t10.0\t20.0\t100\n' \
    >>"$arm_directory/requests.tsv"
printf 'r2\tcold-image\t300\t400\tok\t113\t32\t80.0\t25.0\t70\n' \
    >>"$arm_directory/requests.tsv"

# census.tsv carries the header write_header() in
# patches/llama-cuda-dispatch-census.patch emits: graph_index, t_ns, mode,
# n_nodes, op, path, detail, src0_name, dst_name, src0_type, src1_type,
# dst_type, ne00..ne13, nb01..nb13, the three contiguity flags, batch_count,
# launches.
census_file=$arm_directory/census.tsv
printf 'graph_index\tt_ns\tmode\tn_nodes\top\tpath\tdetail\tsrc0_name\tdst_name\tsrc0_type\tsrc1_type\tdst_type\tne00\tne01\tne02\tne03\tne10\tne11\tne12\tne13\tnb01\tnb02\tnb03\tnb11\tnb12\tnb13\tsrc0_contiguous\tsrc1_contiguous\tsrc0_transposed\tbatch_count\tlaunches\n' \
    >"$census_file"

row() {
    # graph_index t_ns mode n_nodes op path detail src0_name dst_name
    # src0_type src1_type dst_type ne00 ne01 ne02 ne03 ne10 ne11 ne12 ne13
    # nb01 nb02 nb03 nb11 nb12 nb13 c0 c1 transposed batch_count launches
    printf '%s\n' "$*" | tr ' ' '\t' >>"$census_file"
}

# Row A and row B: two distinct MMVQ shapes inside r1's window (t_ns 150 and
# 160), both ne11=512 in a request whose label carries no "image", so both
# read text_prefill and aggregate under the one (request, phase, path, detail,
# types, mode) key -- dispatch_launches sums their launch counts (3 + 2 = 5)
# and distinct_shapes counts the two distinct (name, ne00, ...) tuples.
row 0 150 eager 10 MUL_MAT MMVQ - blk.0.ffn_down.weight node_1 q6_K f32 f32 4608 1024 1 1 4608 512 1 1 0 0 0 0 0 0 1 1 0 1 3
row 0 160 eager 10 MUL_MAT MMVQ - blk.0.ffn_up.weight   node_2 q6_K f32 f32 6144 1024 1 1 6144 512 1 1 0 0 0 0 0 0 1 1 0 1 2

# Row C: the same MMVQ/text_prefill shape at t_ns=999, outside both request
# windows, so it joins request_id "outside" rather than r1.
row 0 999 eager 10 MUL_MAT MMVQ - blk.0.attn_v.weight node_3 q6_K f32 f32 4608 1024 1 1 4608 512 1 1 0 0 0 0 0 0 1 1 0 1 5

# Row D: a v.* src0 name reads vision_encoder regardless of ne11 or label.
row 0 150 eager 10 MUL_MAT MMQ - v.blk.0.attn_q.weight node_4 q4_K f32 f32 1024 1024 1 1 1024 4 1 1 0 0 0 0 0 0 1 1 0 1 1

# Row E: an mm.* src0 name reads projector.
row 0 150 eager 10 MUL_MAT MMF - mm.1.weight node_5 f16 f32 f32 768 768 1 1 768 4 1 1 0 0 0 0 0 0 1 1 0 1 1

# Row F: ne11=1 inside r2, whose label carries "image", reads
# post_image_decode.
row 0 350 eager 10 MUL_MAT MMVF - blk.5.attn_output.weight node_6 q4_K f32 f32 1024 1024 1 1 1024 1 1 1 0 0 0 0 0 0 1 1 0 1 1

# Row G: ne11=8 (above one) inside the same image request reads
# llm_prefill_from_image_embeddings rather than text_prefill.
row 0 360 eager 10 MUL_MAT MMQ - blk.5.ffn_down.weight node_7 q4_K f32 f32 4608 1024 1 1 4608 8 1 1 0 0 0 0 0 0 1 1 0 1 1

# Row H: a graph_replay row inside r1's window. A replay dispatches nothing
# through the hooks, so its launches (4) fold into graph_replays and never
# into dispatch_launches.
row 1 155 replay 10 - graph_replay - - - - - - - - - - - - - - - - - - - - - - - - 4

# Rows I and J: two distinct cuBLAS shapes inside r1's window, so the arm's
# cublas_share reads launches on the cuBLAS path over every dispatch launch
# and cublas_distinct_shapes counts the two shapes.
row 2 150 eager 10 MUL_MAT cuBLAS cublasGemmEx/F16 blk.0.attn_output.weight node_8 f16 f32 f32 768 352 1 1 768 768 1 1 0 0 0 0 0 0 1 1 0 1 1
row 2 160 eager 10 MUL_MAT cuBLAS cublasGemmEx/F16 blk.1.attn_output.weight node_9 f16 f32 f32 512 352 1 1 512 768 1 1 0 0 0 0 0 0 1 1 0 1 1

# The second arm carries a census.tsv with no requests.tsv beside it, which
# summarize_arm() must skip rather than raise on.
printf 'graph_index\tt_ns\tmode\tn_nodes\top\tpath\tdetail\tsrc0_name\tdst_name\tsrc0_type\tsrc1_type\tdst_type\tne00\tne01\tne02\tne03\tne10\tne11\tne12\tne13\tnb01\tnb02\tnb03\tnb11\tnb12\tnb13\tsrc0_contiguous\tsrc1_contiguous\tsrc0_transposed\tbatch_count\tlaunches\n' \
    >"$empty_arm_directory/census.tsv"
printf '0\t150\teager\t10\tMUL_MAT\tMMVQ\t-\tblk.0.ffn_down.weight\tnode_1\tq6_K\tf32\tf32\t4608\t1024\t1\t1\t4608\t512\t1\t1\t0\t0\t0\t0\t0\t0\t1\t1\t0\t1\t1\n' \
    >>"$empty_arm_directory/census.tsv"

failures=0
report() {
    printf 'check=%s outcome=%s\n' "$1" "$2"
    [ "$2" = pass ] || failures=$((failures + 1))
}

set +e
python3 "$summarizer" "$output_directory" >"$work_directory/summarizer.out" 2>"$work_directory/summarizer.err"
summarizer_status=$?
set -e
if [ "$summarizer_status" -eq 0 ]; then
    report summarizer_runs_clean pass
else
    report summarizer_runs_clean fail
    cat "$work_directory/summarizer.err" >&2
fi

# write_tsv() names its line terminator, so every generated file is LF-only,
# ends on exactly one LF, and carries the header's field count on every row.
# The summarizer is then run a second time over the same records into a
# second directory, and the two outputs have to agree row for row after
# newline normalization, which is what proves the writer owns the format
# rather than a post-pass repairing it.
phases=$arm_directory/phases.tsv
summary=$output_directory/census-summary.tsv
run_wide_cublas=$output_directory/cublas-shapes.tsv
format_failures=0
for generated in "$phases" "$summary" "$run_wide_cublas" "$arm_directory/cublas-shapes.tsv"; do
    if grep -q "$(printf '\r')" "$generated"; then
        printf 'carriage return in %s\n' "$generated" >&2
        format_failures=$((format_failures + 1))
    fi
    if [ "$(tail -c1 "$generated" | od -An -c | tr -d ' ')" != '\n' ] ||
        [ "$(tail -c2 "$generated" | od -An -c | tr -d ' ')" = '\n\n' ]; then
        printf 'file does not end on exactly one LF: %s\n' "$generated" >&2
        format_failures=$((format_failures + 1))
    fi
    if ! awk -F'\t' 'NR == 1 { n = NF } NF != n { exit 1 }' "$generated"; then
        printf 'row field count differs from the header: %s\n' "$generated" >&2
        format_failures=$((format_failures + 1))
    fi
done
if [ "$format_failures" -eq 0 ]; then
    report generated_files_are_lf_only_and_rectangular pass
else
    report generated_files_are_lf_only_and_rectangular fail
fi

second_output=$work_directory/output-2
mkdir -p "$second_output/T0-fake-text"
cp "$arm_directory/census.tsv" "$arm_directory/requests.tsv" "$second_output/T0-fake-text/"
python3 "$summarizer" "$second_output" >/dev/null 2>&1
normalized() { tr -d '\r' <"$1" >"$work_directory/normalized-$2"; }
normalized "$phases" a1; normalized "$second_output/T0-fake-text/phases.tsv" b1
normalized "$summary" a2; normalized "$second_output/census-summary.tsv" b2
normalized "$run_wide_cublas" a3; normalized "$second_output/cublas-shapes.tsv" b3
if cmp -s "$work_directory/normalized-a1" "$work_directory/normalized-b1" &&
    cmp -s "$work_directory/normalized-a2" "$work_directory/normalized-b2" &&
    cmp -s "$work_directory/normalized-a3" "$work_directory/normalized-b3"; then
    report regeneration_reproduces_rows pass
else
    report regeneration_reproduces_rows fail
fi

phase_row() {
    # phase_row REQUEST PHASE PATH -- prints the one matching phases.tsv row,
    # or nothing.
    awk -F'\t' -v request="$1" -v phase="$2" -v path="$3" \
        'NR==1{next} $2==request && $4==phase && $5==path {print; found=1}
         END{exit !found}' "$phases"
}

if [ -n "$(phase_row r1 text_prefill MMVQ)" ]; then
    report request_join_inside_window pass
else
    report request_join_inside_window fail
fi

if [ -n "$(phase_row outside text_prefill MMVQ)" ]; then
    report request_join_outside_window pass
else
    report request_join_outside_window fail
fi

if [ -n "$(phase_row r1 vision_encoder MMQ)" ]; then
    report phase_vision_encoder pass
else
    report phase_vision_encoder fail
fi

if [ -n "$(phase_row r1 projector MMF)" ]; then
    report phase_projector pass
else
    report phase_projector fail
fi

if [ -n "$(phase_row r2 post_image_decode MMVF)" ]; then
    report phase_post_image_decode pass
else
    report phase_post_image_decode fail
fi

if [ -n "$(phase_row r2 llm_prefill_from_image_embeddings MMQ)" ]; then
    report phase_llm_prefill_from_image_embeddings pass
else
    report phase_llm_prefill_from_image_embeddings fail
fi

replay_row=$(phase_row r1 graph_replay graph_replay)
if [ -n "$replay_row" ] &&
   [ "$(printf '%s\n' "$replay_row" | awk -F'\t' '{print $13}')" = 0 ] &&
   [ "$(printf '%s\n' "$replay_row" | awk -F'\t' '{print $14}')" = 4 ]; then
    report graph_replay_excluded_from_dispatch_launches pass
else
    report graph_replay_excluded_from_dispatch_launches fail
fi

shape_row=$(phase_row r1 text_prefill MMVQ)
if [ "$(printf '%s\n' "$shape_row" | awk -F'\t' '{print $12}')" = 2 ] &&
   [ "$(printf '%s\n' "$shape_row" | awk -F'\t' '{print $13}')" = 5 ]; then
    report distinct_shapes_aggregate_dispatch_launches pass
else
    report distinct_shapes_aggregate_dispatch_launches fail
fi

# dispatch_launches over the arm: row A(3) + row B(2) + row D(1) + row E(1)
# + row F(1) + row G(1) + row I(1) + row J(1) = 11, of which cuBLAS carries
# rows I and J (2), so cublas_share is 2/11 = 0.1818 to four decimals.
summary_row=$(awk -F'\t' -v arm="T0-fake-text" '$1==arm' "$summary")
if [ "$(printf '%s\n' "$summary_row" | awk -F'\t' '{print $2}')" = 11 ] &&
   [ "$(printf '%s\n' "$summary_row" | awk -F'\t' '{print $7}')" = 2 ] &&
   [ "$(printf '%s\n' "$summary_row" | awk -F'\t' '{print $8}')" = 0.1818 ]; then
    report cublas_share_four_decimals pass
else
    report cublas_share_four_decimals fail
fi

if [ "$(printf '%s\n' "$summary_row" | awk -F'\t' '{print $9}')" = 2 ]; then
    report cublas_distinct_shapes_counted pass
else
    report cublas_distinct_shapes_counted fail
fi

if [ "$(printf '%s\n' "$summary_row" | awk -F'\t' '{print $10}')" = 4 ]; then
    report graph_replays_totalled_in_summary pass
else
    report graph_replays_totalled_in_summary fail
fi

if awk -F'\t' '$1=="T1-no-requests"' "$summary" | grep -q . ; then
    report arm_without_requests_skipped fail
else
    report arm_without_requests_skipped pass
fi

if [ -f "$empty_arm_directory/phases.tsv" ]; then
    report arm_without_requests_wrote_no_phases fail
else
    report arm_without_requests_wrote_no_phases pass
fi

header=$(head -n1 "$run_wide_cublas")
if [ "$(printf '%s\n' "$header" | awk -F'\t' '{print $1}')" = arm ] &&
   [ "$(printf '%s\n' "$header" | awk -F'\t' '{print $4}')" = phase ]; then
    report run_wide_cublas_arm_and_phase_first pass
else
    report run_wide_cublas_arm_and_phase_first fail
fi

cublas_data_rows=$(awk -F'\t' 'NR>1' "$run_wide_cublas" | wc -l)
if [ "$cublas_data_rows" = 2 ]; then
    report run_wide_cublas_carries_every_row pass
else
    report run_wide_cublas_carries_every_row fail
fi

if [ "$failures" -eq 0 ]; then
    printf 'dispatch_census_summary=accepted checks=%s\n' 16
else
    printf 'dispatch_census_summary=rejected failures=%s\n' "$failures" >&2
    exit 1
fi
