#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    printf 'usage: %s REQUEST_JSON [STATE_DIRECTORY [TIMEOUT_SECONDS]]\n' "$0" >&2
    exit 2
fi

request_path=$1
state_directory=${2:-"${HOME:?}/qwen-webui-state"}
timeout_seconds=${3:-600}
api_key_file=$state_directory/api.key
response_path=$state_directory/real-response.json
metrics_path=$state_directory/real-request.metrics

case $timeout_seconds in
    '' | *[!0-9]*)
        printf 'timeout must be a positive integer\n' >&2
        exit 2
        ;;
esac
if [ "$timeout_seconds" -eq 0 ]; then
    printf 'timeout must be a positive integer\n' >&2
    exit 2
fi
if [ ! -s "$request_path" ] || [ ! -s "$api_key_file" ]; then
    printf 'request and API key files must be non-empty\n' >&2
    exit 1
fi

umask 077
start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_epoch=$(date +%s)
set +e
http_metrics=$(curl --fail --silent --show-error \
    --max-time "$timeout_seconds" \
    --output "$response_path" \
    --write-out 'http_code=%{http_code}\nwall_seconds=%{time_total}\n' \
    --header "Authorization: Bearer $(sed -n '1p' "$api_key_file")" \
    --header 'Content-Type: application/json' \
    --data-binary "@$request_path" \
    http://127.0.0.1:8080/v1/chat/completions)
curl_status=$?
set -e
end_epoch=$(date +%s)
end_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

{
    printf 'start_utc=%s\n' "$start_utc"
    printf 'end_utc=%s\n' "$end_utc"
    printf 'elapsed_integer_seconds=%s\n' "$((end_epoch - start_epoch))"
    printf 'curl_status=%s\n' "$curl_status"
    printf '%s' "$http_metrics"
} >"$metrics_path"

if [ "$curl_status" -ne 0 ]; then
    exit "$curl_status"
fi
