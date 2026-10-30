#!/usr/bin/env python3
"""Vanilla-parity runner (1.7.10): live Java oracles vs Zig probes.

Usage:
  parity.py list                  # areas + tiers
  parity.py run [area ...]        # run areas (default: all tier-0)
  parity.py run --regen [area]    # re-pin expected/ from live oracle output
  parity.py run --no-cache        # ignore .state/ oracle cache

Contract per area: oracle output and probe output are parsed into plain
values and compared semantically (exact ints, epsilon floats). `expected/`
stores oracle-side goldens so oracle drift (jar/toolchain changes) fails
loudly instead of silently agreeing with a changed probe.

Layout: tools/parity/mc1710/{oracles,areas}/; state in tools/parity/.state/
(gitignored); goldens in areas/<area>/expected/ (checked in).
"""

import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MC1710 = os.path.join(HERE, "mc1710")
REPO = os.path.dirname(os.path.dirname(HERE))
SERVER_JAR = os.path.join(REPO, "jars", "server-1.7.10.jar")
CLIENT_JAR = os.path.join(REPO, "jars", "client-1.7.10.jar")
STATE_DIR = os.path.join(HERE, ".state")
BUILD_DIR = os.path.join(STATE_DIR, "build")
CACHE_FILE = os.path.join(STATE_DIR, "cache.json")
ZIG_BIN = os.path.join(REPO, "zig-out", "bin")

TIER_LIVE = "T0-live-oracle"


def sh(cmd, cwd=None):
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd or REPO)
    if p.returncode != 0:
        raise RuntimeError("command failed: %s\n%s" % (" ".join(cmd), p.stderr[-2000:]))
    return p.stdout


