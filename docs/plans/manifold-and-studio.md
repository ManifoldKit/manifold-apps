# Manifold and Manifold Studio product plan

Status: accepted product direction. Wave 0 risk retirement is complete and the
Wave 1 macOS rename is implemented, adversarially reviewed, and build-verified.
The complete iOS UI suite passes; the macOS UI runner is blocked before test
execution by an active host system-authentication session. Studio implementation
has not started.

## Product definition

ManifoldKit and its companion packages are the product. The applications in
this repository are executable documentation: they consume published public
APIs exactly as an external adopter would and demonstrate those APIs in
complete, tested applications.

### Manifold

Manifold is the flagship native reference application for iOS, iPadOS, and
macOS. It demonstrates the application-facing experience a developer can ship
with ManifoldKit: conversations, persistence, model and endpoint selection,
attachments, tools and approvals, RAG, voice, App Intents, theming, and the
appropriate local or cloud backends for each platform.

The iOS and macOS builds may have distinct native targets, but they present one
product and share application code where the platforms genuinely have the same
interaction. Platform-specific behavior remains native rather than being
forced through a lowest-common-denominator abstraction.

### Manifold Studio

Manifold Studio is the advanced developer workbench for ManifoldKit and its
companions. It combines a local server with a browser interface to demonstrate
and inspect capabilities that are too operational, diagnostic, or specialized
for the flagship application.

Studio is intended to demonstrate:

- hosting ManifoldKit through its server product and consuming it from a
  non-Swift client;
- backend, model, capability, template, sampler, and tool configuration;
- raw streaming, structured output, reasoning, tool-loop, MCP, RAG, and
  observability behavior;
- reproducible performance measurements across local and cloud backends; and
- external orchestration and presentation of independent eval evidence.

Studio is not a separate inference implementation or a commercial service.
General-purpose runtime, model, evaluation, and tooling capabilities belong in
ManifoldKit, a companion, or `manifold-eval`. Studio proves and explains those
public surfaces.

## Repository boundaries

| Repository | Owns | Must not own |
| --- | --- | --- |
| `ManifoldKit` | Runtime contracts, server library, provider-independent behavior, public inspection and observability APIs | App-specific presentation |
| `manifold-mlx` / `manifold-llama` | Backend implementations and backend-specific executable surfaces | Studio orchestration or cross-backend verdicts |
| `manifold-eval` | Independent capture, scoring, collation, regressions, reproducibility guards, and evidence semantics | Studio UI or dependencies required by the graded repositories |
| `manifold-apps` | Flagship native application, Studio host, browser workbench, orchestration adapters, and copyable examples | Private hooks or duplicate runtime/eval logic |

All production targets in this repository continue to consume published tags.
If an application needs an unreleased or private hook, the work stops and the
missing public API is designed and released in the owning repository first.

## Target architecture

```text
Manifold iOS ─────────────── public ManifoldKit + companion APIs
Manifold macOS ───────────── public ManifoldKit + companion APIs

Studio browser
      │ same-origin HTTP + streaming
      ▼
Studio SwiftPM daemon ────── ManifoldServerKit and public control APIs
      │
      ├── configured local/cloud backend processes or services
      └── external manifold-eval jobs and references to evaluator-owned artifacts
```

The OpenAI-compatible API remains the interoperability surface for ordinary
inference clients. Studio-only lifecycle, diagnostics, capabilities, job, and
artifact operations use an explicit control-plane API rather than overloading
compatibility endpoints.

The browser application is built to static assets and, once the server exposes
a public route-extension seam, is served by the Studio daemon on the same
origin. Production use does not require a Node runtime. Generated or
hand-written client types must be derived from one versioned contract rather
than allowing the Swift and browser representations to drift independently.

The server daemon is a dedicated SwiftPM executable, not an XcodeGen application
target. SwiftPM can enable ManifoldKit's Server trait on a published dependency;
the current XcodeGen-generated package reference cannot express that trait.

`manifold-eval` remains an external authority. Studio may configure a launch,
start the CLI or an eventual public runner, stream diagnostics, capture raw
terminal status, retain launch metadata, and visualize references to its
evidence. The evaluator owns artifacts, attention grammar, diagnostics, and
typed results. Studio does not reimplement scorers, parse presentation text as
data, or silently convert `clean`, `attention`, `indeterminate`, or `artifact`
outcomes into a Studio verdict.

