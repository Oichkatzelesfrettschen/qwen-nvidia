#!/bin/sh
set -eu

# Hold verify-nvidia-sdk.sh and fetch-nvidia-sdk.sh to fixture ledgers. A
# fake pacman answers the package queries and fixture prefixes carry the
# version header and shared objects the verifier reads, so the cases run on
# any clone: an installed pair is accepted, a package at another version is
# refused, an absent package is refused unless QWEN_SDK_VERIFY_ALLOW_ABSENT=1,
# a malformed digest or a non-https source is refused, and the fetcher refuses
# a candidate row, refuses an archive whose bytes hash to something else, and
# accepts one whose bytes hash to the pin.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
failures=0
report() {
    if [ "$1" = 0 ]; then printf 'ok %s\n' "$2"; else printf 'FAIL %s\n' "$2"; failures=$((failures + 1)); fi
}

cvcuda_prefix=$temporary_directory/cvcuda
nvimgcodec_prefix=$temporary_directory/nvimgcodec
mkdir -p "$cvcuda_prefix/lib" "$cvcuda_prefix/include/cvcuda" "$nvimgcodec_prefix/lib" "$nvimgcodec_prefix/include"
: >"$cvcuda_prefix/lib/libcvcuda.so.0.17.0"
: >"$cvcuda_prefix/include/cvcuda/Version.h"
: >"$nvimgcodec_prefix/lib/libnvimgcodec.so.0.9.0"
printf '#define NVIMGCODEC_VER_MAJOR 0\n#define NVIMGCODEC_VER_MINOR 9\n#define NVIMGCODEC_VER_PATCH 0\n' \
    >"$nvimgcodec_prefix/include/nvimgcodec_version.h"

archive=$temporary_directory/nvimgcodec-0.9.0.20-archive.tar.xz
printf 'fixture archive bytes\n' >"$archive"
archive_sha256=$(sha256sum "$archive" | cut -d ' ' -f 1)
zero_digest=0000000000000000000000000000000000000000000000000000000000000000

write_ledger() {
    # write_ledger FILE CVCUDA_VERSION NVIMGCODEC_STATUS DIGEST SOURCE
    printf '# id\tvendor\tcomponent\tversion\tcuda_major\tarch\tartifact_name\tsource_url\tsha256\tinstall_prefix\tpackage\tstatus\n' >"$1"
    printf 'cvcuda-lib\tNVIDIA\tCV-CUDA\t%s\t13\tx86_64\tcvcuda-lib-%s.tar.xz\thttps://example.invalid/cvcuda\t%s\t%s\tcvcuda-bin\tpinned\n' \
        "$2" "$2" "$zero_digest" "$cvcuda_prefix" >>"$1"
    printf 'nvimgcodec\tNVIDIA\tnvImageCodec\t0.9.0.20\t13\tx86_64\tnvimgcodec-0.9.0.20-archive.tar.xz\t%s\t%s\t%s\tnvimgcodec-bin\t%s\n' \
        "$5" "$4" "$nvimgcodec_prefix" "$3" >>"$1"
}

fake_pacman=$temporary_directory/pacman
cat >"$fake_pacman" <<'FAKE'
#!/bin/sh
case $2 in
    cvcuda-bin) printf 'cvcuda-bin %s\n' "${FAKE_CVCUDA_VERSION:-0.17.0-1}" ;;
    nvimgcodec-bin) [ "${FAKE_NVIMGCODEC_ABSENT:-0}" = 1 ] && exit 1; printf 'nvimgcodec-bin 0.9.0.20-1\n' ;;
    *) exit 1 ;;
esac
FAKE
chmod +x "$fake_pacman"
verify() { QWEN_SDK_VERIFY_PACMAN=$fake_pacman "$script_directory/verify-nvidia-sdk.sh" "$@"; }

ledger=$temporary_directory/ledger.tsv
write_ledger "$ledger" 0.17.0 pinned "$archive_sha256" "https://example.invalid/nvimgcodec"
verify "$ledger" >"$temporary_directory/out" 2>&1 && report 0 "an installed pair is accepted" || report 1 "an installed pair is accepted"
grep -q 'nvidia_sdk_verify=accepted rows=2' "$temporary_directory/out" && report 0 "the summary counts both rows" || report 1 "the summary counts both rows"

FAKE_CVCUDA_VERSION=0.16.0-1 verify "$ledger" >"$temporary_directory/out" 2>&1 && report 1 "a package at another version is refused" || report 0 "a package at another version is refused"
grep -q 'is at 0.16.0-1 rather than 0.17.0' "$temporary_directory/out" && report 0 "the refusal names both versions" || report 1 "the refusal names both versions"