def file_hash(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()[:16]


def load_cache():
    if os.path.exists(CACHE_FILE):
        with open(CACHE_FILE) as f:
            return json.load(f)
    return {}


def save_cache(cache):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(CACHE_FILE, "w") as f:
        json.dump(cache, f, indent=1, sort_keys=True)


def compile_oracle(area, sources, cp_extra=()):
    key = hashlib.sha256("".join(file_hash(s) for s in sources).encode()).hexdigest()[:16]
    out = os.path.join(BUILD_DIR, area, key)
    marker = os.path.join(out, ".ok")
    if os.path.exists(marker):
        return out
    os.makedirs(out, exist_ok=True)
    cp = [SERVER_JAR] + list(cp_extra)
    sh(["javac", "-nowarn", "-cp", ":".join(cp), "-d", out] + sources)
    with open(marker, "w") as f:
        f.write(key)
    return out


def run_oracle(area, main, classes, args, sources, use_cache):
    src_hash = hashlib.sha256("".join(file_hash(s) for s in sources).encode()).hexdigest()[:16]
    cache = load_cache()
    ckey = "%s/oracle/%s/%s" % (area, main, "/".join(args))
    if use_cache and cache.get(ckey, {}).get("src") == src_hash:
        return cache[ckey]["out"]
    out = sh(["java", "-cp", classes + ":" + SERVER_JAR, main] + args)
    cache[ckey] = {"src": src_hash, "out": out}
    save_cache(cache)
    return out


def ensure_probe(binary):
    path = os.path.join(ZIG_BIN, binary)
    if os.path.exists(path):
        return path
    print("probe %s missing, running zig build ..." % binary, flush=True)
    sh(["zig", "build"])
    if not os.path.exists(path):
        raise RuntimeError("probe %s not produced by zig build" % binary)
    return path


def read_corpus(area):
    path = os.path.join(MC1710, "areas", area, "corpus.txt")
    cases = []
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                cases.append(line.split())
    return cases if cases else [[]]


def expected_path(area, case):
    name = "full" if not case else "-".join(case).replace("/", "_")
    return os.path.join(MC1710, "areas", area, "expected", name + ".txt")


def check_or_write(area, case, oracle_out, regen):
    path = expected_path(area, case)
    if regen:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(oracle_out)
        return "regenerated"
    if not os.path.exists(path):
        return "NO-EXPECTED (run --regen), probe-vs-oracle compared live"
    with open(path) as f:
        pinned = f.read()
    if pinned != oracle_out:
        return "ORACLE-DRIFT: live output differs from expected/ (jar/toolchain changed?)"
    return None


def parse_kv(text):
    got = {}
    for line in text.splitlines():
        cur = None
        for tok in line.split():
            if "=" in tok:
                cur, v = tok.split("=", 1)
                if cur in got:
                    cur = None
                else:
                    got[cur] = v
            elif cur is not None:
                got[cur] += " " + tok
    return got


def floats_close(a, b, eps):
    return abs(a - b) <= eps * max(1.0, abs(a), abs(b))


# --- area: rng --------------------------------------------------------------

def rng_oracle(args):
    src = [os.path.join(MC1710, "oracles", "rng", "RndProbe.java")]
    classes = compile_oracle("rng", src)
    return run_oracle("rng", "RndProbe", classes, args, src, USE_CACHE)


def rng_check(otext, ptext):
    got = parse_kv(ptext)
    want = parse_kv(otext)
    for k, v in want.items():
        if k not in got:
            return "probe missing key " + k
        if k.startswith(("nextInt", "nextLong", "nextBytes")):
            if got[k] != v:
                return "%s mismatch: oracle=%s probe=%s" % (k, v, got[k])
            continue
        ovar = [float(x) for x in v.replace(",", " ").split()]
        pvar = [float(x) for x in got[k].replace(",", " ").split()]
        if len(ovar) != len(pvar):
            return "%s arity mismatch" % k
        for o, p in zip(ovar, pvar):
            if not floats_close(o, p, 1e-6):
                return "%s float mismatch: oracle=%s probe=%s" % (k, v, got[k])
    return None


# --- area: registry-blocks ----------------------------------------------------

def blocks_oracle():
    src = [os.path.join(MC1710, "oracles", "mcscan", "BlockIdDump.java")]
    classes = compile_oracle("registry-blocks", src)
    return run_oracle("registry-blocks", "BlockIdDump", classes, [], src, USE_CACHE)


def to_wire(c):
    if c <= 164:
        return c
    if c <= 170:
        return c + 5
    if c <= 323:
        return c + 85
    if c <= 329:
        return c + 93
    return c + 1926


def blocks_probe():
    ids = {}
    with open(os.path.join(REPO, "src", "ids.zig")) as f:
        for line in f:
            line = line.strip()
            if line.startswith("//") or "=" not in line:
                continue
            name, rest = line.split("=", 1)
            name = name.strip()
            val = rest.split(",")[0].strip()
            if name.replace("_", "").isalnum() and val.isdigit():
                ids[int(val)] = name
    wires = sorted(to_wire(c) for c in ids if to_wire(c) < 256)
    return "wires:" + ",".join(str(w) for w in wires) + "\ncount=%d\n" % len(wires)


def blocks_check(otext, _):
    want = []
    for line in otext.splitlines():
        if line.startswith("TOTAL_"):
            continue
        want.append(int(line.split()[0]))
    want = sorted(set(w for w in want if w < 256))
    got = [int(x) for x in blocks_probe().splitlines()[0].split(":")[1].split(",")]
    if want != got:
        only_o = sorted(set(want) - set(got))
        only_p = sorted(set(got) - set(want))
        return "wire-set mismatch: oracle-only=%s probe-only=%s" % (only_o, only_p)
    return None


# --- area: registry-biomes ----------------------------------------------------

def biomes_oracle():
    src = [os.path.join(MC1710, "oracles", "registry", "BiomeDump.java")]
    classes = compile_oracle("registry-biomes", src)
    return run_oracle("registry-biomes", "BiomeDump", classes, [], src, USE_CACHE)


def biomes_probe():
    import re
    found = {}
    with open(os.path.join(REPO, "src", "worldgen", "v5", "biome.zig")) as f:
        for line in f:
            m = re.search(r"//\s*(\d+)\s+(.+?)\s*$", line)
            if m:
                found[int(m.group(1))] = m.group(2)
    return "".join("%d:%s\n" % (k, found[k]) for k in sorted(found))


def biomes_check(otext, _):
    import re
    want = {}
    for line in otext.splitlines():
        k, v = line.split(":", 1)
        k = int(k)
        if v.startswith("ID_MISMATCH"):
            continue
        want[k] = v
    got = {}
    for line in biomes_probe().splitlines():
        k, v = line.split(":", 1)
        got[int(k)] = v
    errs = []
    for k in sorted(set(want) & set(got)):
        if want[k] != "-" and want[k] != got[k]:
            errs.append("biome %d name: oracle=%r probe=%r" % (k, want[k], got[k]))
    src = open(os.path.join(REPO, "src", "worldgen", "v5", "biome.zig")).read()
    m = re.search(r"id <= 39\) return true;", src)
    extra = set()
    if m:
        line = src[m.end():].split("=> true", 1)[0]
        extra = set(int(x) for x in re.findall(r"\d+", line)) - {161}
    allowed = set(range(40)) | extra
    if set(k for k, v in want.items() if v != "-") != allowed:
        errs.append("registered-set mismatch: oracle=%s allowed=%s" % (
            sorted(k for k, v in want.items() if v != "-"), sorted(allowed)))
    return "; ".join(errs) if errs else None


# --- area: genlayer ------------------------------------------------------------

def genlayer_oracle(args):
    src = [os.path.join(MC1710, "oracles", "verify", "LayerProbe.java")]
    classes = compile_oracle("genlayer", src)
    return run_oracle("genlayer", "LayerProbe", classes, args, src, USE_CACHE)


def genlayer_check(otext, ptext, w, h):
    # Vanilla getInts returns an oversized reuse buffer (256-cell floor,
    # growing past it); only the first w*h cells are meaningful (row-major).
    want = w * h
    oracle = {}
    for line in otext.splitlines():
        if line.startswith("R") and ":" in line:
            k, v = line.split(":", 1)
            oracle[k] = [int(x) for x in v.split()][:want]
    probe = {}
    for line in ptext.splitlines():
        if line.startswith("L") and ":" in line:
            k, v = line.split(":", 1)
            probe["R" + k[1:]] = [int(x) for x in v.split()][:want]
    if sorted(oracle) != sorted(probe):
        return "root mismatch: oracle=%s probe=%s" % (sorted(oracle), sorted(probe))
    for k in sorted(oracle):
        if oracle[k] != probe[k]:
            if len(oracle[k]) != len(probe[k]):
                return "%s length: oracle=%d probe=%d" % (k, len(oracle[k]), len(probe[k]))
            diffs = [i for i, (a, b) in enumerate(zip(oracle[k], probe[k])) if a != b]
            return "%s differs at %d cells, first idx=%s (oracle=%s probe=%s)" % (
                k, len(diffs), diffs[0], oracle[k][diffs[0]], probe[k][diffs[0]])
    return None


AREAS = {
    "rng": {"tier": TIER_LIVE, "kind": "per-case"},
    "registry-blocks": {"tier": TIER_LIVE, "kind": "single"},
    "registry-biomes": {"tier": TIER_LIVE, "kind": "single"},
    "genlayer": {"tier": TIER_LIVE, "kind": "per-case"},
}

USE_CACHE = True


def run_single(area, case, regen):
    if area == "rng":
        seed = case[0]
        otext = rng_oracle([seed])
        ptext = sh([ensure_probe("worldgen_dump"), seed, "0", "0"])
        err = rng_check(otext, ptext)
    elif area == "registry-blocks":
        otext = blocks_oracle()
        err = blocks_check(otext, None)
        derr = check_or_write(area, [], otext, regen)
        if err is None:
            err = derr
        elif regen and derr == "regenerated":
            err = "regenerated (semantic gap remains: " + err + ")"
        return label(area, case), otext, err
    elif area == "registry-biomes":
        otext = biomes_oracle()
        err = biomes_check(otext, None)
        derr = check_or_write(area, [], otext, regen)
        if err is None:
            err = derr
        elif regen and derr == "regenerated":
            err = "regenerated (semantic gap remains: " + err + ")"
        return label(area, case), otext, err
    elif area == "genlayer":
        otext = genlayer_oracle(case)
        ptext = sh([ensure_probe("genlayer_dump")] + case)
        err = genlayer_check(otext, ptext, int(case[3]), int(case[4]))
    else:
        return label(area, case), "", "unknown area"
    if err is None:
        err = check_or_write(area, case, otext, regen)
    return label(area, case), otext, err


def label(area, case):
    return area + (" [" + " ".join(case) + "]" if case else "")


def cmd_list():
    for name, meta in AREAS.items():
        print("%-18s %s" % (name, meta["tier"]))


def cmd_run(names, regen):
    fails = 0
    total = 0
    for area in names:
        cases = read_corpus(area) if AREAS[area]["kind"] == "per-case" else [[]]
        for case in cases:
            total += 1
            name, _, err = run_single(area, case, regen)
            flag = "REGEN" if regen and err == "regenerated" else ("FAIL" if err else "ok")
            print("%-42s %s%s" % (name, flag, "" if not err or flag == "ok" else " -- " + err))
            if err and not (regen and err == "regenerated"):
                fails += 1
    print("%d cases, %d failed" % (total, fails))
    return 1 if fails else 0


def main(argv):
    if len(argv) < 2 or argv[1] == "list":
        cmd_list()
        return 0
    if argv[1] != "run":
        print(__doc__)
        return 2
    global USE_CACHE
    regen = "--regen" in argv
    if "--no-cache" in argv:
        USE_CACHE = False
    names = [a for a in argv[2:] if not a.startswith("--")]
    if not names:
        names = [n for n, m in AREAS.items() if m["tier"] == TIER_LIVE]
    unknown = [n for n in names if n not in AREAS]
    if unknown:
        print("unknown areas: %s" % ", ".join(unknown))
        return 2
    if not os.path.exists(SERVER_JAR):
        print("missing %s (jars/ is gitignored; provide 1.7.10 jars)" % SERVER_JAR)
        return 2
    return cmd_run(names, regen)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
