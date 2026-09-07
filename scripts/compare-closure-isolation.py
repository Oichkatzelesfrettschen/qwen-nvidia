#!/usr/bin/env python3
"""Isolate what one source change reaches inside two build closures.

Two closures built from the same pin differ by whatever their source diffs
differ by, and a rate or behavior comparison between them attributes every
difference to that change. This reader establishes the attribution rather than
assuming it, over readings that answer different questions, and every reading
that cannot be completed lowers the verdict rather than being skipped.

The configuration reading holds every lever equal. scripts/build-llama-cuda.sh
folds each material CMake choice into build-configuration.tsv and digests the
whole record into the closure name, so two closures differing in one field are
a one-axis comparison and two closures differing in more are not.

The source reading binds each build to the tree it was built from. A build
directory names a source directory in its CMakeCache.txt, and that directory's
current contents are not necessarily the contents the build recorded, so the
reader recomputes `git diff --binary HEAD` over each tree and requires it to
equal the `source_diff_sha256` its build-configuration.tsv carries. Two builds
naming one source path cannot both match, which is what keeps a pair of
successive builds from reading as a comparison of two trees.

The reachability reading is what replaces a byte comparison of linked
artifacts. Ninja records every edge, so the transitive consumer closure of a
changed translation unit's object names the exact set of targets that change
can reach, and a device-path target inside that set is the refutation. Both
graphs are read and required to agree over the whole reached set. Order-only
and implicit inputs are followed as inputs, which over-approximates the closure
in the safe direction: the reading can name more consumers than exist, never
fewer. Syntax the parser does not evaluate -- an unexpanded variable reference
-- is counted rather than ignored, because an edge read as a literal is an edge
whose real endpoints went unread.

The device-code reading compares instructions rather than bytes. nvcc writes
__FILE__-derived strings into .nv.global.init, which is initialized device
global data rather than a strippable debug section, so two cubins built from
identical sources at different absolute paths differ in content while carrying
identical code. cuobjdump -sass prints the instruction stream without that
data, which is why the device claim is made over the disassembly and why a
linked-artifact byte comparison is reported as unavailable rather than as a
difference this reader cannot attribute. A disassembly is accepted only where
it carries functions, since a command that exits zero having printed nothing
otherwise digests to the empty string on both sides and agrees.

nvcc mangles an internal-linkage entity through a module identifier it derives
from the translation unit, `_INTERNAL_<hex>_<len>_<unit>`, so the same source
compiled at two paths yields symbols differing in that hex alone. Replacing
every identifier with one placeholder would merge two distinct identifiers into
one symbol and hide a real difference, so each hex is replaced by a digest of
the unit it names: distinct units keep distinct symbols, the width is
preserved so the mangled length prefix stays valid, and the reader requires
each side's hex-to-unit mapping to be injective in both directions, since two
identifiers naming one unit would share a placeholder, and both sides to name
the same units.

The verdict is three-valued, because a positive isolation claim requires
positive readings rather than the absence of a negative one. `held` needs every
differing source traced to an object, both graphs agreeing, no device target in
any consumer closure, a source tree matching the digest its build recorded, a
fully parsed graph, and a device reading that ran, carried functions, and
agreed. `refuted` names a reading that contradicts the isolation. Everything
else is `not_established`.
"""

import argparse
import collections
import hashlib
import os
import re
import subprocess
import sys

DEVICE_TARGET = re.compile(r"ggml|cuda|\.cu\.o$|cubin|fatbin", re.IGNORECASE)
MODULE_LENGTHED = re.compile(rb"_INTERNAL_([0-9a-f]{8})_([0-9]+)_")
MODULE_SHORT = re.compile(rb"_INTERNAL_([0-9a-f]{8})_")
SASS_FUNCTION = re.compile(rb"^\s*Function\s*:")
CUDA_LIBRARY = re.compile(r"^libggml-cuda\.so\.[0-9]+(?:\.[0-9]+)*$")
CMAKE_SOURCE_KEY = "CMAKE_HOME_DIRECTORY:INTERNAL="
# A reference surviving top-level binding expansion names a node this reader
# never resolves, so the edge carrying it is counted rather than followed.
NINJA_VARIABLE = re.compile(r"\$[A-Za-z{]")