FAKE_NVIMGCODEC_ABSENT=1 verify "$ledger" >"$temporary_directory/out" 2>&1 && report 1 "an absent package is refused" || report 0 "an absent package is refused"
FAKE_NVIMGCODEC_ABSENT=1 QWEN_SDK_VERIFY_ALLOW_ABSENT=1 verify "$ledger" >"$temporary_directory/out" 2>&1 && report 0 "an absent package is reported under the allowance" || report 1 "an absent package is reported under the allowance"
grep -q 'nvidia_sdk=absent id=nvimgcodec' "$temporary_directory/out" && report 0 "the allowance names the absent row" || report 1 "the allowance names the absent row"

printf '#define NVIMGCODEC_VER_MAJOR 0\n#define NVIMGCODEC_VER_MINOR 8\n#define NVIMGCODEC_VER_PATCH 0\n' >"$nvimgcodec_prefix/include/nvimgcodec_version.h"
verify "$ledger" >"$temporary_directory/out" 2>&1 && report 1 "a version header disagreeing with the row is refused" || report 0 "a version header disagreeing with the row is refused"
printf '#define NVIMGCODEC_VER_MAJOR 0\n#define NVIMGCODEC_VER_MINOR 9\n#define NVIMGCODEC_VER_PATCH 0\n' >"$nvimgcodec_prefix/include/nvimgcodec_version.h"

write_ledger "$temporary_directory/bad-digest.tsv" 0.17.0 pinned deadbeef "https://example.invalid/nvimgcodec"
verify "$temporary_directory/bad-digest.tsv" >"$temporary_directory/out" 2>&1 && report 1 "a malformed digest is refused" || report 0 "a malformed digest is refused"
write_ledger "$temporary_directory/http.tsv" 0.17.0 pinned "$archive_sha256" "http://example.invalid/a"
verify "$temporary_directory/http.tsv" >"$temporary_directory/out" 2>&1 && report 1 "a source outside https is refused" || report 0 "a source outside https is refused"

fetch() { "$script_directory/fetch-nvidia-sdk.sh" "$@"; }
fetch_ledger=$temporary_directory/fetch.tsv
write_ledger "$fetch_ledger" 0.17.0 pinned "$archive_sha256" "file://$archive"
fetcher=$temporary_directory/fetcher
mkdir -p "$fetcher"
cp "$script_directory/fetch-nvidia-sdk.sh" "$fetcher/"
cp "$fetch_ledger" "$fetcher/nvidia-sdk-artifacts.tsv"
"$fetcher/fetch-nvidia-sdk.sh" nvimgcodec "$temporary_directory/dest" >"$temporary_directory/out" 2>&1 && report 0 "the fetcher accepts bytes hashing to the pin" || report 1 "the fetcher accepts bytes hashing to the pin"
grep -q 'nvidia_sdk_fetch=verified' "$temporary_directory/out" && report 0 "the fetch is reported verified" || report 1 "the fetch is reported verified"
"$fetcher/fetch-nvidia-sdk.sh" nvimgcodec "$temporary_directory/dest" >"$temporary_directory/out" 2>&1 && grep -q 'nvidia_sdk_fetch=present' "$temporary_directory/out" && report 0 "a present archive at the pin is left alone" || report 1 "a present archive at the pin is left alone"
write_ledger "$fetcher/nvidia-sdk-artifacts.tsv" 0.17.0 pinned "$zero_digest" "file://$archive"
"$fetcher/fetch-nvidia-sdk.sh" nvimgcodec "$temporary_directory/dest2" >"$temporary_directory/out" 2>&1 && report 1 "the fetcher refuses bytes hashing elsewhere" || report 0 "the fetcher refuses bytes hashing elsewhere"
[ ! -e "$temporary_directory/dest2/nvimgcodec-0.9.0.20-archive.tar.xz" ] && report 0 "a refused fetch leaves no archive at the pinned name" || report 1 "a refused fetch leaves no archive at the pinned name"
write_ledger "$fetcher/nvidia-sdk-artifacts.tsv" 0.17.0 candidate "$archive_sha256" "file://$archive"
"$fetcher/fetch-nvidia-sdk.sh" nvimgcodec "$temporary_directory/dest3" >"$temporary_directory/out" 2>&1 && report 1 "the fetcher refuses a candidate row" || report 0 "the fetcher refuses a candidate row"

if [ "$failures" -ne 0 ]; then
    printf 'verify_nvidia_sdk=rejected failures=%s\n' "$failures" >&2
    exit 1
fi
printf 'verify_nvidia_sdk=accepted\n'
