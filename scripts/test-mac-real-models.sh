#!/usr/bin/env bash
# Runs the opt-in Manifold Mac MLX -> GGUF -> MLX UI hardware gate. This is not a
# fixture lane: it intentionally fails before xcodebuild when the local
# prerequisites are absent, rather than reporting a misleading skipped pass.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MLX_MODEL_PATH="${MANIFOLD_MAC_REAL_MLX_MODEL_PATH:-$HOME/Documents/Models/mlx/Qwen3.5-2B-4bit}"
GGUF_MODEL_PATH="${MANIFOLD_MAC_REAL_GGUF_MODEL_PATH:-$HOME/Documents/Models/gguf/Qwen3.5-2B/Qwen_Qwen3.5-2B-Q4_K_M.gguf}"

fail() {
  printf 'Manifold Mac real-model gate: %s\n' "$*" >&2
  exit 1
}

display_model_name() {
  local path="$1"
  local name="$(basename "$path")"
  local extension="$(printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$extension" == "gguf" ]]; then
    name="${name%.*}"
  fi
  name="${name//-/ }"
  name="${name//_/ }"
  printf '%s' "$name"
}

[[ -z "${CI:-}" ]] || fail "is a physical-model hardware gate and must not be run in CI."
[[ "$(uname -m)" == "arm64" ]] || fail "requires an arm64 Mac; this host is $(uname -m)."
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is unavailable; install full Xcode."

# Xcode's package build plugins compile and bundle the companion metallibs in
# the application. A standalone `metal`/`metallib` lookup is therefore not a
# prerequisite for this app-level gate (and is absent on some valid Xcode
# installations). The xcodebuild below remains the authoritative toolchain
# and resource-load check.

[[ -d "$MLX_MODEL_PATH" && -r "$MLX_MODEL_PATH" ]] || fail "MLX model directory is missing or unreadable: $MLX_MODEL_PATH"
[[ -r "$MLX_MODEL_PATH/config.json" ]] || fail "MLX model config.json is missing or unreadable: $MLX_MODEL_PATH/config.json"

has_readable_safetensors=0
while IFS= read -r -d '' model_file; do
  if [[ -r "$model_file" ]]; then
    has_readable_safetensors=1
    break
  fi
done < <(/usr/bin/find "$MLX_MODEL_PATH" -type f -name '*.safetensors' -print0)
(( has_readable_safetensors == 1 )) || fail "MLX model has no readable .safetensors weights: $MLX_MODEL_PATH"

[[ -f "$GGUF_MODEL_PATH" && -r "$GGUF_MODEL_PATH" ]] || fail "GGUF model is missing or unreadable: $GGUF_MODEL_PATH"

MLX_DISPLAY_NAME="$(display_model_name "$MLX_MODEL_PATH" | tr '[:upper:]' '[:lower:]')"
GGUF_DISPLAY_NAME="$(display_model_name "$GGUF_MODEL_PATH" | tr '[:upper:]' '[:lower:]')"
[[ "$MLX_DISPLAY_NAME" != "$GGUF_DISPLAY_NAME" ]] || fail "MLX and GGUF model rows collide on display identity: '$MLX_DISPLAY_NAME'"

MLX_MODEL_BYTES=0
while IFS= read -r -d '' model_file; do
  model_bytes="$(stat -f '%z' "$model_file")" || fail "could not stat MLX model file: $model_file"
  [[ "$model_bytes" =~ ^[0-9]+$ ]] || fail "invalid MLX model file size for $model_file: $model_bytes"
  MLX_MODEL_BYTES=$((MLX_MODEL_BYTES + model_bytes))
done < <(/usr/bin/find "$MLX_MODEL_PATH" -type f -name '*.safetensors' -perm -u+r -print0)
(( MLX_MODEL_BYTES > 0 )) || fail "MLX model weights have zero total size: $MLX_MODEL_PATH"

GGUF_MODEL_BYTES="$(stat -f '%z' "$GGUF_MODEL_PATH")" || fail "could not stat GGUF model: $GGUF_MODEL_PATH"
[[ "$GGUF_MODEL_BYTES" =~ ^[0-9]+$ && "$GGUF_MODEL_BYTES" -gt 0 ]] || fail "invalid GGUF model size: $GGUF_MODEL_BYTES"

# The UI-test app has its own TCC boundary. Stage clone-on-write copies into a
# uniquely named temporary directory so the real backend opens paths that are
# directly accessible to the launched app without duplicating the model data.
STAGING_ROOT="$(mktemp -d /private/tmp/manifold-mac-real-models.XXXXXX)" || fail "could not create the real-model staging directory"
cleanup_staging() {
  case "$STAGING_ROOT" in
    /private/tmp/manifold-mac-real-models.*)
      /bin/rm -rf -- "$STAGING_ROOT"
      ;;
    *)
      printf 'Manifold Mac real-model gate: refusing to remove unexpected staging path: %s\n' "$STAGING_ROOT" >&2
      return 1
      ;;
  esac
}
trap cleanup_staging EXIT

STAGED_MLX_MODEL_PATH="$STAGING_ROOT/$(basename "$MLX_MODEL_PATH")"
STAGED_GGUF_MODEL_PATH="$STAGING_ROOT/$(basename "$GGUF_MODEL_PATH")"
/bin/cp -cR "$MLX_MODEL_PATH" "$STAGING_ROOT/" || fail "could not clone MLX model into staging: $STAGING_ROOT"
/bin/cp -c "$GGUF_MODEL_PATH" "$STAGING_ROOT/" || fail "could not clone GGUF model into staging: $STAGING_ROOT"
[[ -d "$STAGED_MLX_MODEL_PATH" && -r "$STAGED_MLX_MODEL_PATH" ]] || fail "staged MLX model is missing or unreadable: $STAGED_MLX_MODEL_PATH"
[[ -f "$STAGED_GGUF_MODEL_PATH" && -r "$STAGED_GGUF_MODEL_PATH" ]] || fail "staged GGUF model is missing or unreadable: $STAGED_GGUF_MODEL_PATH"

cd "$REPO_ROOT"
if ! xcodegen generate; then
  fail "XcodeGen failed to generate Manifold.xcodeproj."
fi
MANIFOLD_MAC_REAL_MODEL_TEST=1 \
MANIFOLD_MAC_REAL_MLX_MODEL_PATH="$STAGED_MLX_MODEL_PATH" \
MANIFOLD_MAC_REAL_GGUF_MODEL_PATH="$STAGED_GGUF_MODEL_PATH" \
MANIFOLD_MAC_REAL_MLX_MODEL_BYTES="$MLX_MODEL_BYTES" \
MANIFOLD_MAC_REAL_GGUF_MODEL_BYTES="$GGUF_MODEL_BYTES" \
xcodebuild test \
  -project Manifold.xcodeproj \
  -scheme ManifoldMac \
  -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation \
  MANIFOLD_MAC_REAL_MODEL_TEST=1 \
  MANIFOLD_MAC_REAL_MLX_MODEL_PATH="$STAGED_MLX_MODEL_PATH" \
  MANIFOLD_MAC_REAL_GGUF_MODEL_PATH="$STAGED_GGUF_MODEL_PATH" \
  MANIFOLD_MAC_REAL_MLX_MODEL_BYTES="$MLX_MODEL_BYTES" \
  MANIFOLD_MAC_REAL_GGUF_MODEL_BYTES="$GGUF_MODEL_BYTES"