## Proposed future layout

This is a destination, not a description of the current tree:

```text
Manifold/
  Shared/
  iOS/
  macOS/
Studio/
  Server/
  Web/
  ProcessSupport/
Tests/
docs/
  plans/
  spikes/
```

Do not perform a wholesale directory move before the first target migration.
Each implementation milestone moves only the files it owns and updates build
configuration, tests, documentation, and `AGENTS.md` together.

## Developer-workbench workflows

Studio should be organized around developer questions rather than a feature
gallery:

1. **Playground:** send a request and inspect raw streaming events, reasoning,
   structured output, tool calls, approvals, and the copyable client code.
2. **Models and backends:** inspect registered capabilities and configure or
   operate supported model sources without hiding backend differences.
3. **Server:** start and inspect a ManifoldKit server, authentication posture,
   active requests, and interoperability examples.
4. **Tools and MCP:** inspect schemas, policies, calls, results, and complete
   multi-turn tool transcripts.
5. **Benchmarks:** capture timing, throughput, memory, warm/cold state, hardware,
   model, quantization, renderer, sampler, and version provenance.
6. **Evals:** launch independent jobs, follow progress, retain artifacts, compare
   measured cells, and support human triage without claiming new verdicts.
7. **Diagnostics:** expose the exact public configuration and capability state
   that explains observed behavior.

Every workflow should make three things discoverable: what ManifoldKit did,
which public API drove it, and how the developer can reproduce it.

## Delivery sequence

### Wave 0: plan and risk retirement

- Record this product definition and repository boundary.
- Run the server-host, browser-boundary, and eval-orchestration spikes below.
- Convert missing public surfaces into acceptance-criteria-complete backlog
  items in their owning repositories.

Exit: the implementation topology is supported by evidence, or its exact
blockers are known. No spike prototype is promoted directly to production.

### Wave 1: one native Manifold product

- Rename the existing macOS application target and user-facing product from
  Manifold Studio to Manifold while retaining a native macOS target.
- Replace platform-named feature registries with product-appropriate seams.
- Keep advanced developer-only surfaces available until Studio has a verified
  replacement; remove them from Manifold only with coverage for the new path.
- Update XcodeGen, schemes, UI tests, bundle identifiers/display names, release
  documentation, and canonical repository instructions coherently.

Exit: iOS and macOS builds present one Manifold product, and the full affected
test gate is green.

### Wave 2: Studio host and browser foundation

Prerequisites: U1 and the **read-only** portion of U3 have shipped as published
releases. Until then a SwiftPM daemon may prove only `/health` and the existing
OpenAI-compatible inference endpoints; it cannot satisfy this wave's
same-origin/static-asset or runtime-metadata exit condition.

- Add the smallest supported Studio server target consuming the published
  server library.
- Serve versioned static assets from the same origin.
- Establish health, server metadata, capability discovery, and deterministic
  streaming playground contracts.
- Add hermetic contract and browser tests before live backends.

Exit: a browser can identify the server and complete one deterministic streamed
turn through public ManifoldKit surfaces.

### Wave 3: advanced runtime workbench

- Add backend/model inspection and lifecycle operations supported by public
  APIs.
- Add structured output, tools/approval, MCP, RAG, and observability workflows
  incrementally.
- Include copyable Swift and HTTP examples with each workflow.

Exit: each exposed capability has a reproducible demo, explicit error states,
and an affected full-suite gate.

### Wave 4: companion and process topology

- Add isolated runtime processes where backend lifecycle or linking constraints
  require them.
- Make discovery, startup, shutdown, crash recovery, version compatibility, and
  artifact locations explicit.
- Add opt-in hardware-gated verification without weakening hermetic CI.

Exit: supported companion configurations are reproducible and failures are
visible rather than silently falling back.

### Wave 5: eval and benchmark workbench

- Prerequisite: U2 has shipped its evaluator-owned machine-readable identity
  and versioned manifest/artifact contract before any structured evaluator UI.
