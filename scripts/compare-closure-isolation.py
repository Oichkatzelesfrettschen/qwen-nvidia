#!/usr/bin/env python3
"""Isolate what one source change reaches inside two build closures.

Two closures built from the same pin differ by whatever their source diffs
differ by, and a rate or behavior comparison between them attributes every
difference to that change. This reader establishes the attribution rather than
assuming it, over three readings that answer different questions.

The configuration reading holds every lever equal. scripts/build-llama-cuda.sh
folds each material CMake choice into build-configuration.tsv and digests the
whole record into the closure name, so two closures differing in one field are
a one-axis comparison and two closures differing in more are not. A second
differing lever ends the run, because a comparison whose axes are unseparated
answers no question either lever asked.

The reachability reading is what replaces a byte comparison of linked
artifacts. Ninja records every edge, so the transitive consumer closure of a
changed translation unit's object names the exact set of targets that change
can reach, and a device-path target inside that set is the refutation the
caller is looking for. Both graphs are read and required to agree, since one
closure's graph states what that closure links rather than what its companion
does. The reading is structural, so it holds whatever the absolute build paths
are.

The device-code reading compares instructions rather than bytes. nvcc writes
__FILE__-derived strings into .nv.global.init, which is initialized device
global data rather than a strippable debug section, so two cubins built from
identical sources at different absolute paths differ in content while carrying
identical code. cuobjdump -sass prints the instruction stream without that
data, which is why the device claim is made over the disassembly and why a
linked-artifact byte comparison is reported as unavailable rather than as a
difference this reader cannot attribute.

One path-derived token survives into the disassembly. nvcc mangles an
internal-linkage entity through a module identifier it derives from the
translation unit, which appears in the symbol as _INTERNAL_<hex>_<len>_<unit>,
so the same source compiled at two paths yields two symbols differing in that
hex alone. MODULE_IDENTIFIER replaces it with a fixed token of the same width,
which keeps the mangled length prefix valid, and the reader reports how many
distinct identifiers it normalized on each side so a reading that silently
erased a real difference is visible as a count rather than hidden in a digest.

The verdict is three-valued, because a positive isolation claim requires two
positive readings rather than the absence of a negative one. `held` needs every
differing source traced to an object, no device target in any consumer closure,
and a device-code reading that ran and agreed. `refuted` names a reading that
contradicts the isolation. `not_established` covers the rest: a device reading
that did not run or could not run, a differing source ninja traces to no
object, and two graphs that disagree. A run that never read the device payload
therefore states that it did not, rather than reporting isolation.
"""

import argparse
import collections
import hashlib
import os
import re
import subprocess
import sys

DEVICE_TARGET = re.compile(r"ggml|cuda|\.cu\.o$|cubin|fatbin", re.IGNORECASE)
MODULE_IDENTIFIER = re.compile(rb"_INTERNAL_[0-9a-f]{8}_")
MODULE_PLACEHOLDER = b"_INTERNAL_XXXXXXXX_"
CUDA_LIBRARY = re.compile(r"^libggml-cuda\.so\.[0-9]+(?:\.[0-9]+)*$")
CMAKE_SOURCE_KEY = "CMAKE_HOME_DIRECTORY:INTERNAL="

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
    """Retained rows carry no local absolute path."""
    home = os.path.expanduser("~")
    return value.replace(home, "$HOME") if home and home != "/" else value


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


def changed_paths(source_directory):
    """Every path the tree carries over its pin, as porcelain reports them."""
    completed = subprocess.run(
        ["git", "-C", source_directory, "status", "--porcelain"],
        capture_output=True, text=True, check=True, env=git_environment())
    return [line[3:].strip() for line in completed.stdout.splitlines()
            if len(line) > 3]


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


def read_consumers(ninja_path):
    """input -> outputs, over every build edge ninja records."""
    consumers = collections.defaultdict(set)
    with open(ninja_path) as handle:
        for line in handle:
            if not line.startswith("build "):
                continue
            body = line[len("build "):].rstrip("\n")
            if ":" not in body:
                continue
            outputs, remainder = body.split(":", 1)
            output_names = outputs.replace("|", " ").split()
            input_names = [name for name in remainder.split()[1:]
                           if name not in ("|", "||")]
            for name in input_names:
                for output in output_names:
                    consumers[name].add(output)
    return consumers


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
    """The compiled objects ninja derives from one source path."""
    direct = sorted(output for output in consumers.get(name, ())
                    if output.endswith(".o"))
    if direct:
        return direct
    suffix = os.path.basename(name) + ".o"
    return sorted({output for outputs in consumers.values()
                   for output in outputs if output.endswith(suffix)})


