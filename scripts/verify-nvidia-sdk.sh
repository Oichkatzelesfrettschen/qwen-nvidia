#!/bin/sh
set -eu

# Verify that every pinned row of scripts/nvidia-sdk-artifacts.tsv is
# installed on this host as the ledger states: the package the row names is
# installed at the row's version through pacman, the install prefix exists and
# holds the component's shared object, and the version header the archive
# ships agrees with the row. The archive digest itself is verified by the
# PKGBUILD at build time and by fetch-nvidia-sdk.sh at fetch time; this
# script reads what those left on disk. A row whose package is absent is
# reported rather than fatal when QWEN_SDK_VERIFY_ALLOW_ABSENT=1, so a clone
# without the SDKs can still validate the ledger's shape.

usage() {
    printf 'usage: %s [LEDGER]\n' "$0" >&2
    exit 2
}
[ "$#" -le 1 ] || usage
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ledger=${1:-$script_directory/nvidia-sdk-artifacts.tsv}
[ -r "$ledger" ] || { printf 'ledger is not readable: %s\n' "$ledger" >&2; exit 2; }
allow_absent=${QWEN_SDK_VERIFY_ALLOW_ABSENT:-0}
pacman_command=${QWEN_SDK_VERIFY_PACMAN:-pacman}

failures=0
rows=0
while IFS='	' read -r id vendor component version cuda_major arch artifact_name source_url sha256 install_prefix package status; do
    case $id in
        '#'*|'') continue ;;
    esac
    rows=$((rows + 1))
    for pair in "id=$id" "vendor=$vendor" "component=$component" "version=$version" \
        "cuda_major=$cuda_major" "arch=$arch" "artifact_name=$artifact_name" \
        "source_url=$source_url" "sha256=$sha256" "install_prefix=$install_prefix" \
        "package=$package" "status=$status"; do
        [ -n "${pair#*=}" ] || { printf 'row %s leaves %s empty\n' "$id" "${pair%%=*}" >&2; failures=$((failures + 1)); }
    done
    case $sha256 in *[!0-9a-f]*) printf 'row %s digest is not hex\n' "$id" >&2; failures=$((failures + 1)) ;; esac
    [ "${#sha256}" -eq 64 ] || { printf 'row %s digest is not 64 hex\n' "$id" >&2; failures=$((failures + 1)); }
    case $source_url in https://*) ;; *) printf 'row %s source is not https\n' "$id" >&2; failures=$((failures + 1)) ;; esac
    case $status in pinned|candidate|retired) ;; *) printf 'row %s status %s is unknown\n' "$id" "$status" >&2; failures=$((failures + 1)) ;; esac
    case $artifact_name in *"$version"*) ;; *) printf 'row %s artifact name does not carry version %s\n' "$id" "$version" >&2; failures=$((failures + 1)) ;; esac
    [ "$status" = pinned ] || continue
    installed=$("$pacman_command" -Q "$package" 2>/dev/null | cut -d ' ' -f 2 || :)
    if [ -z "$installed" ]; then
        if [ "$allow_absent" = 1 ]; then
            printf 'nvidia_sdk=absent id=%s package=%s\n' "$id" "$package"
            continue
        fi
        printf 'row %s: package %s is not installed\n' "$id" "$package" >&2
        failures=$((failures + 1))
        continue
    fi
    case $installed in "$version"-*) ;; *)
        printf 'row %s: package %s is at %s rather than %s\n' "$id" "$package" "$installed" "$version" >&2
        failures=$((failures + 1)) ;;
    esac
    [ -d "$install_prefix" ] || { printf 'row %s: prefix %s is absent\n' "$id" "$install_prefix" >&2; failures=$((failures + 1)); continue; }
    case $component in
        CV-CUDA)
            [ -e "$install_prefix/lib/libcvcuda.so.$version" ] || { printf 'row %s: libcvcuda.so.%s is absent\n' "$id" "$version" >&2; failures=$((failures + 1)); }
            [ -e "$install_prefix/include/cvcuda/Version.h" ] || { printf 'row %s: cvcuda/Version.h is absent\n' "$id" >&2; failures=$((failures + 1)); }
            ;;
        nvImageCodec)
            short=${version%.*}
            [ -e "$install_prefix/lib/libnvimgcodec.so.$short" ] || { printf 'row %s: libnvimgcodec.so.%s is absent\n' "$id" "$short" >&2; failures=$((failures + 1)); }
            header=$install_prefix/include/nvimgcodec_version.h
            if [ -r "$header" ]; then
                major=$(sed -n 's/^#define NVIMGCODEC_VER_MAJOR \([0-9]*\).*/\1/p' "$header")
                minor=$(sed -n 's/^#define NVIMGCODEC_VER_MINOR \([0-9]*\).*/\1/p' "$header")
                patch=$(sed -n 's/^#define NVIMGCODEC_VER_PATCH \([0-9]*\).*/\1/p' "$header")
                [ "$major.$minor.$patch" = "$short" ] || { printf 'row %s: header states %s.%s.%s rather than %s\n' "$id" "$major" "$minor" "$patch" "$short" >&2; failures=$((failures + 1)); }
            else
                printf 'row %s: nvimgcodec_version.h is absent\n' "$id" >&2; failures=$((failures + 1))
            fi
            ;;
    esac
    printf 'nvidia_sdk=installed id=%s package=%s-%s prefix=%s\n' "$id" "$package" "$installed" "$install_prefix"
done <"$ledger"
[ "$rows" -gt 0 ] || { printf 'the ledger holds no row\n' >&2; exit 1; }
if [ "$failures" -ne 0 ]; then
    printf 'nvidia_sdk_verify=rejected failures=%s\n' "$failures" >&2
    exit 1
fi
printf 'nvidia_sdk_verify=accepted rows=%s\n' "$rows"