- Add launch orchestration against the independent `manifold-eval` surface.
- Preserve Studio launch metadata plus stdout/stderr, raw terminal status, and
  references to evaluator-owned manifests, captures, reports, diagnostics, and
  provenance.
- Present comparisons without collapsing unmeasured, indeterminate, or
  non-comparable cells into failures or deriving a Studio assurance result.

Exit: one fixture-driven external evaluator launch and one opt-in live
measurement can be launched, observed, and reopened from evaluator-owned
manifest/artifact references and Studio launch provenance; Studio makes no
derived verdict.

## Issue-ready implementation backlog

The following items are intentionally ordered. Each is small enough to become
one issue after its owning spike has resolved the open technical detail.

### U1 (`ManifoldKit`): expose a bounded server-host extension seam

Why it matters: a published `ManifoldServerKit` consumer can start the server
but cannot currently add Studio's static assets or control-plane routes without
reaching into its internal router.

Acceptance criteria:

- a public host extension point can mount bounded routes and/or static assets
  before server startup;
- the default `ManifoldServer` executable retains its existing routes and
  behavior without host configuration;
- the API does not expose mutable server internals beyond what an adopter needs;
- route conflicts and missing asset roots fail visibly and have tests; and
- the surface ships in a published release consumed by a remote-only fixture.

### U2 (`manifold-eval`): publish executable identity and result artifacts

Why it matters: Studio can preserve the CLI's Markdown and diagnostics today,
but cannot safely render structured results without parsing presentation text
or guessing evaluator compatibility.

Acceptance criteria:

- `manifold-eval --version --json` reports a versioned machine-readable
  identity and supported artifact schemas;
- every finished command can emit an evaluator-owned versioned manifest with
  attention state, diagnostics, artifact hashes, raw evidence references, and
  a command-specific typed result;
- unmeasured and indeterminate states remain first-class;
- fixture tests prove warning-plus-exit-0 and nonzero exit behavior; and
- Markdown remains available for humans and backward-compatible automation.

### U3 (`ManifoldKit`): expose portable runtime-control snapshots

Why it matters: Studio can list inference models today, but released public
APIs do not provide a sanitized server identity, backend/capability snapshot,
or safe request-scoped lifecycle/cancellation controller suitable for a remote
developer workbench.

Acceptance criteria:

- a transport-free public provider returns `Sendable`/`Codable` server,
  backend, model, capability, and operation snapshots with stable opaque IDs;
- the provider owns concurrency and never hands an arbitrary backend instance
  to HTTP/UI code;
- capability projection is explicit and excludes credentials, local paths,
  prompts, and provider-private responses;
- lifecycle and cancellation are advertised only where settled outcomes can be
  reported safely; backend-wide `stopGeneration()` is not presented as
  request-scoped cancellation; and
- a published-consumer fixture proves missing optional lifecycle support and
  conservative capability reporting.

### B1: make the macOS target Manifold — implemented and build-verified

Why it matters: the flagship reference should demonstrate one coherent native
application across Apple platforms before the Studio name is reused for a
different architecture.

Acceptance criteria:

- the macOS scheme, product name, user-facing strings, bundle identity, tests,
  and release instructions consistently describe Manifold;
- shared sources retain platform-native behavior and no longer call the macOS
  feature set "Studio";
- generated project output remains ignored;
- generated scheme/product validation succeeds; and
- the complete affected iOS and macOS test gate is run, with host-level test
  initialization failures distinguished from application test failures.

Confirmed and implemented decisions:

- `ManifoldMac` is the internal macOS target, UI-test prefix, and scheme;
  product/display name is `Manifold`.
- Both platform builds use the shared `com.manifoldkit.Manifold` bundle ID.
- The old Studio data identity is treated as fresh data: no SwiftData,
  preferences, or Keychain migration is added.
- `MANIFOLD_STUDIO_*` variables were renamed without compatibility aliases.
- Signing, notarization, and distribution remain deferred.

Generated scheme/product validation succeeded, and a Terra-high adversarial
re-review returned **SHIP**. The initial published `manifold-mlx`
`MLXMetallibPlugin` failure reproduced in an origin/main-equivalent worktree;
installing Xcode's optional Metal toolchain resolved it. The full iOS and
macOS build then passed, including production of `Manifold.app`, and the iOS UI
suite passed 42 tests with one expected physical-device-only skip and no
failures. Two macOS UI-suite launches built successfully but XCTest executed
zero tests because LocalAuthentication rejected runner initialization with
`Code=-4`, `System authentication is running`. This is a confirmed host test
service blocker, not an application assertion failure; rerun the macOS suite
after the host authentication session ends.