def resolve_objects(consumers, source_directory, relative_source):
    """Ninja names its inputs by absolute path where the source is out of tree."""
    absolute = os.path.join(source_directory, relative_source)
    return objects_for(consumers, absolute) or objects_for(consumers, relative_source)


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


def device_code_digest(build_directory, cuobjdump):
    library = cuda_library(build_directory)
    if library is None:
        return "absent", "no CUDA backend library", 0
    try:
        process = subprocess.Popen([cuobjdump, "-sass", library],
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
    except OSError:
        return "unavailable", sanitize(library), 0
    digest = hashlib.sha256()
    identifiers = set()
    for line in process.stdout:
        identifiers.update(MODULE_IDENTIFIER.findall(line))
        digest.update(MODULE_IDENTIFIER.sub(MODULE_PLACEHOLDER, line))
    process.stdout.close()
    if process.wait() != 0:
        return "unavailable", sanitize(library), len(identifiers)
    return digest.hexdigest(), sanitize(library), len(identifiers)


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
    control = read_configuration(arguments.control_build)
    subject = read_configuration(arguments.subject_build)

    fields = sorted(set(control) | set(subject))
    delta = [(field, control.get(field, "absent"), subject.get(field, "absent"))
             for field in fields
             if control.get(field) != subject.get(field)]
    write_rows(os.path.join(arguments.out, "configuration-delta.tsv"),
               ("field", "control", "subject"), delta)
    print("configuration_axes=%d" % len(delta))
    for field, control_value, subject_value in delta:
        print("configuration_delta field=%s control=%s subject=%s"
              % (field, control_value, subject_value))
    if len(delta) != 1 or delta[0][0] != "source_diff_sha256":
        print("comparison_refused reason=configuration_axes_not_source_alone")
        return EXIT_STATUS[REFUTED]

    control_source = read_source_directory(arguments.control_build)
    subject_source = read_source_directory(arguments.subject_build)
    print("build_paths_equal=%s"
          % ("yes" if control_source == subject_source else "no"))

    differing = differing_sources(control_source, subject_source)
    write_rows(os.path.join(arguments.out, "source-delta.tsv"),
               ("path", "control_sha256", "subject_sha256"), differing)
    print("differing_sources=%d" % len(differing))

    graphs = {
        "control": (read_consumers(os.path.join(arguments.control_build,
                                                "build.ninja")), control_source),
        "subject": (read_consumers(os.path.join(arguments.subject_build,
                                                "build.ninja")), subject_source),
    }
    reachability = []
    device_reached = 0
    untraced = 0
    disagreeing = 0
    for relative, _, _ in differing:
        artifact_sets = {}
        for closure, (consumers, source) in graphs.items():
            objects = resolve_objects(consumers, source, relative)
            if not objects:
                untraced += 1
                reachability.append((closure, relative, "none", 0, 0, "no_object"))
                artifact_sets[closure] = None
                continue
            artifacts = set()
            for object_name in objects:
                reached = transitive_consumers(consumers, object_name)
                device = sorted(name for name in reached
                                if DEVICE_TARGET.search(name))
                device_reached += len(device)
                closure_artifacts = sorted(name for name in reached
                                           if name.startswith("bin/"))
                artifacts.update(closure_artifacts)
                reachability.append((closure, relative, object_name, len(reached),
                                     len(device),
                                     ",".join(closure_artifacts) or "none"))
            artifact_sets[closure] = artifacts
        if artifact_sets.get("control") != artifact_sets.get("subject"):
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
        control_digest, control_library, control_ids = device_code_digest(
            arguments.control_build, arguments.cuobjdump)
        subject_digest, subject_library, subject_ids = device_code_digest(
            arguments.subject_build, arguments.cuobjdump)
        write_rows(os.path.join(arguments.out, "device-code.tsv"),
                   ("closure", "sass_sha256", "module_identifiers", "library"),
                   (("control", control_digest, control_ids, control_library),
                    ("subject", subject_digest, subject_ids, subject_library)))
        print("module_identifiers_normalized control=%d subject=%d"
              % (control_ids, subject_ids))
        if {control_digest, subject_digest} & {"absent", "unavailable"}:
            device_verdict = "unavailable"
        elif control_digest == subject_digest:
            device_verdict = "identical"
        else:
            device_verdict = "differs"
        print("device_code=%s control=%s subject=%s"
              % (device_verdict, control_digest[:12], subject_digest[:12]))

    if device_reached or device_verdict == "differs":
        verdict = REFUTED
    elif untraced or disagreeing or device_verdict != "identical":
        verdict = NOT_ESTABLISHED
    else:
        verdict = HELD
    print("device_path_isolation=%s" % verdict)
    if control_source != subject_source:
        print("artifact_byte_comparison=unavailable reason=build_paths_differ")
    return EXIT_STATUS[verdict]


if __name__ == "__main__":
    sys.exit(main())
