# Studio control-plane contract spike

**Status:** proposed boundary; no production implementation implied
**Scope:** Studio's SwiftPM daemon and browser workbench, against released
ManifoldKit **v0.76.0** (`a5c013d3fceb7ccdc9dde0d34236846019e61cba`).

## Decision

Keep inference and control separate:

* **Inference remains exactly OpenAI-compatible.** Studio calls the existing
  `/v1/models`, `/v1/chat/completions`, and `/v1/embeddings` routes. In
  particular, it must not add fields, events, or terminal markers to chat
  completion SSE; `[DONE]` and all existing chunk/error behaviour remain the
  ManifoldServer contract.
* **Control is a Studio-owned, versioned JSON API** under `/studio/v1`.
  Its event feed is a distinct SSE media type and schema. It is for observing
  and requesting *control* actions, never token delivery.
* **ManifoldKit owns portable runtime facts and safe primitives; Studio owns
  only orchestration records.** That puts backend/model inspection, lifecycle
  state and capability truth below the product boundary. Studio may retain a
  queue, launch record and artifact *references*, but an independent evaluator
  owns its assurance attention state, diagnostics and artifacts.

This is deliberately not an attempt to make ManifoldServer's current
internals public. The released surface does not support that safely.

## Evidence from the released public surface

| Released source (v0.76.0) | Public fact | Contract consequence |
| --- | --- | --- |
| `Package.swift`, products `ManifoldServerKit` and `ManifoldAppEval` | The server embedding library and app-eval harness are published, separately imported products. | `ManifoldAppEval` is useful for in-process developer golden-scenario self-checks only; it is not a server-control or independent-assurance API. |
| `Sources/ManifoldServer/ManifoldServer.swift`, `ManifoldServer.serve(configuration:backendProvider:)` | The supported embedded-server entry point; it runs until its enclosing task is cancelled. | Daemon lifetime can use this public entry point. It does not expose the constructed `ServerApp`. |
| `Sources/ManifoldServer/ServerBackendProvider.swift`, `ServerBackendProvider` | Provider can list models/records, resolve a backend for a request, and optionally resolve embeddings. | `/v1/models` is the only current public inventory seam; it contains no capabilities, identity, lifecycle or events. |
| `Sources/ManifoldServer/ServerApp.swift`, `makeApplication()` | Routes are `/health`, `/v1/models`, `/v1/chat/completions`, `/v1/embeddings`, plus optional `/metrics`; `ServerApp` and health are internal. | There is no released `/studio` route or public extension point to install one. Do not reach into it. |
| `Sources/ManifoldContract/InferenceBackend.swift`, `InferenceBackend` | Public `isModelLoaded`, `isGenerating`, `capabilities`, `manifest`, `loadModel`, `stopGeneration`, `unloadModel`, `resetConversation`, and `secureWipe`. | These are the raw generic facts/actions that a *new explicit* control-provider seam can surface. They are not an HTTP contract by themselves. |
| `Sources/ManifoldHardware/BackendCapabilities.swift`, `BackendCapabilities` | Codable capability truth: streaming, tools, structured output, vision/audio, limits, cancellation style, sampler parameters and more. | Encode a stable selected subset first; do not make Studio reverse-engineer UI state. |
| `Sources/ManifoldInference/Services/ModelLifecycleCoordinator.swift` | Lifecycle coordinator is internal (`@MainActor`) despite its detailed load/unload logic. | Studio cannot use it as a public remote lifecycle controller. |
| `Sources/ManifoldAppEval` and `docs/APP-EVAL.md` | `ManifoldAppEval` is a deterministic in-process golden-scenario harness. | It may demonstrate or self-check an app integration, but cannot substitute for the independent `manifold-eval` authority. |

Two safety constraints in that evidence are decisive. `stopGeneration()` is
backend-wide, not request-scoped; ManifoldServer itself avoids calling it for
a timed-out request when `parallelSlots > 1`. Also,
`CancellableModelLoading` is documented in
`BackendOptInProtocols.swift` as a **planned, not-yet-wired** seam with only a
test-support conformer. Neither may be advertised as reliable job
cancellation.

## `/studio/v1` transport contract

The daemon serves all endpoints below. JSON uses UTF-8
`application/json`; field names are `snake_case`; identifiers are opaque
strings. Timestamps are RFC 3339 UTC strings. Unknown object fields and
unknown capability keys must be ignored by clients. Requests carrying an
unknown *required* enum value fail with `invalid_request`.