### B2: establish a supported Studio server consumer

Why it matters: Studio must prove the published server library can be embedded
by an adopter instead of relying on ManifoldKit repository internals.

Acceptance criteria:

- a documented target consumes a released `ManifoldServerKit` and its required
  trait through a dedicated SwiftPM manifest;
- it starts and stops cleanly, reports health and version metadata, and makes
  bind address/port explicit;
- it uses U1's published route/static-asset seam rather than server internals;
- deterministic tests cover startup failure and port conflicts; and
- no local package path, source copy, or private API is introduced.

### B3: publish the minimal Studio control-plane contract

Why it matters: lifecycle and diagnostics do not belong in compatibility
resources, while browser and Swift representations must not drift.

Acceptance criteria:

- ManifoldKit public APIs provide only transport-free, provider-independent
  runtime snapshots and safe lifecycle primitives; Studio owns the versioned
  HTTP/SSE envelope, operation IDs, event retention, and browser history;
- the Studio contract versions its runtime projections and launch metadata
  without duplicating runtime state; `manifold-eval` independently owns and
  versions evaluator manifests, attention grammar, artifacts, and typed
  results;
- ordinary inference retains the server's existing OpenAI-compatible wire
  behavior;
- error, cancellation, unsupported-capability, and version-mismatch shapes are
  explicit; and
- hermetic contract fixtures drive both server and browser tests.

### B4: serve the deterministic Studio browser shell

Why it matters: a same-origin non-Swift client is the smallest proof that the
server surface is usable outside SwiftUI.

Acceptance criteria:

- static production assets require no Node runtime;
- the browser discovers the server/capabilities and completes one scripted
  streamed turn;
- disconnect, cancellation, malformed chunks, and server errors are visible;
- the page includes copyable HTTP and Swift equivalents; and
- browser verification is deterministic and does not require a live model.

### B5: define and implement backend-worker supervision

Why it matters: advanced companion demonstrations must respect linking,
hardware, lifecycle, and crash-isolation constraints rather than hiding them
inside one fragile process.

Acceptance criteria:

- supported worker executables, version compatibility, discovery, startup,
  shutdown, and crash semantics are documented, using the same versioned
  `/studio/v1/server` and `/studio/v1/capabilities` handshake resources as the
  daemon rather than an unversioned worker-specific handshake;
- stdout/stderr and terminal state remain inspectable;
- no worker silently falls back to a different backend; and
- hermetic doubles cover supervision while real hardware checks remain opt-in.

### B6: add the independent eval job adapter

Why it matters: developers should be able to launch and inspect assurance runs
without moving grading authority into Studio.

Acceptance criteria:

- Studio discovers a compatible `manifold-eval` executable or reports an
  actionable absence/version error;
- compatibility is negotiated through U2's published identity/artifact
  contract, never by parsing human-readable version or report text;
- it launches one fixture-driven job with fixed arguments and an isolated
  artifact directory;
- diagnostics, report output, exit-code grammar, cancellation, and restart
  behavior are preserved exactly; and
- Studio launches with `Process.executableURL` and an argument array (never a
  shell), hashes the selected executable, records a redacted argument array,
  allowlists inherited environment values, and confines output to the isolated
  run directory;
- stdout and stderr are drained concurrently with timestamps, evaluator output
  is treated as untrusted, and raw termination status plus artifact hashes are
  retained in Studio-owned launch metadata; and
- Studio presents evaluator-owned artifacts and attention state but does not
  reinterpret, recompute, or derive an assurance result.

### B7: add reproducible benchmark manifests

Why it matters: performance demonstrations are useful only when a developer can
reproduce the model, runtime, prompt, sampler, hardware, and warm/cold state.

Acceptance criteria:

- every run records all comparison inputs plus tool and dependency versions;
- raw samples and aggregate statistics remain available;
- unmeasured or non-comparable cells cannot render as zero or failure; and
- a saved manifest can rerun the same supported configuration or clearly state
  which dependency is no longer available.

