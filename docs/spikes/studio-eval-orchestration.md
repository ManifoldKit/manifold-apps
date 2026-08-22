# Studio ↔ manifold-eval orchestration spike

**Decision: viable as an external launcher and artifact viewer; not yet viable as a structured
reporting integration.** Studio can safely own process lifetime, diagnostic display, and artifact
retention while `manifold-eval` remains the only scorer and signal producer. Do not link, bundle,
or vend `manifold-eval` into Studio. A versioned public result artifact is required before Studio
can render a native structured result view.

## Evidence

Read-only source/docs inspected:

- `/Users/roryford/Repos/ManifoldKit/manifold-eval/AGENTS.md`
- `/Users/roryford/Repos/ManifoldKit/manifold-eval/README.md`
- `/Users/roryford/Repos/ManifoldKit/manifold-eval/docs/CONCEPTS.md`
- CLI implementation at `Sources/manifold-eval/main.swift` and per-command files.

The executable's public behavior supports the launcher boundary:

- Every documented command returns the shared exit grammar: `0` clean, `1` needs human
  inspection, `3` indeterminate, `4` known benign artifact. Usage errors return `2`.
- `collate`, `diff`, generator commands, and `perf-bench` deliberately send diagnostics/progress to
  stderr. Reports go to stdout or an explicit `--out` path.
- Offline fixture commands require no model or network and can exercise the flow.

Commands executed from this spike worktree (no `xcodebuild` or app build):

```sh
/Users/roryford/Repos/ManifoldKit/manifold-eval/.build/debug/manifold-eval collate \
  /Users/roryford/Repos/ManifoldKit/manifold-eval/Tests/ManifoldEvalTests/Fixtures/ollama-mistral.json \
  /Users/roryford/Repos/ManifoldKit/manifold-eval/Tests/ManifoldEvalTests/Fixtures/llama-mistral.json \
  --out /private/tmp/manifold-eval-studio-spike.5znaqR/CROSS_RUNTIME.md
```

It wrote a 1,631-byte deterministic Markdown matrix with two records and two cells. Its report
states that holes are not measured zeroes and frames the cross-runtime table as a prompt for human
inspection, rather than a backend-bug verdict.

```sh
/Users/roryford/Repos/ManifoldKit/manifold-eval/.build/debug/manifold-eval collate \
  /Users/roryford/Repos/ManifoldKit/manifold-eval/Tests/ManifoldEvalTests/Fixtures/ollama-mistral.json \
  /Users/roryford/Repos/ManifoldKit/manifold-eval/Tests/ManifoldEvalTests/Fixtures/llama-mistral-othercommit.json \
  --out /private/tmp/manifold-eval-studio-spike.z2akCD/MIXED_CORE.md
```

Observed, in order: a `[warning]` diagnostic on stderr about two incompatible core commits;
successful artifact write; exit `0`. The report repeats the warning. This proves that the Studio
runner can stream diagnostics independently of report capture and must not derive a clean result
solely from exit `0`.

```sh
/Users/roryford/Repos/ManifoldKit/manifold-eval/.build/debug/manifold-eval collate
```

Observed: `error: collate requires at least one record file` on stderr and exit `2`.

The local executable successfully exercised the documented `collate` path, but its build date is
not a substitute for a public CLI version contract. A future integration must query a supported
version/contract surface rather than trust a discovered executable.

## Safe boundary

Studio is a **client of a separately installed executable**, never an evaluator:

1. The user selects an explicit `manifold-eval` executable and a run directory. Studio launches it
   with `Process.executableURL` and an argument array; it must never pass an interpolated shell
   command or accept a free-form runner string.
2. Studio concurrently drains stdout and stderr, timestamps chunks, displays stderr as untrusted
   diagnostic text, and preserves both streams as immutable log artifacts. Independent pipes do not
   supply a total ordering, so timestamps—not assumed line order—are the display order.
3. Studio waits for termination, records the raw exit status, and maps it only to the evaluator's
   published *attention state*. In particular, `1` is “a human should look,” `3` is indeterminate,
   and neither is a Studio-declared regression or bug.
4. Studio views the evaluator-authored Markdown report exactly as an artifact (or exports/reveals
   it). It does not calculate scores, fold cells, suppress holes, adjudicate divergences, or infer a
   verdict from tables.

Use a per-run directory outside the app bundle, for example:

```text
Application Support/ManifoldStudio/Evaluations/<UUID>/
  studio-job.json          # Studio-owned launch metadata and raw termination result
  stdout.log
  stderr.log
  report.md                # evaluator-owned, requested with --out
  inputs/                  # immutable copied or referenced inputs, with hashes
```

`studio-job.json` should record executable path plus SHA-256, selected contract version, argument
array with secret-bearing values redacted, start/finish instants, PID, raw status, and artifact
hashes. Treat all evaluator output, paths, and Markdown as untrusted content: restrict output paths
to the run directory, use Foundation URLs rather than shell expansion, avoid inherited secret-heavy
environments (allowlist required variables only), and use the macOS sandbox/bookmark flow for
user-selected executable and input locations. The Studio app must not distribute the grader or
present its own results as an assurance verdict; both would blur the independent-assurance boundary.

## Missing public artifact contract

The current CLI is adequate for a basic artifact viewer but insufficient for a native fixture-driven
report UI:

| Surface | Current state | Consequence |
|---|---|---|
| `collate`, `ifeval`, `bfcl`, `toolloop`, `diff`, `regress` | Markdown report only | Studio would have to parse presentation text, which is not a public data API. |
| Generator lanes | JSONL capture outputs | They are inputs to scorers, not a completed-run result envelope. |
| `perf-bench` | `--json-out` emits versioned `BenchResult` array | Useful precedent, but it lacks job metadata/diagnostics/exit attention state and covers only performance. |
| Executable identity | no public `--version`/capability command found | Studio cannot safely select a decoder or gate incompatible CLI versions. |

Required upstream addition in **manifold-eval**, owned and versioned there: a stable
`--artifact-out <directory>` (or equivalent) contract for every finished command, plus
`manifold-eval --version --json`. The directory should contain:

```json
{
  "schemaVersion": 1,
  "tool": { "name": "manifold-eval", "version": "…", "build": "…" },
  "command": "collate",
  "attentionState": "clean | inspect | indeterminate | benignArtifact | executionError | usageError",
  "diagnostics": [{ "severity": "warning", "message": "…" }],
  "artifacts": [{ "path": "report.md", "sha256": "…", "mediaType": "text/markdown" }],
  "result": { "command-owned, versioned typed result": "…" }
}
```

The evaluator, not Studio, must populate `attentionState`, diagnostics, and typed results. The
contract must retain first-class “not measured” / error states and raw evidence references rather
than normalizing them to failures or zeroes. Studio can decode only a schema version it explicitly
supports, otherwise preserve and open the Markdown/log artifacts without interpretation.

## Conclusion and scope

No app code was added: the current report artifact plus `Process`-level standard I/O is enough to
prove the safe launcher/viewer boundary, and adding a Studio UI now would either be an unpolished
Markdown shell or force Studio to reimplement evaluator presentation semantics. The correct next
step is an evaluator-owned, versioned artifact manifest; after that, a small Studio job controller
can launch it and display the manifest without importing any scoring code.

Files changed by this spike: this document only.