Every successful response has this envelope:

```json
{
  "api_version": "1.0",
  "request_id": "req_01J...",
  "data": {}
}
```

Every non-2xx response has the same `api_version` and `request_id`, plus:

```json
{
  "error": {
    "code": "unsupported_capability",
    "message": "Backend local-llama does not support model lifecycle control.",
    "target": "backend:local-llama",
    "retryable": false,
    "details": {"capability": "model_lifecycle"}
  }
}
```

`api_version` is the negotiated major/minor: clients send
`Accept: application/vnd.manifold.studio+json;version=1` (plain
`application/json` means v1 during the v1 lifetime). The server returns
`Studio-API-Version: 1.0`. An unsupported major returns HTTP 406 with
`version_mismatch`, `details.supported: ["1"]`. A newer minor is tolerated
because additions are optional. `GET /studio/v1/capabilities` is always the
first browser request after identity.

### Read resources

| Endpoint | Minimal `data` | Ownership |
| --- | --- | --- |
| `GET /studio/v1/server` | `server_id`, `display_name`, `manifoldkit_version`, `started_at`, `inference_base_url`, `auth`, `control_api` | Generic source facts; Studio presentation names/configuration. |
| `GET /studio/v1/capabilities` | `features` map, `limits`, `event_stream` availability | Generic capability vocabulary; Studio decides which optional features it implements. |
| `GET /studio/v1/backends` | array of `{id, kind, status, model_id?, capabilities, lifecycle}` | Generic runtime inspection snapshot. |
| `GET /studio/v1/backends/{id}` | above plus `manifest?`, `loaded`, `generating`, and conservative diagnostics | Generic runtime inspection snapshot. Never expose credentials, filesystem paths, raw prompts, or backend object types. |
| `GET /studio/v1/models` | models known to the daemon, each with `id`, `backend_id`, `availability`, `current` and optional manifest summary | Studio's cross-backend view may enrich the current `/v1/models` inventory, but inference clients still use `/v1/models`. |

`capabilities.features` is a map, rather than a guessed server version:

```json
{
  "runtime_inspection": true,
  "model_lifecycle": false,
  "event_stream": true,
  "external_evaluator_jobs": true,
  "artifact_download": true,
  "request_cancellation": false
}
```

For v1, a backend's portable `capabilities` projects only the stable
`BackendCapabilities` values relevant to a remote controller: `streaming`,
`tool_calling`, `structured_output`, `vision`, `audio_input`,
`max_context_tokens`, `max_output_tokens`, `cancellation_style`, and
`model_lifecycle`. New backend capability fields are additive. `model_lifecycle`
is **not** inferred from `isModelLoaded`; it is true only when the daemon has
a safe generic controller for that backend.

### Lifecycle request (optional capability)

`POST /studio/v1/backends/{id}/operations` accepts one idempotency-keyed
request:

```json
{"operation":"load_model","model_id":"model:acme/7b","idempotency_key":"op_01J..."}
```

Supported operations are `load_model`, `unload_model`, and `reset`. A success
is `202 Accepted` with an operation resource:

```json
{"api_version":"1.0","request_id":"req_...","data":{"id":"op_...","state":"queued","backend_id":"local-llama"}}
```

`GET /studio/v1/operations/{id}` reports `queued | running | succeeded |
failed | cancelled`, timestamps and a sanitized error. `DELETE` requests
cancellation and returns `202`; it must never claim cancellation succeeded
until a subsequent terminal event/status says `cancelled`. If an implementation
cannot safely cancel a native load, it returns `unsupported_capability` rather
than abandoning a mutable backend. The current v0.76.0 public surface means
Studio should initially advertise `model_lifecycle: false` unless/until the
generic seam below lands.

### Events

`GET /studio/v1/events` is an authenticated SSE stream, separate from
OpenAI inference SSE. It emits `id`, `event`, and JSON `data`; reconnect uses
`Last-Event-ID`. Events are ordered per daemon and may be replayed from a
bounded retained window. If the cursor is too old, respond `409
event_cursor_expired` and require the browser to re-fetch snapshots.