## Bounded spikes

### S1: published server host

Question: can this repository consume `ManifoldServerKit` with the required
Server trait through a supported published dependency and package a host that
serves health plus static assets?

Evidence required:

- exact consumer/build-system shape;
- trait and XcodeGen/SwiftPM behavior;
- minimal host/static-asset proof or exact compile-time blocker; and
- recommendation for the production target boundary.

### S2: browser API boundary

Question: which operations fit the compatibility API, and what minimal
Studio-specific control plane is required?

Evidence required:

- capability/model discovery contract;
- one deterministic streaming contract;
- same-origin static-asset posture;
- browser error/cancellation behavior; and
- a reasoned framework/toolchain recommendation.

### S3: independent eval orchestration

Question: can Studio safely launch, observe, and retain one fixture-driven
`manifold-eval` run without absorbing its grading authority?

Evidence required:

- executable discovery and process lifecycle;
- stdout/stderr and terminal-status handling;
- current report/artifact suitability;
- missing machine-readable surface, if any; and
- distribution and security implications.

## Spike findings

### S1: published server host — supported with one upstream gap

The worker created a disposable remote-only SwiftPM consumer using
`ManifoldKit` `0.76.0..<0.77.0`, enabled `traits: ["Server"]`, and depended on
`ManifoldServerKit`. `swift package resolve` selected published v0.76.0 and
`swift build -c debug` compiled the server module and probe successfully.

The released public entry point
`ManifoldServer.serve(configuration:backendProvider:)` owns an internal
`ServerApp`. Its router already mounts `/health`, `/v1/models`, chat,
embeddings, and metrics, but no public router, route installer, or static-asset
configuration is available. Consequently, a Studio host cannot yet serve the
browser on the same port without a new ManifoldServerKit public seam. A separate
static port is technically possible but is not the recommended product shape.

A separate XcodeGen 2.45.4 probe accepted a `traits: [Server]` YAML key but
emitted no trait representation in the generated package reference or product
dependency. The key was silently ineffective. The supported topology is
therefore a dedicated macOS SwiftPM daemon, not another target in the generated
Xcode project.

Commands used: `swift package dump-package`, `swift package resolve`,
`swift build -c debug`, and a bounded `xcodegen generate` inspection. No
`xcodebuild` ran. The disposable package/project was removed; no prototype
should be retained. Remaining work belongs first in ManifoldServerKit: expose a
bounded public route/static-asset extension point through a published release.

### S2: browser boundary — feasible after protocol correction

A framework-free HTML/JavaScript fixture demonstrated the intended client
shape without a Node production runtime. Ordinary inference stays on
`GET /v1/models` and `POST /v1/chat/completions`. The latter preserves
ManifoldServer's existing OpenAI-compatible SSE framing:
`Content-Type: text/event-stream`, `data: <json>` events, and terminal
`data: [DONE]`. Browser `fetch()` can POST and incrementally parse that stream;
`EventSource` is not required.

Lifecycle, capability, server, eval-job, and artifact state belongs under a
separately versioned Studio control-plane namespace such as `/studio/v1/*`.
Static assets should be same-origin once S1's route seam exists. A syntax check
passed, but sandbox socket restrictions prevented a real local browser/server
round trip, so cancellation, malformed events, authentication, and connection
failure remain deliberately unproven.

The initial worker answer incorrectly changed the compatibility endpoint to
NDJSON. Review caught the protocol break; the worker inspected ManifoldServer,
changed the probe to its actual SSE wire format, removed named-element globals,
and passed `node --check` plus `git diff --check`. The disposable browser probe
is useful evidence but should be rewritten from the eventual versioned contract
rather than promoted as production code.

### S3: eval orchestration — launcher/viewer viable, structured UI blocked

Detailed evidence: [`../spikes/studio-eval-orchestration.md`](../spikes/studio-eval-orchestration.md).

The worker drove the existing `manifold-eval collate` CLI against repository
fixtures. One run wrote a deterministic Markdown matrix. A mixed-core fixture
emitted a warning on stderr, repeated it in the report, successfully wrote the
artifact, and exited `0`. An argument-error run wrote to stderr and exited `2`.
This proves Studio must retain stderr and the evaluator's raw exit status; exit
`0` alone is not a clean/attention-free verdict.

