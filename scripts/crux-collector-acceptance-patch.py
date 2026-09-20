"""Apply the crux collector's acceptance correction to a copied graft tree.

collectFileCrux computes the next attempt from the map it just filled, so a
record stored on its id alone retires itself from the retry and is then
discarded by the `!r.summary.trim()` test in applyFileCrux. Storing a record
only when it carries that summary makes one rule govern both the retry and the
graph. The stock text must be present verbatim: a graft whose collector has
moved is reported rather than patched by approximation.
"""

import pathlib
import sys

STOCK = """            for (const r of list)
                if (!results.has(r.id))
                    results.set(r.id, r);"""

FIXED = """            for (const r of list)
                if (r && typeof r.summary === "string" && r.summary.trim() && !results.has(r.id))
                    results.set(r.id, r);"""


def main(path):
    enrich = pathlib.Path(path)
    text = enrich.read_text(encoding="utf-8")
    if FIXED in text:
        return 0
    if STOCK not in text:
        sys.stderr.write("collectFileCrux does not carry the stock predicate\n")
        return 1
    enrich.write_text(text.replace(STOCK, FIXED, 1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