V1 event names are `server.changed`, `backend.changed`, `operation.changed`,
`evaluator_job.changed`, and `evaluator_artifact.available`. Every payload has
`event_id`, `occurred_at`, `resource_type`, `resource_id`, and a current
resource snapshot or `{ "state": ... }` patch. The event stream is for
invalidation/progress, not an event-sourced database; clients must recover by
GET after a reconnect.

## Evaluation: two deliberately separate concepts

### Developer self-checks: `ManifoldAppEval`

`ManifoldAppEval` golden application scenarios are in-process, deterministic
developer demos/self-checks. They may run in a Studio development build, but
they are not submitted as evaluator jobs, do not produce assurance evidence,
and do not appear in the external-evaluator resource collection below. If
shown in a browser, label their output `developer_self_check` and never
`evaluation`, `assurance`, or `verdict`.

### Independent assurance: external `manifold-eval`

`manifold-eval` remains the independent external authority. Studio creates an
**orchestration reference**, launches a compatible evaluator executable, and
then preserves (rather than parses into a Studio result) the evaluator-owned
attention state, diagnostics, artifact set and attention grammar.

The minimal resources are:

* `POST/GET /studio/v1/evaluator-jobs` and
  `GET /studio/v1/evaluator-jobs/{id}` for a Studio launch record only:
  `id`, `state`, `manifest_ref`, executable compatibility, timestamps and
  evaluator-provided reference links. States are `queued | launching |
  running | finished | failed | cancellation_requested`; `finished` is not a
  Studio verdict.
* `DELETE /studio/v1/evaluator-jobs/{id}` requests cancellation of the
  launched process. It has the same non-final semantics as lifecycle
  cancellation and does not alter evaluator evidence.
* `GET /studio/v1/evaluator-jobs/{id}/artifacts` and
  `GET /studio/v1/evaluator-artifacts/{id}` return opaque evaluator-owned
  artifact references and metadata. Artifact bytes and their interpretation
  remain evaluator-controlled; neither is embedded in Studio SSE.

The planned **versioned evaluator manifest** is a prerequisite for `POST`.
Studio stores and passes it through unchanged, checking only compatibility:
`manifest_schema_version`, evaluator executable/version requirement, run ID,
input references and requested output location. The evaluator defines all
attention/diagnostic/result fields and their grammar. Studio must not invent
an `eval_result`, map attention states to a boolean, or recalculate an
assurance verdict. The job record may cite manifest and artifact digests for
provenance, but it does not absorb their contents.

## Ownership and the required upstream seam

| ManifoldKit must own (portable) | Studio must own (product orchestration) |
| --- | --- |
| `ServerIdentity`/version and a stable, sanitized `RuntimeCapabilities` vocabulary | `/studio/v1` route mounting, browser assets, auth policy and daemon configuration |
| Read-only backend/model status projection from a provider that owns the runtime | Operation IDs, idempotency store, scheduling, retained event log and progress fan-out |
| A safe lifecycle-controller protocol with declared operations and status, not a leaked backend instance | Launch records, compatibility checks, process supervision and references to external evaluator manifests/artifacts |
| Per-operation cancellation semantics that state whether cancellation is supported, requested and settled | Cross-job cancellation policy and UI workflow |
| Capability/error vocabulary shared by hosts | Studio-specific HTTP envelope, error rendering and migrations |

Proposed generic additions, before Studio exposes lifecycle controls:

1. Add a public `ServerRuntimeControlProvider` (or similarly narrow module
   seam) alongside `ServerBackendProvider`. It supplies sanitized server
   identity, backend/model snapshots and optional lifecycle operations. It
   must own concurrency/serialization; it must never hand arbitrary
   `InferenceBackend` objects to HTTP code.
2. Define `RuntimeBackendSnapshot`, `RuntimeModelSnapshot`,
   `RuntimeOperation` and `RuntimeOperationStatus` as `Sendable`/`Codable`
   value types with stable IDs and capability flags. Project
   `BackendCapabilities` explicitly, not by reflecting the Swift type.
3. Add a lifecycle/cancellation contract only when it can report settled
   outcome. The existing `stopGeneration()` remains backend-wide and cannot
   represent cancellation of an individual Studio job; the inert
   `CancellableModelLoading` protocol is insufficient.
4. Keep the generic seam transport-free. ManifoldServer may later offer an
   opt-in generic control router, but Studio can own `/studio/v1` while the
   seam matures. No private `ServerApp` access, no `@testable`, no reflection.