HELD = "held"
REFUTED = "refuted"
NOT_ESTABLISHED = "not_established"
EXIT_STATUS = {HELD: 0, REFUTED: 1, NOT_ESTABLISHED: 4}

# git reads GIT_DIR, GIT_INDEX_FILE, and GIT_WORK_TREE from the environment
# whatever -C names, so a caller invoked from inside another git operation
# would route these reads into that operation's index.
GIT_ROUTING = ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_OBJECT_DIRECTORY")


def git_environment():
    environment = dict(os.environ)
    for name in GIT_ROUTING:
        environment.pop(name, None)
    return environment


def sanitize(value):
    """Retained rows carry no local absolute path, wherever it is rooted."""
    home = os.path.expanduser("~")
    if home and home != "/":
        value = value.replace(home, "$HOME")
    return re.sub(r"(?<![\w$])/(?:[\w.-]+/)*[\w.+-]+",
                  lambda match: "<abs>/" + os.path.basename(match.group(0)),
                  value)


def read_configuration(build_directory):
    path = os.path.join(build_directory, "build-configuration.tsv")
    record = {}
    with open(path) as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) == 2:
                record[fields[0]] = fields[1]
    if not record:
        raise SystemExit("build-configuration.tsv carries no fields: %s" % path)
    return record


def read_source_directory(build_directory):
    path = os.path.join(build_directory, "CMakeCache.txt")
    with open(path) as handle:
        for line in handle:
            if line.startswith(CMAKE_SOURCE_KEY):
                return line[len(CMAKE_SOURCE_KEY):].strip()
    raise SystemExit("CMakeCache.txt names no source directory: %s" % path)


def source_diff_digest(source_directory):
    """The digest build-llama-cuda.sh records, recomputed over the tree now."""
    completed = subprocess.run(
        ["git", "-C", source_directory, "diff", "--binary", "HEAD", "--"],
        capture_output=True, check=True, env=git_environment())
    return hashlib.sha256(completed.stdout).hexdigest()


def changed_paths(source_directory):
    """Every path the tree carries over its pin, read NUL-delimited.

    Porcelain quotes a pathname carrying a space or a control character, and a
    rename record names two paths, so the human-readable form drops files this
    inventory exists to find.
    """
    completed = subprocess.run(
        ["git", "-C", source_directory, "status", "--porcelain", "-z"],
        capture_output=True, check=True, env=git_environment())
    entries = completed.stdout.split(b"\0")
    paths = []
    index = 0
    while index < len(entries):
        entry = entries[index]
        index += 1
        if len(entry) < 4:
            continue
        status, path = entry[:2], entry[3:]
        paths.append(os.fsdecode(path))
        if status[0:1] in (b"R", b"C") or status[1:2] in (b"R", b"C"):
            if index < len(entries) and entries[index]:
                paths.append(os.fsdecode(entries[index]))
                index += 1
    return paths


def digest_file(path):
    if not os.path.isfile(path):
        return "absent"
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def differing_sources(control_source, subject_source):
    """The tracked paths whose bytes differ between the two trees."""
    union = sorted(set(changed_paths(control_source)) |
                   set(changed_paths(subject_source)))
    differing = []
    for relative in union:
        control = digest_file(os.path.join(control_source, relative))
        subject = digest_file(os.path.join(subject_source, relative))
        if control != subject:
            differing.append((relative, control, subject))
    return differing


def unescape(token):
    return token.replace("$:", ":").replace("$ ", " ").replace("$$", "$")


def split_edge(text):
    """Split a ninja edge on unescaped whitespace, honoring `$ `."""
    tokens, current, index = [], [], 0
    while index < len(text):
        character = text[index]
        if character == "$" and index + 1 < len(text):
            current.append(text[index:index + 2])
            index += 2
            continue
        if character.isspace():
            if current:
                tokens.append("".join(current))
                current = []
            index += 1
            continue
        current.append(character)
        index += 1
    if current:
        tokens.append("".join(current))
    return tokens


BINDING = re.compile(r"^([A-Za-z0-9_.-]+)\s*=\s*(.*)$")


