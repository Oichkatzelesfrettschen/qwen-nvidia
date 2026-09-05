#!/bin/sh
set -eu

# Where a client's image is decoded, where its pixels land, and what a
# CV-CUDA resize changes against the projector's own preprocessing, per
# encoded format, on this device. Compiles scripts/media-decode-probe/
# media-placement.cpp against the SDK prefixes scripts/nvidia-sdk-artifacts.tsv
# names and the promoted llama.cpp closure's libmtmd, writes the encoded
# fixtures, and runs the probe once per vision row under the GPU ownership
# lock: every fixture under five nvImageCodec backend policies with the debug
# messenger retained, every decode compared byte for byte against the
# stb_image decode the served path performs, and the projector's preprocessor
# from libmtmd as the reference four CV-CUDA resizes are held to. A second
# pass runs each policy alone under Nsight Systems with the preprocessing
# off, and scripts/read-nsys-embd-transfers.py lists every memory copy of the
# capture against the encoded and decoded byte counts, so the transfer a
# CPU-backed decode makes to reach a device target is read from the driver
# rather than declared.
#
# The probe proves placement and equivalence and serves nothing: the served
# path is unchanged by this script, and the record is what a device-side
# media input stage is designed against.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY [MODEL_ID...]\n' "$0" >&2
    printf '  MODEL_ID defaults to qwen35-2b lfm25-vl-450m; each needs a projector beside its file\n' >&2
    printf '  QWEN_LLAMA_BUILD names the closure build directory holding libmtmd (default: the promoted row)\n' >&2
    printf '  QWEN_LLAMA_SOURCE names the pinned llama.cpp source tree (default: $HOME/src/llama.cpp-qwen-nvidia)\n' >&2
    exit 2
}
[ "$#" -ge 1 ] || usage
output_directory=$1
shift
model_ids=${*:-"qwen35-2b lfm25-vl-450m"}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
host_cxx=${QWEN_HOST_COMPILER:-/usr/bin/g++-15}
cuda_prefix=${QWEN_CUDA_PREFIX:-/opt/cuda}
source_directory=${QWEN_LLAMA_SOURCE:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
models_directory=${QWEN_MODELS_DIR:-"${HOME:?}/models"}
nsys_binary=${QWEN_MEDIA_NSYS:-nsys}
profiler_wrapper=$script_directory/exec-profiler-clean-env.sh
registry_script=$script_directory/model-registry.sh

if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    printf 'refused: output directory exists and is not empty: %s\n' "$output_directory" >&2
    exit 2
fi
mkdir -p "$output_directory/fixtures" "$output_directory/nsys"
# the run directory is named by nsys in its own report line, and the home
# prefix by every loader line, so both leave every retained text
scrub_home() { sed -e "s|$output_directory|OUT|g" -e "s|${HOME:?}|\$HOME|g"; }
summary=$output_directory/summary.tsv
record() { printf '%s\t%s\n' "$1" "$2" >>"$summary"; }
: >"$summary"

if [ -z "${QWEN_LLAMA_BUILD:-}" ]; then
    promoted_digest=$(awk -F '\t' '!/^#/ && $1 == "promoted" { print $2 }' "$script_directory/serving-closures.tsv")
    [ -n "$promoted_digest" ] || { printf 'serving-closures.tsv names no promoted closure\n' >&2; exit 1; }
    build_directory=$source_directory/build-qwen-cuda-$promoted_digest
else
    build_directory=$QWEN_LLAMA_BUILD
fi
[ -f "$build_directory/bin/libmtmd.so" ] || {
    printf 'refused: no libmtmd.so under %s\n' "$build_directory/bin" >&2
    exit 1
}
command -v "$nsys_binary" >/dev/null 2>&1 || { printf 'refused: nsys is absent: %s\n' "$nsys_binary" >&2; exit 1; }

"$script_directory/verify-nvidia-sdk.sh" | tee "$output_directory/sdk-verify.txt"
prefix_of() {
    awk -F '\t' -v id="$1" '!/^#/ && $1 == id { print $10 }' "$script_directory/nvidia-sdk-artifacts.tsv"
}
cvcuda_prefix=$(prefix_of cvcuda-lib)
nvimgcodec_prefix=$(prefix_of nvimgcodec)

probe=$output_directory/media-placement
"$host_cxx" -std=c++17 -O2 -o "$probe" \
    "$script_directory/media-decode-probe/media-placement.cpp" \
    -I"$cuda_prefix/include" -I"$nvimgcodec_prefix/include" -I"$cvcuda_prefix/include" \
    -I"$source_directory/tools/mtmd" -I"$source_directory/ggml/include" -I"$source_directory/include" \
    -I"$source_directory/vendor" \
    -L"$cuda_prefix/lib64" -L"$nvimgcodec_prefix/lib" -L"$cvcuda_prefix/lib" -L"$build_directory/bin" \
    -Wl,-rpath,"$build_directory/bin" -Wl,-rpath,"$nvimgcodec_prefix/lib" -Wl,-rpath,"$cvcuda_prefix/lib" \
    -lnvimgcodec -lcvcuda -lnvcv_types -lcudart -lmtmd -lllama -lggml -lggml-base 2>&1 | scrub_home | tee "$output_directory/compile.txt"
[ -x "$probe" ] || { printf 'the probe did not compile\n' >&2; exit 1; }
record compiler "$("$host_cxx" -dumpfullversion)"
record build_directory "$(printf '%s' "$build_directory" | scrub_home)"
record libmtmd_sha256 "$(sha256sum "$build_directory/bin/libmtmd.so" | cut -d ' ' -f 1)"

# The fixtures: the graded PNG drawings, the served photograph, one large
# drawing, and the encoded variants of the bars drawing.
for image in bars.png shapes.png page.png zebra.jpg; do
    cp "$script_directory/quality-images/$image" "$output_directory/fixtures/$image"
done
cp "$script_directory/handoff-images/bars-large.png" "$output_directory/fixtures/bars-large.png"
python3 "$script_directory/media-decode-probe/make-fixtures.py" "$output_directory/fixtures" >/dev/null
fixture_list=""
for path in "$output_directory"/fixtures/*; do
    record "fixture:$(basename "$path")" "$(sha256sum "$path" | cut -d ' ' -f 1)"
    fixture_list="$fixture_list $path"
done

. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership.txt.raw"
sed -E -e 's|^(cuda_client) pid=[0-9]+ name=([^ ]+).* used=([0-9]+ MiB) .* verdict=(.*)$|\1 name=\2 used=\3 verdict=\4|' \
    -e 's|name=[^ ]*/([^ /]+)|name=\1|' -e 's|^(named_llama_server_pids)=.*$|\1=redacted|' \
    <"$output_directory/ownership.txt.raw" | scrub_home >"$output_directory/ownership.txt"
rm -f "$output_directory/ownership.txt.raw"
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv"

status=0
first_projector=""
for model_id in $model_ids; do
    model_file=$("$registry_script" id "$model_id" model_file)
    model_path=$models_directory/$model_file
    projector_path=$("$script_directory/select-projector.sh" "$model_path" || :)
    [ -n "$projector_path" ] && [ -f "$projector_path" ] || {
        printf 'refused: no projector beside %s\n' "$model_path" >&2
        record "verdict:$model_id" "refused projector_absent"
        status=1
        continue
    }
    [ -n "$first_projector" ] || first_projector=$projector_path
    model_directory=$output_directory/$model_id
    mkdir -p "$model_directory"
    record "projector:$model_id" "$(sha256sum "$projector_path" | cut -d ' ' -f 1)"
    probe_status=0
    # shellcheck disable=SC2086
    QWEN_NVIMGCODEC_EXTENSIONS="$nvimgcodec_prefix/extensions" \
        "$probe" --mmproj "$projector_path" --extensions "$nvimgcodec_prefix/extensions" \
        --messages "$model_directory/messages.tsv" $fixture_list \
        >"$model_directory/placement.tsv" 2>"$model_directory/probe.log" 9>&- || probe_status=$?
    for text in placement.tsv probe.log messages.tsv; do
        scrub_home <"$model_directory/$text" >"$model_directory/$text.scrubbed" && mv "$model_directory/$text.scrubbed" "$model_directory/$text"
    done
    record "probe_exit:$model_id" "$probe_status"
    [ "$probe_status" -eq 0 ] || status=1
done

# The transfer pass: each policy alone under Nsight Systems, decode only,
# against the first projector, since the decode arms read the projector for
# nothing beyond the clip_init the probe requires.
if [ -n "$first_projector" ]; then
    first_model=${model_ids%% *}
    sizes=$(awk -F '\t' '$1 == "decode" || $1 == "reference_decode" {
        for (i = 2; i <= NF; i++) if ($i ~ /^(decoded_bytes|encoded_bytes)=/) { split($i, kv, "="); print kv[2] }
    }' "$output_directory/$first_model/placement.tsv" | sort -un | paste -sd , -)
    record transfer_sizes "$sizes"
    for policy in any gpu hw hybrid cpu; do
        capture_directory=$output_directory/nsys/$policy
        mkdir -p "$capture_directory"
        capture_status=0
        # shellcheck disable=SC2086
        "$profiler_wrapper" "$nsys_binary" profile --trace=cuda --sample=none --cpuctxsw=none \
            --output "$capture_directory/profile" --force-overwrite=true \
            "$probe" --mmproj "$first_projector" --extensions "$nvimgcodec_prefix/extensions" \
            --policy "$policy" --no-preproc $fixture_list \
            >"$capture_directory/probe.txt" 2>&1 9>&- || capture_status=$?
        scrub_home <"$capture_directory/probe.txt" >"$capture_directory/probe.scrubbed" && mv "$capture_directory/probe.scrubbed" "$capture_directory/probe.txt"
        record "capture_exit:$policy" "$capture_status"
        if [ -f "$capture_directory/profile.nsys-rep" ]; then
            "$nsys_binary" export --type sqlite --force-overwrite true \
                --output "$capture_directory/profile.sqlite" "$capture_directory/profile.nsys-rep" \
                >"$capture_directory/nsys-export.txt" 2>&1 || status=1
            scrub_home <"$capture_directory/nsys-export.txt" >"$capture_directory/nsys-export.scrubbed" && mv "$capture_directory/nsys-export.scrubbed" "$capture_directory/nsys-export.txt"
            record "capture_sha256:$policy" "$(sha256sum "$capture_directory/profile.sqlite" | cut -d ' ' -f 1)"
            # a policy every decoder refused opens no device work, so its
            # capture holds no copy table; the summarizer reads that against
            # the decode rows rather than this script deciding it
            reader_status=0
            python3 "$script_directory/read-nsys-embd-transfers.py" "$capture_directory/profile.sqlite" \
                --sizes "$sizes" --min-bytes 4096 --out "$capture_directory/transfers.tsv" \
                >"$capture_directory/transfers-summary.txt" 2>&1 || reader_status=$?
            record "transfer_reader_exit:$policy" "$reader_status"
            # neither Nsight form is admitted into the tree; the copy table and the digest stay
            rm -f "$capture_directory/profile.nsys-rep" "$capture_directory/profile.sqlite"
        else
            status=1
        fi
    done
fi
rm -f "$probe"

python3 "$script_directory/summarize-media-decode-placement.py" "$output_directory" >"$output_directory/verdict.txt" 2>&1 || status=1
cat "$output_directory/verdict.txt"
record exit "$status"
exit "$status"
