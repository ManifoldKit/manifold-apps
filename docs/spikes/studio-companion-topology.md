# Studio companion process topology spike

**Status:** recommendation for a v1 Studio workbench; no implementation in this
spike.  **Question:** how can a macOS Studio demonstrate MLX, llama.cpp/GGUF,
Foundation Models, Ollama, and cloud providers without making the Studio app
process a link-time and runtime home for every backend family?

## Recommendation

Use one lightweight **Studio browser/workbench** process and one optional,
single-family **worker server process** per local runtime.  The worker embeds
the released `ManifoldServerKit` facade, implements its public
`ServerBackendProvider`, and links exactly one companion family:

```text
Studio daemon/browser (SwiftPM host)
  ├─ direct, in-process: Foundation / Ollama / cloud through ManifoldKit
  ├─ HTTP (loopback, authenticated) ──> manifold-studio-mlx-worker
  │                                      └─ ManifoldServerKit + ManifoldMLX
  └─ HTTP (loopback, authenticated) ──> manifold-studio-llama-worker
                                         └─ ManifoldServerKit + ManifoldLlama
```

The workers expose the released OpenAI-compatible interface (`/v1/models`,
`/v1/chat/completions`, `/v1/embeddings`, `/health`, optionally `/metrics`).
Studio owns orchestration, UI state, worker discovery, and per-worker model
selection.  Each worker owns native runtime initialization and its loaded
model.  V1 starts at most one hardware-consuming local worker at a time; it
does not attempt MLX + llama.cpp concurrency merely because they are separate
processes.

This is the least-coupled supported boundary: it uses a public server facade
and protocol rather than private server classes, keeps the SwiftPM package
graphs separate, and gives a stable HTTP contract to the Studio UI.

## Evidence and confidence boundaries

The following are **released-tag facts**, inspected with `git show` rather
than inferred from the checked-out main branches.

| Repository/tag | Proven public surface | Consequence |
| --- | --- | --- |
| `ManifoldKit v0.76.0` | `Package.swift` publishes executable `ManifoldServer` and library product `ManifoldServerKit`; its `Server` trait gates Hummingbird/server code. | A standalone SwiftPM server host is supported. Per S1, the consuming worker's manifest enables the dependency `Server` trait; this is not a vague instruction to invoke a root build with `--traits Server`. XcodeGen cannot express that dependency trait. |
| `ManifoldKit v0.76.0` | `ManifoldServer.serve(configuration:backendProvider:)` is public, as are `ServerBackendProvider` and `ServerBackendRequest` (`Sources/ManifoldServer/ManifoldServer.swift`, `ServerBackendProvider.swift`). | A worker can embed the server and inject a companion backend without changing core. |
| `ManifoldKit v0.76.0` | The stock `ManifoldServer` CLI loads only Foundation or Ollama. Its MLX/GGUF selections explicitly fail, cloud is `notImplemented` (`TraitAwareServerBackendProvider.swift`; `docs/QUICKSTART-SERVER.md`). | Do not shell out to the released CLI for MLX, llama, or cloud; write small family-specific hosts around the facade. |
| `manifold-mlx v0.5.0` | Library product `ManifoldMLX`; executables only `manifold-tools-mlx` and `fuzz-mlx` (`Package.swift`). `MLXBackends` registers an `MLXBackend`; `MLXBackend` is public and loads from a local snapshot or model identifier. | There is no released MLX HTTP server executable. The worker constructs/caches `MLXBackend` itself. |
| `manifold-llama v0.4.3` | Library product `ManifoldLlama`; executables are `manifold-tools-llama` and `manifold-llama-eval` (`Package.swift`). `LlamaBackends` registers `LlamaBackend`; the backend loads local `.gguf` URLs. | There is no released GGUF HTTP server executable. The worker constructs/caches `LlamaBackend` itself. |
| `manifold-eval v0.1.4` | README and `Package.swift` deliberately keep MLX/llama out of the eval process; collation uses separate-process `ConformanceRecord` JSON. `LlamaRunnerDriver` uses a subprocess and drains stdout/stderr concurrently. | The estate already treats native local families as process-isolated and shows the required log-pipe discipline. |

**Local-main observations, not a release guarantee:** at inspection time,
`manifold-mlx` HEAD was `v0.4.0-5-gff88fb5`, `manifold-llama` HEAD was
`v0.4.3`, and ManifoldKit HEAD was dirty at `v0.75.0-36-g92d133a6`. Their
manifests still expose the tools/eval executables above, not a general worker
server product. The local clone's tags are stale: direct public remote evidence
from `git ls-remote --tags` verifies `manifold-mlx v0.5.2` at
`c47d0b0358b8a33e47db8a1a8a8ee53891f0723c` and `manifold-llama v0.4.5` at
`9a88af0a989d579688ead1bf2209a36eddccfb15`. Studio's declared pins are thus
released, not an implementation blocker. The tagged-surface audit above remains
anchored to the locally available `v0.5.0`/`v0.4.3` objects until those refs are
fetched; do not treat local-main observations as evidence about the newer tags.

## Why the boundary is feasible