## Auth and error policy

Use the existing server bearer-token posture as the placeholder: control must
require authentication whenever inference requires it, and it must not make a
keyless/non-loopback bind possible. v0.76.0's `ServerConfiguration` already
refuses a keyless non-loopback bind and requires explicit
`allowAnonymous` for loopback. Future auth may use session/browser tokens,
but authorization is capability-based: read, lifecycle, external-evaluator
launch, and evaluator-artifact-read are distinct permissions.

V1 stable error codes are `unauthenticated` (401), `forbidden` (403),
`not_found` (404), `version_mismatch` (406), `invalid_request` (400),
`unsupported_capability` (409), `conflict` (409),
`event_cursor_expired` (409), `rate_limited` (429), and `internal` (500).
Errors must not expose API keys, local model paths, raw provider responses,
or prompts. Existing OpenAI inference error envelopes and status mapping are
unchanged and are deliberately not reused as the control wire schema.

## Contract fixtures (implementation gate)

Fixtures should be JSON files shared by daemon and browser contract tests:

* `server.v1.json`: identity plus `manifoldkit_version: "0.76.0"` and an
  inference URL; assert no secret fields.
* `capabilities.v1.json`: inspection/events/external-evaluator jobs true, lifecycle and
  request-cancellation false. Browser hides disabled controls.
* `backend-loaded.v1.json` and `backend-unavailable.v1.json`: include both a
  manifest-present and manifest-absent backend; ensure unknown optional
  capabilities are ignored.
* `operation-load-success.v1.json`, `operation-unsupported.v1.json`, and
  `operation-cancel-requested.v1.json`: assert cancellation is not reported
  as final until settled.
* `developer-self-check.v1.json`: if surfaced at all, is visibly labelled as
  a `ManifoldAppEval` developer self-check and contains no assurance claim.
* `evaluator-job-finished.v1.json`: contains a launch record, manifest digest
  and opaque evaluator references, but no Studio verdict/result or parsed
  attention state.
* `evaluator-manifest-v1.json`: pins the pass-through versioned manifest
  wrapper and executable compatibility check.
* `evaluator-artifact-reference.v1.json`: preserves opaque artifact metadata
  and provenance without embedding or reinterpreting diagnostics/content.
* `event-backend-changed.sse` and `event-cursor-expired.json`: exercise
  resume/reconcile behaviour.
* `error-version-mismatch.v1.json` and
  `error-unsupported-capability.v1.json`: pin envelope/status/code.
* Existing ManifoldServer chat-completion streaming fixtures: run byte-for-byte
  unchanged, including terminal `[DONE]`, to prove this work has not altered
  OpenAI SSE.

## Issue-ready acceptance criteria

* A Studio daemon can return the v1 server and capability snapshots without
  importing internal ManifoldServer types or exposing secrets.
* Browser controls are driven solely by declared capabilities; unsupported
  lifecycle/cancellation is visible and non-actionable.
* Every operation/external-evaluator launch has an opaque ID, idempotency
  semantics, terminal state, and reconcilable event/snapshot path.
* A cancelled load/generation is never claimed cancelled until the runtime has
  settled; v0.76.0's backend-wide `stopGeneration()` is not used as a
  per-job cancellation surrogate.
* The versioned evaluator manifest passes from Studio to a compatible
  `manifold-eval` executable unchanged. Studio preserves evaluator-owned
  artifacts, diagnostics and attention grammar as opaque references and makes
  no assurance verdict or derived `eval_result` claim.
* `ManifoldAppEval` is either absent from the browser contract or visibly
  labelled a developer self-check, never conflated with independent assurance.
* The existing OpenAI-compatible inference endpoints and their SSE bytes pass
  their existing contract fixtures unchanged.
* The generic upstream seam compiles as a public consumer API and has a
  provider-contract test covering missing optional lifecycle support,
  capability projection, and safe cancellation reporting.

## Self-review / rework triggers

This spike intentionally stops before choosing a router library, persistence
store, event-retention size, or auth provider. Rework it if a released
ManifoldKit version adds a public runtime-control provider, changes the
`InferenceBackend` cancellation model, or exposes a supported server route
mounting API. Until then, implementing lifecycle routes would require private
hooks and violates this boundary; read-only Studio views should use only an
explicit new public seam or the existing OpenAI model list.
