"""Instrument a copied graft tree to record each crux attempt's identities.

collectFileCrux decides the second attempt from the ids it accepted, and enrich
decides the graph from the summaries those records carry, so a record lost
between them is lost to one of three causes: an id that never came back, an id
returned in a form no target matches, or a summary that arrived blank. The deep
log distinguishes none of them, and no reply body is retained anywhere. This
writes one JSON object per attempt to the path in GRAFT_CRUX_TRACE, naming the
ids requested, parsed, summarized, accepted and still missing.

The trace observes and changes no acceptance rule, so a traced run takes the
path an untraced run takes. Each insertion anchors on a line the collector
corrections leave alone, so a tree can carry a correction and this trace at
once and the trace reports what that collector did.
"""

import pathlib
import sys

HELPER_ANCHOR = "async function collectFileCrux(summarizer, path, source, refs) {"
HELPER = """async function traceCruxAttempt(record) {
    const target = process.env.GRAFT_CRUX_TRACE;
    if (!target)
        return;
    const { appendFileSync } = await import("node:fs");
    appendFileSync(target, `${JSON.stringify(record)}\\n`);
}
"""

REQUESTED_ANCHOR = \
    "            const list = await summarizer.describeFile({ path, source, nodes: missing });"
REQUESTED = """            const requested = missing;
            const list = await summarizer.describeFile({ path, source, nodes: missing });"""

TRACE_ANCHOR = "            missing = refs.filter((r) => !results.has(r.id));"
TRACE = """            missing = refs.filter((r) => !results.has(r.id));
            await traceCruxAttempt({
                path,
                attempt,
                requested: requested.map((r) => r.id),
                parsed: list.map((r) => r.id),
                summarized: list.filter((r) => r.summary && r.summary.trim()).map((r) => r.id),
                accepted: [...results.keys()],
                missing: missing.map((r) => r.id),
                miss: summarizer.lastMiss ? summarizer.lastMiss.kind : null,
                finish_reason: summarizer.lastMiss ? summarizer.lastMiss.finishReason : null,
            });"""

INSERTIONS = (
    (HELPER_ANCHOR, HELPER + HELPER_ANCHOR),
    (REQUESTED_ANCHOR, REQUESTED),
    (TRACE_ANCHOR, TRACE),
)


def main(path):
    enrich = pathlib.Path(path)
    text = enrich.read_text(encoding="utf-8")
    if "traceCruxAttempt" in text:
        return 0
    for anchor, replacement in INSERTIONS:
        if text.count(anchor) != 1:
            sys.stderr.write("collectFileCrux does not carry %r exactly once\n" % anchor)
            return 1
        text = text.replace(anchor, replacement, 1)
    enrich.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