def expand(token, bindings):
    """Substitute top-level bindings, which is what CMake's paths reference."""
    for _ in range(8):
        replaced = re.sub(r"\$\{([A-Za-z0-9_.-]+)\}|\$([A-Za-z0-9_.-]+)",
                          lambda match: bindings.get(
                              match.group(1) or match.group(2), match.group(0)),
                          token)
        if replaced == token:
            return token
        token = replaced
    return token


def read_consumers(ninja_path):
    """input -> outputs over every build edge, with unevaluated edges counted."""
    consumers = collections.defaultdict(set)
    unevaluated = 0
    with open(ninja_path) as handle:
        joined, pending = [], ""
        for line in handle:
            line = line.rstrip("\n")
            if line.endswith("$") and not line.endswith("$$"):
                pending += line[:-1]
                continue
            joined.append(pending + line)
            pending = ""
        if pending:
            joined.append(pending)
    bindings = {}
    for line in joined:
        if line.startswith((" ", "\t")) or not line or line.startswith("#"):
            continue
        match = BINDING.match(line)
        if match:
            bindings[match.group(1)] = match.group(2).strip()
    for line in joined:
        if not line.startswith("build "):
            continue
        body = line[len("build "):]
        separator = -1
        index = 0
        while index < len(body):
            if body[index] == "$":
                index += 2
                continue
            if body[index] == ":":
                separator = index
                break
            index += 1
        if separator < 0:
            continue
        output_tokens = [expand(token, bindings)
                         for token in split_edge(body[:separator])]
        input_tokens = [expand(token, bindings)
                        for token in split_edge(body[separator + 1:])[1:]]
        edge_tokens = output_tokens + input_tokens
        if any(NINJA_VARIABLE.search(token) for token in edge_tokens):
            unevaluated += 1
        output_names = [unescape(token) for token in output_tokens
                        if token != "|"]
        input_names = [unescape(token) for token in input_tokens
                       if token not in ("|", "||")]
        for name in input_names:
            for output in output_names:
                consumers[name].add(output)
    return consumers, unevaluated


def transitive_consumers(consumers, seed):
    reached, frontier = set(), [seed]
    while frontier:
        node = frontier.pop()
        for consumer in consumers.get(node, ()):
            if consumer not in reached:
                reached.add(consumer)
                frontier.append(consumer)
    return reached


def objects_for(consumers, name):
    """Every compiled object ninja derives from one source path."""
    return sorted(output for output in consumers.get(name, ())
                  if output.endswith(".o"))


def resolve_objects(consumers, source_directory, relative_source):
    """Ninja names an input by absolute or by relative path, so union both."""
    absolute = os.path.join(source_directory, relative_source)
    found = set(objects_for(consumers, absolute))
    found.update(objects_for(consumers, relative_source))
    return sorted(found)


def cuda_library(build_directory):
    binary_directory = os.path.join(build_directory, "bin")
    if not os.path.isdir(binary_directory):
        return None
    found = None
    for name in sorted(os.listdir(binary_directory)):
        candidate = os.path.join(binary_directory, name)
        if CUDA_LIBRARY.match(name) and not os.path.islink(candidate):
            found = candidate
    return found


def module_units(line):
    """Each module identifier paired with the translation unit it names.

    The mangling spells the unit as a decimal length followed by that many
    characters, so reading the length is what separates the unit from the
    function name that follows it; keying on the whole tail instead would give
    one identifier several units and read as a collision.
    """
    for match in MODULE_LENGTHED.finditer(line):
        length = int(match.group(2))
        unit = line[match.end():match.end() + length]
        if len(unit) == length:
            yield match.group(1), unit


def module_placeholder(unit):
    """A width-preserving stand-in that keeps distinct units distinct."""
    return hashlib.sha256(unit).hexdigest()[:8].encode()