Studio can safely launch a separately installed compatible executable using
Foundation `Process` with an argument array, concurrently retain stdout and
stderr, record raw termination state, and present evaluator-owned artifacts as
untrusted content. It must not invoke through a shell, inherit a secret-heavy
environment, parse Markdown as a data API, recompute scores, or reinterpret the
evaluator's exit grammar.

The current CLI is sufficient for an artifact viewer but not a native
structured results UI. Most lanes emit Markdown only; only `perf-bench` has a
JSON result option, and no public machine-readable version/capability command
was found. The required upstream work is an evaluator-owned
`--version --json` surface and a versioned per-run artifact manifest containing
the attention state, diagnostics, typed result, raw evidence references, and
artifact hashes. No application prototype was warranted; the spike retained
only its evidence document.

### S4: Studio control contract — viable read-only v1, lifecycle gated

Detailed contract: [`../spikes/studio-control-contract.md`](../spikes/studio-control-contract.md).

The released v0.76.0 surface supports the existing OpenAI-compatible inference
data plane but exposes no public route mount, runtime inspection provider, or
safe request-scoped lifecycle controller. Studio should keep inference bytes
unchanged and use a separately versioned `/studio/v1` control plane for server
identity, capability snapshots, backend/model inspection, operations, events,
and external job references.

The initial v1 must advertise lifecycle and request cancellation as unsupported
until U3 lands. `InferenceBackend.stopGeneration()` is backend-wide, while the
public `CancellableModelLoading` opt-in is planned but not wired to production
backends; neither can truthfully settle an individual Studio operation.

The contract uses snapshot GETs plus a reconcilable Studio SSE event stream,
stable JSON error/version envelopes, capability-driven browser controls, and
shared deterministic fixtures. U1 remains the prerequisite for mounting these
routes. Generic identity/capability/lifecycle facts belong in ManifoldKit;
Studio owns HTTP presentation, operation IDs, event retention, and browser
history.

Review found and corrected one material authority error. `ManifoldAppEval`
golden scenarios are developer self-checks only. Independent assurance jobs
launch `manifold-eval`, preserve evaluator-owned attention state, diagnostics,
manifests, and artifacts as opaque references, and never become a Studio
verdict or derived result.

### S5: companion process topology — isolated local workers

Detailed topology: [`../spikes/studio-companion-topology.md`](../spikes/studio-companion-topology.md).

V1 should run the Studio control plane as a SwiftPM daemon. Foundation and
remote provider families may remain directly registered in that daemon.
MLX and llama/GGUF each use a separate loopback-only SwiftPM worker linked to
exactly one companion plus `ManifoldServerKit`; workers implement the released
`ServerBackendProvider` injection seam and expose the existing inference HTTP
surface.

Studio supervises child PIDs, drains stdout/stderr concurrently, retains
bounded diagnostics, uses per-launch bearer credentials, and serializes local
hardware access so at most one MLX/GGUF worker loads or generates at once. A
worker owns its backend instance, model handles, caches, and process-exit
cleanup. U1 is required before workers can add a Studio version/capability
handshake on the same server.

Direct remote tag verification resolved the worker's conservative release
question: `manifold-mlx` v0.5.2 exists at
`c47d0b0358b8a33e47db8a1a8a8ee53891f0723c`, and `manifold-llama` v0.4.5
exists at `9a88af0a989d579688ead1bf2209a36eddccfb15`. The local clones had stale tag
refs; the pins in `project.yml` are published and are not a blocker.

### S6: macOS Manifold rename — implemented, generator-reviewed

Detailed inventory: [`../spikes/manifold-macos-rename-inventory.md`](../spikes/manifold-macos-rename-inventory.md).

The inventory identified the rename surface across `project.yml`, the app
entry point, feature registries, launch arguments, macOS UI tests, shared test
helpers, real-model scripts, Makefile, CI, release docs, README, and `AGENTS.md`.
The confirmed `ManifoldMac`/`Manifold` target and product decisions were then
implemented atomically, with generated scheme/product validation succeeding.

