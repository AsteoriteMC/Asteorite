# Parity pipeline (1.7.10)

Live vanilla oracles vs Zig probes. Vanilla jars live in `jars/`
(gitignored — provide `server-1.7.10.jar`; oracle build fails loudly
without it). Oracle Java sources are checked in under
`mc1710/oracles/` (rescued `/tmp` harnesses + new probes), so every
golden is regenerable from this repo.

## Commands

```
tools/parity/parity.py list              # areas + tiers
tools/parity/parity.py run [area ...]    # default: all T0 areas
tools/parity/parity.py run --regen ...   # re-pin expected/ from live oracles
tools/parity/parity.py run --no-cache    # bypass .state/ oracle cache
```

`expected/` holds oracle-side goldens: the runner still executes the
live oracle every run and fails on drift (jar/toolchain change), so a
stale golden can never silently agree with a changed probe. `--regen`
requires the live probe-vs-oracle comparison to pass first (registry
areas pin the oracle output while reporting semantic gaps separately).

## Tiers

- **T0 live oracle**: Java runs against `jars/` every invocation,
  compared semantically with a Zig probe (exact ints, epsilon floats).
  Areas: `rng`, `registry-blocks`, `registry-biomes`, `genlayer`.
- **T1 pinned goldens**: checked-in values with jar citations, no live
  oracle yet (in-tree `zig build test` CRCs/histograms, `expected/`).
- **T2 live E2E**: TCP bots (`tools/traffic_bot.py`,
  `tools/transport_e2e.py`).

See `mc1710/COVERAGE.md` for the full area manifest and open gaps.

## Adding an area

1. Oracle `.java` in `mc1710/oracles/<area>/` (default package, reads
   args from `argv`, prints `key: values` lines).
2. Corpus in `mc1710/areas/<area>/corpus.txt` (one case per line).
3. Adapter in `parity.py`: `*_oracle`, `*_probe` (reuse `zig-out/bin`
   dump tools — never add a probe that duplicates one), `*_check`
   returning `None` or an error string.
4. Register in `AREAS`, run with `--regen`, commit `expected/`.
5. Record in `COVERAGE.md`.

Rules: oracle output is the only truth (never "fix" the oracle to
match the probe); float compares use epsilon with the reason noted;
corpus must include boundary cases (seeds 0/-1/INT64 extremes,
1x1 windows, negative coords).