### Injection seam and wire protocol

`ServerBackendProvider` requires `listModels()` and
`backend(for: ServerBackendRequest)`, with optional `listModelRecords()` and
`embeddingBackend(for:)`.  A worker actor can lazy-load and cache one backend
per selected model, then return it to the server for each request.  The server
facade explicitly documents this companion-host recipe and says registrars
(`MLXBackends`/`LlamaBackends`) are **not** the server seam: registrars feed an
`InferenceService`, while the server calls the provider directly.

For Studio, HTTP is preferable to a custom stdin protocol:

- it is already a public, OpenAI-compatible wire with streaming SSE;
- it supports worker health and model discovery without a second protocol;
- `manifold-eval` already has a symmetric OpenAI-compatible HTTP driver; and
- native crashes become process exits, rather than app-process corruption.

Bind each worker to loopback only. `ServerConfiguration` rejects a keyless
non-loopback bind and also requires an explicit `allowAnonymous` opt-in for a
keyless loopback bind. V1 should generate a per-launch API key and pass it in
the worker environment/arguments; Studio sends it as a Bearer token. Never
use `allowAnonymous` as the normal design, even on loopback.

### Discovery and version handshake

The released server provides `/health` (only `{ "status": "ok" }`) and
`/v1/models`; neither is a sufficient compatibility/version handshake.  Add a
Studio-owned worker endpoint, e.g. `GET /studio/handshake`, before advertising
a worker as ready. **This is blocked on U1's public route-mount seam:** the
released `ManifoldServerKit` facade exposes serving with an injected backend,
not a public way for a consumer to mount additional routes. Do not reach into
internal server classes or claim the endpoint is implementable until U1 lands.
It should report:

```json
{
  "protocolVersion": 1,
  "workerID": "mlx|llama",
  "workerBuild": "…",
  "coreVersion": "0.76.x",
  "companionVersion": "…",
  "capabilities": { "chat": true, "embeddings": false },
  "state": "starting|ready|loading|busy|failed",
  "modelRoots": ["…redacted identifiers…"]
}
```

The worker must reject an incompatible protocol version before receiving a
model path or prompt. Studio should verify its child PID, loopback port, API
key, handshake response, then `/health`; `/v1/models` only proves the current
model inventory.

### Lifecycle, logs, crashes, and hardware serialization

Workers have explicit states: spawned → handshaken → loading → ready/busy →
stopping/failed. The supervising Studio component owns process launch,
termination, restart backoff, and a bounded rotating stderr log file per
worker. It must drain stdout and stderr concurrently; `LlamaRunnerDriver`
documents a real deadlock when verbose llama stderr fills an undrained pipe.

Treat unexpected termination, port loss, or a failed health probe as a failed
worker, retain the last log tail and exit status for the UI, and never restart
while a user-visible generation is still attributed to the dead PID. A normal
shutdown sends cancellation/termination, waits a bounded period, then kills
only its recorded child PID.

Hardware policy is conservative:

- MLX declares `sharesMLXProcessResources: true`; its implementation has a
  process-global resource arbiter and requires serialized in-process Metal
  access. One MLX worker, one active generation/load at a time.
- llama.cpp's released `LlamaBackendProcessLifecycle` initializes once and
  deliberately never calls `llama_backend_free()` until process exit because
  init/free/re-init is undefined. Its natural cleanup boundary is worker exit,
  not a long-lived mixed host.
- The eval package says separate processes are required because of the
  llama once-per-process lifecycle and MLX serialization. V1 additionally
  serializes local workers at the Studio supervisor level to avoid unified
  memory pressure/Metal contention. Remote Ollama/cloud traffic need not hold
  that local-hardware lease.

### Model ownership

Studio should store only user-approved bookmarks/identifiers and pass a
resolved local URL to the selected worker for a load. The worker owns the
open model handle, caches, temporary conversion/download state, load progress,
and `unloadModel()`/process-exit cleanup. Do not share mutable model directories
or a resident backend object across workers. MLX may download an identifier;
v1 should either make that an explicit worker operation with a declared cache
root or require Studio to supply a resolved snapshot. GGUF is a local file
input. The model path must never be exposed through a network-bound listener.

## Backend placement for the demonstration

| Family | V1 placement | Rationale |
| --- | --- | --- |
| MLX | `manifold-studio-mlx-worker` | Separates MLX/Metal and its companion dependency graph from Studio. |
| llama/GGUF | `manifold-studio-llama-worker` | Gives llama.cpp a process-exit lifecycle and avoids linking its xcframework with MLX. |
| Foundation Models | Direct in Studio initially | It is a core family and platform-gated; no native companion conflict is evidenced. A worker is optional later for uniform crash containment. |
| Ollama | Direct in Studio (remote endpoint) | ManifoldKit has a released registrar/backend and the stock server supports it; it is already an external daemon. |
| Cloud SaaS | Direct in Studio (remote endpoint) | `CloudSaaSBackends` is a released registrar, but `manifold-server --backend cloud` is explicitly unsupported, so do not put cloud behind the stock server in v1. |

