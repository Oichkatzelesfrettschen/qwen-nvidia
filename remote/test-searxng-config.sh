#!/bin/sh
set -eu

# Validates remote/searxng-settings.yml structurally, without SearXNG, a
# server, or root. PyYAML is the only optional dependency: its absence is
# reported as `not_run` on its own line rather than silently skipping the
# rest of the file, since a missing YAML parser is a fact about the host
# running the test, not a pass.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
settings_file=$script_directory/searxng-settings.yml

if [ ! -f "$settings_file" ]; then
    printf 'settings file missing: %s\n' "$settings_file" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 not found: not_run\n'
    exit 0
fi

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    printf 'PyYAML not installed: not_run\n'
    exit 0
fi

python3 - "$settings_file" <<'PYEOF'
import sys

import yaml

with open(sys.argv[1]) as handle:
    settings = yaml.safe_load(handle)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


check(settings.get("use_default_settings") is True, "use_default_settings must be true")

search = settings.get("search", {})
formats = search.get("formats", [])
check("json" in formats, "search.formats must include json")
check("html" in formats, "search.formats must include html")

server = settings.get("server", {})
check(server.get("bind_address") == "127.0.0.1", "server.bind_address must be 127.0.0.1")
check(server.get("port") == 8888, "server.port must be 8888")
check(server.get("limiter") is False, "server.limiter must be false")
check(server.get("public_instance") is False, "server.public_instance must be false")
check(server.get("image_proxy") is False, "server.image_proxy must be false")

outgoing = settings.get("outgoing", {})
check(outgoing.get("request_timeout") == 3.0, "outgoing.request_timeout must be 3.0")
check(outgoing.get("max_request_timeout") == 8.0, "outgoing.max_request_timeout must be 8.0")
check(outgoing.get("pool_connections") == 20, "outgoing.pool_connections must be 20")
check(outgoing.get("pool_maxsize") == 10, "outgoing.pool_maxsize must be 10")
check(outgoing.get("enable_http2") is True, "outgoing.enable_http2 must be true")
check(outgoing.get("retries") == 0, "outgoing.retries must be 0")

engines = settings.get("engines", [])
check(len(engines) == len({e["name"] for e in engines}), "engines: duplicate name")

qwen_categories = {
    "qwen-open": {"mwmbl", "wiby", "wikipedia", "wikidata"},
    "qwen-broad": {"google", "bing", "brave", "duckduckgo", "startpage", "qwant", "mojeek"},
    "qwen-academic": {"crossref", "arxiv", "pubmed", "wikipedia"},
    "qwen-news": {"reuters", "google news", "bing news", "brave.news"},
    "qwen-yacy": {"yacy"},
}

engines_by_name = {}
for engine in engines:
    name = engine["name"]
    engines_by_name.setdefault(name, []).append(engine)

for category, expected_names in qwen_categories.items():
    for name in expected_names:
        matches = engines_by_name.get(name)
        check(matches is not None, "engine missing from engines: block: %s" % name)
        if not matches:
            continue
        check(len(matches) == 1, "engine %s: not exactly one override block" % name)
        engine = matches[0]
        categories = engine.get("categories")
        check(categories is not None, "engine %s: no categories field" % name)
        if categories is not None:
            check(
                category in categories,
                "engine %s: category %s missing (has %s)" % (name, category, categories),
            )

yacy_engine = engines_by_name.get("yacy", [{}])[0]
check(yacy_engine.get("disabled") is False, "yacy: must be enabled inside qwen-yacy")
check(yacy_engine.get("categories") == ["qwen-yacy"], "yacy: must live in qwen-yacy alone")
check(yacy_engine.get("enable_http") is True, "yacy: enable_http must be true for the http-only local peer")
check(yacy_engine.get("search_mode") == "global", "yacy: search_mode must be global")
check(yacy_engine.get("search_type") == "text", "yacy: search_type must be text")
check(
    yacy_engine.get("base_url") == ["http://127.0.0.1:8090"],
    "yacy: base_url must be [http://127.0.0.1:8090]",
)

if failures:
    for failure in failures:
        print("FAIL: %s" % failure, file=sys.stderr)
    sys.exit(1)

print("PASS: %d engine overrides checked across %d qwen categories" %
      (sum(len(v) for v in qwen_categories.values()), len(qwen_categories)))
PYEOF