Root/Terra review caught a generator-level product-name mismatch and stale
inventory statements before closure; those were corrected. Terra-high
adversarial re-review returned **SHIP**. Installing Xcode's optional Metal
toolchain resolved the independently reproduced `MLXMetallibPlugin` build
failure; the complete build and iOS UI suite are green. The remaining macOS UI
verification is host-blocked before test execution because LocalAuthentication
reports an already-running system authentication session on repeated launches.

## Model-fit retrospective

The spikes deliberately use cheaper workers. Assess them after technical
review, not from elapsed time alone.

| Spike | Assigned model | Retrospective evidence | Verdict |
| --- | --- | --- | --- |
| S1 server host | GPT-5.6 Terra, medium | Found the silent XcodeGen trait failure, proved the published SwiftPM path with a real build, and identified the internal-router API gap without review rework. | Appropriately powered |
| S2 browser boundary | GPT-5.6 Luna, medium | Produced the small fixture efficiently, but initially broke the existing streaming protocol by substituting NDJSON for SSE. Required explicit reviewer correction, then fixed it correctly. | Underpowered for protocol design; suitable for implementation after the contract is fixed |
| S3 eval orchestration | GPT-5.6 Terra, medium | Exercised real fixtures, caught the non-obvious warning-plus-exit-0 behavior, preserved the assurance boundary, and identified a precise upstream artifact/version gap without review rework. | Appropriately powered |
| S4 control contract | GPT-5.6 Terra, medium | Produced strong released-API and cancellation analysis, but initially merged `ManifoldAppEval` self-checks with independent `manifold-eval` authority despite the stated boundary. Required a material reviewer correction. | Underpowered for a combined cross-repository authority contract; split the task or use Terra-high for synthesis |
| S5 companion topology | GPT-5.6 Terra, medium | Reached the correct isolated-worker topology and public injection seam. Review clarified daemon naming, dependency-trait syntax, the U1 route prerequisite, and resolved a conservatively reported stale-tag uncertainty with remote evidence; no topology redesign was required. | Appropriately powered with normal integration review |
| S6 macOS rename | GPT-5.6 Luna, medium | Luna was effective for the broad mechanical inventory, but root/Terra review was needed to catch a generator-level product-name mismatch and stale inventory statements before the Terra-high adversarial re-review returned SHIP. | Appropriate for initial inventory; underpowered as the sole owner of generator-aware implementation closure/review. |

Use these criteria:

- **Underpowered:** missed a material constraint, produced an invalid proof,
  required substantial architectural rework, or could not resolve a bounded
  question despite available evidence.
- **Appropriately powered:** reached a supported conclusion with traceable
  evidence and needed only ordinary review corrections.
- **Overpowered:** completed mostly mechanical work with negligible judgment
  and could credibly have used a lower-cost tier.

### Evidence-driven worker routing

This retrospective is a project experiment register, not a claim that one
model tier is universally right for a category. Future parallel batches should
record the task shape, assigned model and effort, evidence produced, material
review defects, follow-up turns, and final rework before changing the routing
rule.

Current routing hypothesis after two batches:

- use Luna-medium for narrow mechanical inventories or implementation after a
  contract and acceptance criteria are fixed;
- use Terra-medium for bounded protocol design, build-system integration, or
  process topology within one clear authority boundary;
- split a contract that spans runtime APIs, product orchestration, and
  independent assurance into separate Terra tasks, then use Terra-high for the
  authority-preserving synthesis;
- use Terra-high for cross-spike synthesis and adversarial review, escalating
  only after a material miss leaves the boundary unresolved; and
- promote a task one tier after a material review miss; consider demotion only
  after repeated clean results on the same task shape.

The second batch validated Luna on a mechanical inventory and Terra on a
bounded process topology. It also showed that a broad cross-repository contract
can exceed Terra-medium even when its individual API analysis is strong.

## Deferred decisions

- Studio distribution and signing format.
- Production LAN access, pairing, authentication, and TLS.
- Backend-worker installation and update strategy.
- Persistent Studio project/workspace semantics.
- Long-running job recovery across Studio restarts.
- Whether an eventual generated browser client is justified by API size.
- Cross-device conversation ownership or synchronization.

These are intentionally outside the spikes unless one blocks their minimal
proof. They should not be guessed into the first implementation.