def device_code_digest(build_directory, cuobjdump):
    """The disassembly digest, its coverage, and its module identifiers."""
    reading = {"digest": "absent", "library": "no CUDA backend library",
               "lines": 0, "functions": 0, "identifiers": {}, "unmapped": 0}
    library = cuda_library(build_directory)
    if library is None:
        return reading
    reading["library"] = sanitize(library)
    try:
        process = subprocess.Popen([cuobjdump, "-sass", library],
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
    except OSError:
        reading["digest"] = "unavailable"
        return reading
    body = []
    for line in process.stdout:
        reading["lines"] += 1
        if SASS_FUNCTION.search(line):
            reading["functions"] += 1
        for identifier, unit in module_units(line):
            reading["identifiers"].setdefault(identifier, set()).add(unit)
        body.append(line)
    process.stdout.close()
    if process.wait() != 0:
        reading["digest"] = "unavailable"
        return reading
    if reading["functions"] == 0:
        reading["digest"] = "unavailable"
        return reading
    mapping = {}
    for identifier, units in reading["identifiers"].items():
        if len(units) == 1:
            mapping[identifier] = module_placeholder(sorted(units)[0])
    digest = hashlib.sha256()
    for line in body:
        def replace(match):
            identifier = match.group(1)
            if identifier in mapping:
                return b"_INTERNAL_" + mapping[identifier] + b"_"
            reading["unmapped"] += 1
            return b"_INTERNAL_UNMAPPED_"
        digest.update(MODULE_SHORT.sub(replace, line))
    reading["digest"] = digest.hexdigest()
    return reading


def write_rows(path, header, rows):
    with open(path, "w") as handle:
        handle.write("\t".join(header) + "\n")
        for row in rows:
            handle.write("\t".join(sanitize(str(field)) for field in row) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("control_build")
    parser.add_argument("subject_build")
    parser.add_argument("--out", required=True)
    parser.add_argument("--cuobjdump", default="cuobjdump")
    parser.add_argument("--skip-device-code", action="store_true",
                        help="omit the SASS reading, which costs minutes")
    arguments = parser.parse_args()

    os.makedirs(arguments.out, exist_ok=True)
    builds = {"control": arguments.control_build, "subject": arguments.subject_build}
    configuration = {name: read_configuration(path) for name, path in builds.items()}

    fields = sorted(set(configuration["control"]) | set(configuration["subject"]))
    delta = [(field, configuration["control"].get(field, "absent"),
              configuration["subject"].get(field, "absent"))
             for field in fields
             if configuration["control"].get(field) != configuration["subject"].get(field)]
    write_rows(os.path.join(arguments.out, "configuration-delta.tsv"),
               ("field", "control", "subject"), delta)
    print("configuration_axes=%d" % len(delta))
    for field, control_value, subject_value in delta:
        print("configuration_delta field=%s control=%s subject=%s"
              % (field, control_value, subject_value))
    if len(delta) != 1 or delta[0][0] != "source_diff_sha256":
        print("comparison_refused reason=configuration_axes_not_source_alone")
        return EXIT_STATUS[REFUTED]

    sources = {name: read_source_directory(path) for name, path in builds.items()}
    print("source_paths_equal=%s"
          % ("yes" if sources["control"] == sources["subject"] else "no"))

    # A build directory names a source path; the tree at that path now is not
    # necessarily the tree the build recorded, so bind the two before reading.
    bound = 0
    for name in ("control", "subject"):
        recorded = configuration[name].get("source_diff_sha256", "absent")
        observed = source_diff_digest(sources[name])
        matched = recorded == observed
        bound += 1 if matched else 0
        print("source_binding closure=%s recorded=%s observed=%s match=%s"
              % (name, recorded[:12], observed[:12], "yes" if matched else "no"))

    differing = differing_sources(sources["control"], sources["subject"])
    write_rows(os.path.join(arguments.out, "source-delta.tsv"),
               ("path", "control_sha256", "subject_sha256"), differing)
    print("differing_sources=%d" % len(differing))

    graphs = {}
    unevaluated_total = 0
    for name in ("control", "subject"):
        consumers, unevaluated = read_consumers(
            os.path.join(builds[name], "build.ninja"))
        graphs[name] = consumers
        unevaluated_total += unevaluated
        print("graph closure=%s edges_unevaluated=%d" % (name, unevaluated))

    reachability = []
    device_reached = 0
    untraced = 0
    disagreeing = 0
    for relative, _, _ in differing:
        reached_sets = {}
        for name in ("control", "subject"):
            objects = resolve_objects(graphs[name], sources[name], relative)
            if not objects:
                untraced += 1
                reachability.append((name, relative, "none", 0, 0, "no_object"))
                reached_sets[name] = None
                continue
            whole = set()
            for object_name in objects:
                reached = transitive_consumers(graphs[name], object_name)
                whole.update(reached)
                device = sorted(node for node in reached
                                if DEVICE_TARGET.search(node))
                device_reached += len(device)
                artifacts = sorted(node for node in reached
                                   if node.startswith("bin/"))
                reachability.append((name, relative, object_name, len(reached),
                                     len(device), ",".join(artifacts) or "none"))
            reached_sets[name] = whole
        if reached_sets.get("control") != reached_sets.get("subject"):
            disagreeing += 1
    write_rows(os.path.join(arguments.out, "reachability.tsv"),
               ("closure", "source", "object", "transitive_consumers",
                "device_targets", "artifacts"), reachability)
    for row in reachability:
        print("reachability closure=%s source=%s object=%s consumers=%s "
              "device_targets=%s artifacts=%s" % row)
    print("device_targets_reached=%d" % device_reached)
    print("untraced_sources=%d" % untraced)
    print("graph_disagreements=%d" % disagreeing)

    if arguments.skip_device_code:
        print("device_code=not_run reason=skip_requested")
        device_verdict = "not_run"
    else:
        readings = {name: device_code_digest(builds[name], arguments.cuobjdump)
                    for name in ("control", "subject")}
        write_rows(os.path.join(arguments.out, "device-code.tsv"),
                   ("closure", "sass_sha256", "sass_lines", "sass_functions",
                    "module_identifiers", "unmapped_identifiers", "library"),
                   tuple((name, readings[name]["digest"], readings[name]["lines"],
                          readings[name]["functions"],
                          len(readings[name]["identifiers"]),
                          readings[name]["unmapped"], readings[name]["library"])
                         for name in ("control", "subject")))
        units = {name: {unit for units in readings[name]["identifiers"].values()
                        for unit in units} for name in ("control", "subject")}
        injective = True
        for name in ("control", "subject"):
            claimed = collections.Counter()
            for units_of in readings[name]["identifiers"].values():
                if len(units_of) != 1:
                    injective = False
                    continue
                claimed[sorted(units_of)[0]] += 1
            if any(count > 1 for count in claimed.values()):
                injective = False
        unmapped = sum(readings[name]["unmapped"] for name in readings)
        print("module_identifiers control=%d subject=%d units_match=%s "
              "injective=%s unmapped=%d"
              % (len(readings["control"]["identifiers"]),
                 len(readings["subject"]["identifiers"]),
                 "yes" if units["control"] == units["subject"] else "no",
                 "yes" if injective else "no", unmapped))
        print("device_code_coverage control_lines=%d control_functions=%d "
              "subject_lines=%d subject_functions=%d"
              % (readings["control"]["lines"], readings["control"]["functions"],
                 readings["subject"]["lines"], readings["subject"]["functions"]))
        digests = {readings[name]["digest"] for name in readings}
        if digests & {"absent", "unavailable"}:
            device_verdict = "unavailable"
        elif len(digests) > 1:
            device_verdict = "differs"
        elif not injective or unmapped or units["control"] != units["subject"]:
            device_verdict = "unresolved_identifiers"
        else:
            device_verdict = "identical"
        print("device_code=%s control=%s subject=%s"
              % (device_verdict, readings["control"]["digest"][:12],
                 readings["subject"]["digest"][:12]))

    if device_reached or device_verdict == "differs":
        verdict = REFUTED
    elif (untraced or disagreeing or unevaluated_total or bound != 2
            or device_verdict != "identical"):
        verdict = NOT_ESTABLISHED
    else:
        verdict = HELD
    print("device_path_isolation=%s" % verdict)
    if sources["control"] != sources["subject"]:
        print("artifact_byte_comparison=unavailable reason=build_paths_differ")
    return EXIT_STATUS[verdict]


if __name__ == "__main__":
    sys.exit(main())