The direct lanes should continue to use normal ManifoldKit registration:
`FoundationBackends`, `OllamaBackends`, and `CloudSaaSBackends` implement the
released `BackendRegistrar` seam. They do not need to share a process with
local companion workers.

## Rejected alternatives

1. **Link MLX, llama, Foundation, Ollama, and cloud into the Studio daemon/browser process.**
   This creates the exact mixed-family native process the eval topology avoids,
   makes crash recovery impossible, and couples the GUI binary to MLX's Metal
   toolchain and llama's binary xcframework.
2. **Use `ManifoldServer` CLI with `--backend mlx` or `--backend llama`.**
   Released core explicitly reports those families are not compiled into its
   CLI; `--backend cloud` is likewise not implemented.
3. **Use companion registrars to configure the server.**
   The facade documents that registrar and `ServerBackendProvider` extension
   points are disjoint; doing this would silently fail to supply the server.
4. **Invent a general-purpose custom IPC/RPC protocol first.**
   It duplicates released streaming/model HTTP semantics and creates a second
   compatibility surface. Add only the small Studio handshake/control endpoint
   missing from the server, not a replacement data plane.
5. **Allow unrestricted parallel local workers.**
   Separate PIDs do not make unified memory, Metal, thermals, or global native
   lifecycle contention disappear. Start serialized and relax only with
   hardware measurements and explicit upstream guidance.

## Upstream gaps to report (not silently fill with private imports)

- No released companion HTTP-server executable/product for MLX or GGUF.
- No released worker discovery/version/capability handshake; `/health` lacks
  version and `/v1/models` lacks protocol compatibility. Implementing the
  proposed route is specifically blocked on U1's public route-mount seam.
- No public worker lifecycle/control protocol for load progress, unload,
  cancellation attribution, log locations, or model-cache ownership.
- No released cross-process hardware arbiter/lease contract.
- The stock server lacks a cloud backend loader and stock embedding providers;
  the quickstart says `/v1/embeddings` returns 503 until an injected provider
  supplies one.
- Version-pinning ambiguity in Studio's declared companion versions must be
  reconciled against published releases before implementation.

## Issue-ready v1 acceptance criteria

- Two independent SwiftPM worker products exist, each linked to exactly one of
  `ManifoldMLX` or `ManifoldLlama`, plus released `ManifoldServerKit`; each
  consumer manifest enables the dependency `Server` trait per the proven S1
  recipe. The Studio daemon/browser target does not link either companion.
- Each worker implements only public `ServerBackendProvider` APIs, serves
  loopback HTTP with a per-launch bearer key, and passes `/health`, handshake,
  `/v1/models`, and a streamed `/v1/chat/completions` smoke test.
- The handshake rejects incompatible protocol/core/companion tuples and reports
  worker ID, versions, state, and capability truthfully.
- Studio captures bounded worker logs, detects non-zero exit/health loss,
  surfaces the diagnostic, and can restart a failed idle worker without
  relaunching the app.
- At most one MLX/GGUF worker may load or generate at once; the UI explains a
  queued hardware lease. Remote Foundation/Ollama/cloud paths remain usable.
- Model paths/bookmarks are never published over non-loopback networking;
  a worker owns handles/cache and releases them on explicit unload or exit.
- Compatibility is tested against published companion tags, including remotely
  verified MLX `v0.5.2` and llama `v0.4.5`, rather than a branch or local
  package dependency.

## Self-review / rework notes

This recommendation fits the stated goal because it does not pretend a
released, turn-key local server exists: it places a deliberately small host
around the released injection seam. The main remaining product choice is
whether Foundation also belongs behind a worker for browser/daemon uniformity.
V1 keeps it in-process because no incompatible native family is proven there;
revisit only if Foundation failures need independent crash containment. Before
coding, fetch and audit the verified newer companion tags and do a focused
SwiftPM host proof using the S1 dependency-trait recipe. Handshake/control-route
work remains explicitly gated on U1; until then prove only the released HTTP
surface and SSE cancellation.

## Evidence index

- `ManifoldKit@v0.76.0:Package.swift`,
  `Sources/ManifoldServer/{ManifoldServer,ServerBackendProvider,TraitAwareServerBackendProvider,ServerConfiguration}.swift`,
  `Sources/Manifold{Foundation,Ollama,CloudSaaS}/*Backends.swift`, and
  `docs/QUICKSTART-SERVER.md`.
- `manifold-mlx@v0.5.0:Package.swift`,
  `Sources/ManifoldMLX/{MLXBackends,MLXBackend,MLX/MLXResourceArbiter}.swift`,
  and `README.md`.
- `manifold-llama@v0.4.3:Package.swift`,
  `Sources/ManifoldLlama/{LlamaBackends,LlamaBackend,LlamaBackendProcessLifecycle}.swift`,
  and `docs/LLAMA_CONTRACT.md`.
- `manifold-eval@v0.1.4:Package.swift`, `README.md`,
  `Sources/ManifoldEval/Differential/LlamaRunnerDriver.swift`, and
  `Sources/ManifoldEval/Perf/PerfHTTPDriver.swift`.
