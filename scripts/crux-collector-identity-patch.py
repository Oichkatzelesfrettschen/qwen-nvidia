"""Resolve an echoed crux id back to the target it names.

The crux request lists each target as `- id=<id> | <kind> | lines L<a>-L<b>`
and instructs the model to return that id verbatim. A model can read the whole
line as the id and answer with `<id> | <kind> | lines L<a>-L<b>`, whose leading
field is the id it was asked for. collectFileCrux matches on equality, so every
such record misses its target, the retry set never shrinks, and correct
summaries are discarded for their punctuation.

Resolving the leading field against the requested ids recovers the record. An
id that resolves to no target is left exactly as it arrived, so the collector
still loses what the model genuinely invented and this changes no other
outcome.
"""

import pathlib
import sys

ANCHOR = """async function collectFileCrux(summarizer, path, source, refs) {
    const results = new Map();
    let missing = refs;
    let error;
    for (let attempt = 0; attempt < 2 && missing.length > 0; attempt++) {
        try {
            const list = await summarizer.describeFile({ path, source, nodes: missing });
            for (const r of list)
                if (!results.has(r.id))
                    results.set(r.id, r);"""

RESOLVED = """async function collectFileCrux(summarizer, path, source, refs) {
    const results = new Map();
    // The request formats a target as `id | kind | lines L1-L9 | signature` and
    // asks for the id verbatim, so a model can answer with the whole line. Its
    // leading field is the id; resolving it against the requested set recovers
    // a record that carries a summary and would otherwise miss every target.
    const requestedIds = new Set(refs.map((r) => r.id));
    const resolveId = (id) => {
        if (typeof id !== "string" || requestedIds.has(id))
            return id;
        const head = id.split(" | ")[0].trim();
        return requestedIds.has(head) ? head : id;
    };
    let missing = refs;
    let error;
    for (let attempt = 0; attempt < 2 && missing.length > 0; attempt++) {
        try {
            const list = await summarizer.describeFile({ path, source, nodes: missing });
            for (const r of list) {
                const id = resolveId(r.id);
                if (!results.has(id))
                    results.set(id, id === r.id ? r : { ...r, id });
            }"""


def main(path):
    enrich = pathlib.Path(path)
    text = enrich.read_text(encoding="utf-8")
    if "resolveId" in text:
        return 0
    if ANCHOR not in text:
        sys.stderr.write("collectFileCrux does not carry the stock text\n")
        return 1
    enrich.write_text(text.replace(ANCHOR, RESOLVED, 1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
