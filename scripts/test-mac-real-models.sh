#!/usr/bin/env bash
# Runs the opt-in Manifold Mac UI hardware gate with installed models. This is not a
# fixture lane: it intentionally fails before xcodebuild when the local
# prerequisites are absent, rather than reporting a misleading skipped pass.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MLX_MODEL_PATH="${MANIFOLD_MAC_REAL_MLX_MODEL_PATH:-$HOME/Documents/Models/mlx/Qwen3.5-2B-4bit}"
QWEN_MODEL_PATH="${MANIFOLD_MAC_REAL_QWEN_MODEL_PATH:-$HOME/Documents/Models/mlx/Qwen3.5-9B-4bit}"
GGUF_MODEL_PATH="${MANIFOLD_MAC_REAL_GGUF_MODEL_PATH:-$HOME/Documents/Models/gguf/Qwen3.5-2B/Qwen_Qwen3.5-2B-Q4_K_M.gguf}"

fail() {
  printf 'Manifold Mac real-model gate: %s\n' "$*" >&2
  exit 1
}

display_model_name() {
  local path="$1"
  local format="$2"
  local name
  name="$(basename "$path")"
  if [[ "$format" == "gguf" ]]; then
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

[[ "${GGUF_MODEL_PATH##*.}" =~ ^[Gg][Gg][Uu][Ff]$ ]] || fail "expected a .gguf model file: $GGUF_MODEL_PATH"
[[ -f "$GGUF_MODEL_PATH" && -r "$GGUF_MODEL_PATH" ]] || fail "GGUF model is missing or unreadable: $GGUF_MODEL_PATH"
GGUF_MODEL_BYTES="$(stat -f '%z' "$GGUF_MODEL_PATH")" || fail "could not stat GGUF model: $GGUF_MODEL_PATH"
[[ "$GGUF_MODEL_BYTES" =~ ^[0-9]+$ && "$GGUF_MODEL_BYTES" -gt 0 ]] || fail "invalid GGUF model size: $GGUF_MODEL_BYTES"

require_distinct_model_names() {
  local first="$1" second="$2"
  # The UI row lookup matches text case-insensitively, including substrings.
  [[ -n "$first" && -n "$second" && "$first" != *"$second"* && "$second" != *"$first"* ]] ||
    fail "model rows have ambiguous display identities: '$first' and '$second'"
}

MLX_DISPLAY_NAME="$(display_model_name "$MLX_MODEL_PATH" mlx | tr '[:upper:]' '[:lower:]')"
QWEN_DISPLAY_NAME="$(display_model_name "$QWEN_MODEL_PATH" mlx | tr '[:upper:]' '[:lower:]')"
GGUF_DISPLAY_NAME="$(display_model_name "$GGUF_MODEL_PATH" gguf | tr '[:upper:]' '[:lower:]')"
require_distinct_model_names "$MLX_DISPLAY_NAME" "$GGUF_DISPLAY_NAME"
require_distinct_model_names "$MLX_DISPLAY_NAME" "$QWEN_DISPLAY_NAME"
require_distinct_model_names "$QWEN_DISPLAY_NAME" "$GGUF_DISPLAY_NAME"

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

mlx_model_bytes() {
  local path="$1" kind="$2"
  local file_list="$STAGING_ROOT/weights"
  local model_file model_bytes
  local total=0

  [[ -d "$path" && -r "$path" ]] || fail "$kind model directory is missing or unreadable: $path"
  [[ -f "$path/config.json" && -r "$path/config.json" && -s "$path/config.json" ]] ||
    fail "$kind model config.json is missing, empty, or unreadable: $path"
  /usr/bin/find "$path" -type f -name '*.safetensors' -print0 > "$file_list" ||
    fail "could not enumerate $kind model weights: $path"
  while IFS= read -r -d '' model_file; do
    [[ -r "$model_file" && -s "$model_file" ]] || fail "$kind model weight is unreadable or empty: $model_file"
    model_bytes="$(stat -f '%z' "$model_file")" || fail "could not stat $kind model file: $model_file"
    [[ "$model_bytes" =~ ^[0-9]+$ ]] || fail "invalid $kind model file size for $model_file: $model_bytes"
    total=$((total + model_bytes))
  done < "$file_list"
  (( total > 0 )) || fail "$kind model has no readable .safetensors weights: $path"
  printf '%s' "$total"
}

MLX_MODEL_BYTES="$(mlx_model_bytes "$MLX_MODEL_PATH" MLX)"
QWEN_MODEL_BYTES="$(mlx_model_bytes "$QWEN_MODEL_PATH" 'Qwen MLX')"
QWEN_MODEL_TYPE="$(/usr/bin/plutil -extract model_type raw -o - "$QWEN_MODEL_PATH/config.json")" ||
  fail "could not read model_type in Qwen MLX config.json: $QWEN_MODEL_PATH"
[[ "$QWEN_MODEL_TYPE" == "qwen3_5" ]] ||
  fail "expected a Qwen3.5 MLX model, found model_type '$QWEN_MODEL_TYPE': $QWEN_MODEL_PATH"

STAGED_MODELS="$STAGING_ROOT/models"
mkdir "$STAGED_MODELS" || fail "could not create staged model directory: $STAGED_MODELS"
STAGED_MLX_MODEL_PATH="$STAGED_MODELS/$(basename "$MLX_MODEL_PATH")"
STAGED_GGUF_MODEL_PATH="$STAGED_MODELS/$(basename "$GGUF_MODEL_PATH")"
STAGED_QWEN_MODEL_PATH="$STAGED_MODELS/$(basename "$QWEN_MODEL_PATH")"
/bin/cp -cR "$MLX_MODEL_PATH" "$STAGED_MLX_MODEL_PATH" || fail "could not clone MLX model: $STAGED_MLX_MODEL_PATH"
/bin/cp -cR "$QWEN_MODEL_PATH" "$STAGED_QWEN_MODEL_PATH" || fail "could not clone Qwen MLX model: $STAGED_QWEN_MODEL_PATH"
/bin/cp -c "$GGUF_MODEL_PATH" "$STAGED_GGUF_MODEL_PATH" || fail "could not clone GGUF model: $STAGED_GGUF_MODEL_PATH"
[[ -d "$STAGED_MLX_MODEL_PATH" && -r "$STAGED_MLX_MODEL_PATH" ]] || fail "staged MLX model is missing or unreadable: $STAGED_MLX_MODEL_PATH"
[[ -d "$STAGED_QWEN_MODEL_PATH" && -r "$STAGED_QWEN_MODEL_PATH" ]] || fail "staged Qwen MLX model is missing or unreadable: $STAGED_QWEN_MODEL_PATH"
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
MANIFOLD_MAC_REAL_QWEN_MODEL_PATH="$STAGED_QWEN_MODEL_PATH" \
MANIFOLD_MAC_REAL_QWEN_MODEL_BYTES="$QWEN_MODEL_BYTES" \
xcodebuild test \
  -project Manifold.xcodeproj \
  -scheme ManifoldMac \
  -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation \
  MANIFOLD_MAC_REAL_MODEL_TEST=1 \
  MANIFOLD_MAC_REAL_MLX_MODEL_PATH="$STAGED_MLX_MODEL_PATH" \
  MANIFOLD_MAC_REAL_GGUF_MODEL_PATH="$STAGED_GGUF_MODEL_PATH" \
  MANIFOLD_MAC_REAL_MLX_MODEL_BYTES="$MLX_MODEL_BYTES" \
  MANIFOLD_MAC_REAL_GGUF_MODEL_BYTES="$GGUF_MODEL_BYTES" \
  MANIFOLD_MAC_REAL_QWEN_MODEL_PATH="$STAGED_QWEN_MODEL_PATH" \
  MANIFOLD_MAC_REAL_QWEN_MODEL_BYTES="$QWEN_MODEL_BYTES"
