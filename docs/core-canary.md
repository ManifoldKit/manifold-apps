# ManifoldKit main compatibility canary

`Core compatibility canary` builds this application against a requested
ManifoldKit revision before that revision is accepted as compatible with this
consumer. It is separate from ordinary `ci.yml`: ordinary product builds keep
the published-tag dependency pins in `project.yml`.

## Trigger contract

The workflow is defined in `.github/workflows/core-canary.yml` and its check
identity is **Core compatibility canary / app against requested core**.

Manual runs accept two required Git refs:

- `app_ref`: the application revision to check;
- `core_ref`: the ManifoldKit revision to check.

Core integration uses `repository_dispatch` with event type
`manifoldkit-apps-canary`. Its JSON payload must contain a non-empty
`core_ref` and `app_ref`. Core integration must send the immutable app commit
it intended to test as `app_ref`; it must not rely on a moving branch default.
Both values must be a valid Git ref or commit SHA. Invalid or unavailable refs
fail before a gate can pass. The event payload is parsed as JSON and both refs
must be non-empty strings; non-string, multiline, leading-dash, and malformed
refs fail without being exported into the job environment. The run still
uploads failed terminal metadata for a validation or provisioning error.

GitHub requires the workflow file to exist on the repository's default branch
for `workflow_dispatch` and `repository_dispatch` to trigger it. The `--ref`
argument selects which committed workflow version to run only after that
default-branch requirement is met; before it is merged, reproduce the runner
locally from this branch.

The later core-side checker must treat an app canary as evidence only when the
artifact's resolved `core.commit` equals the core commit it dispatched, its
resolved `app.commit` equals the intended application revision, and `status`
is `passed`. A workflow name or a green run alone is insufficient: stale,
missing, unauthorized, timed-out, or failed dispatches are incompatible
evidence.

## What the workflow runs

The runner first checks out the workflow implementation, then checks out the
requested application and ManifoldKit into separate paths. This lets the
always-running terminal-evidence step record a failure even when an invalid
ref prevents either requested checkout. Evidence storage is initialized before
Xcode selection and XcodeGen installation, so provisioning failures are also
recorded. The runner checks resolved commits, fails if checkout status cannot
be inspected or is dirty, and refuses to replace an existing package or spec
path. The
canary script makes a temporary `ManifoldKit -> core` symlink and renders a
temporary XcodeGen spec whose package declaration is exactly:

```yaml
ManifoldKit:
  path: ManifoldKit
```

It then generates the app project and runs the complete iOS and macOS build
and UI-test targets. Hosted runs use the macOS 26 image, Xcode 26.6, and the
official iPhone 17 / iOS 26.5 simulator; XcodeGen is installed explicitly.
The symlink and spec are removed on both success and failure. DerivedData is
left at Xcode's standard outside-repository location.

Each run uploads `manifold-apps-core-canary-<run id>`, containing
`canary-metadata.json` and any iOS/macOS `.xcresult` bundles. The JSON records
the requested refs, resolved app and core commits, XcodeGen/Xcode versions,
the package identity, destination, exit code, and terminal `passed` or
`failed` status. It contains no token or credential material.

## Reproducing a run

After this workflow has reached the default branch, a maintainer can dispatch a
specific pair and wait for its terminal result:

```sh
gh workflow run core-canary.yml --repo ManifoldKit/manifold-apps --ref main \
  -f app_ref=<exact-app-commit> \
  -f core_ref=<exact-core-commit>
gh run watch --repo ManifoldKit/manifold-apps
```

For an already checked-out app workspace and a separate ManifoldKit checkout,
the same gate is runnable locally:

```sh
bash scripts/run-core-canary.sh \
  --app-root "$PWD" \
  --app-ref "$(git rev-parse HEAD)" \
  --core-path /path/to/ManifoldKit \
  --core-ref "$(git -C /path/to/ManifoldKit rev-parse HEAD)" \
  --metadata-dir /private/tmp/manifold-core-canary \
  --ios-destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

Run `bash scripts/test-core-canary.sh` for offline guard coverage. It proves a
valid fake-tool run, then deliberately makes absent and non-string event refs,
malformed refs, missing core input, a provisioning failure, a build failure,
and a test failure red. A hosted incompatibility proof
uses a known incompatible core revision, observes the failed canary artifact,
then reruns the restored compatible pair and records its passed artifact.
