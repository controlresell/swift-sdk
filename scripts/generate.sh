#!/usr/bin/env bash
# Regenerates the client from the OpenAPI document of the ControlResell public API.
#
#   scripts/generate.sh [spec]   # a file or a URL; default: https://api.controlresell.com/api/public/openapi.json
#
# apple/swift-openapi-generator (version pinned below) is built from its tag into .generator/ (ignored by git), and its
# CLI writes Sources/ControlResell/Generated/{Types,Client}.swift, committed so the code reads in git (no build plugin).
# The script writes .spec-sha256; the document itself is not committed.
set -euo pipefail

GENERATOR_VERSION=1.14.3
SPEC="${1:-https://api.controlresell.com/api/public/openapi.json}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GENERATOR_DIR="$ROOT/.generator/swift-openapi-generator-$GENERATOR_VERSION"
if [ ! -x "$GENERATOR_DIR/.build/release/swift-openapi-generator" ]; then
  mkdir -p "$ROOT/.generator"
  rm -rf "$GENERATOR_DIR"
  git clone -q --depth 1 --branch "$GENERATOR_VERSION" https://github.com/apple/swift-openapi-generator.git "$GENERATOR_DIR"
  (cd "$GENERATOR_DIR" && swift build -c release --product swift-openapi-generator)
fi

case "$SPEC" in
  http://*|https://*) curl -fsSL -o "$WORK/openapi.json" "$SPEC" ;;
  *) cp "$SPEC" "$WORK/openapi.json" ;;
esac

SHA="$(shasum -a 256 "$WORK/openapi.json" | cut -d' ' -f1)"

# swift-openapi-generator drops a property typed `anyOf: [{$ref: X}, {type: "null"}]` (OpenAPI 3.1 nullable reference: the
# amounts `estimatedPrice`, `purchasePrice`, `sellingPrice`... would disappear from Item and Order). The script rewrites it to
# the plain `$ref` and removes the property from `required`: the generated type is then `Money?`, and a JSON null reads as nil.
# It also removes the `Idempotency-Key` header parameter of the writes: ControlResellMiddleware sets that header (the same key on
# every retry of a call), so it is not asked of the caller on each write (`IdempotencyKey.with(_:)` chooses it).
python3 -I - "$WORK/openapi.json" <<'PY'
import json, sys

def nullable_ref(schema):
    if isinstance(schema, dict) and isinstance(schema.get("anyOf"), list) and len(schema["anyOf"]) == 2:
        refs = [x for x in schema["anyOf"] if isinstance(x, dict) and "$ref" in x]
        nulls = [x for x in schema["anyOf"] if isinstance(x, dict) and x.get("type") == "null"]
        if len(refs) == 1 and len(nulls) == 1:
            return refs[0]
    return None

def fix(node):
    if isinstance(node, dict):
        properties = node.get("properties")
        if isinstance(properties, dict):
            for name, schema in list(properties.items()):
                ref = nullable_ref(schema)
                if ref is not None:
                    properties[name] = ref
                    if isinstance(node.get("required"), list) and name in node["required"]:
                        node["required"].remove(name)
        parameters = node.get("parameters")
        if isinstance(parameters, list):
            node["parameters"] = [
                p for p in parameters
                if not (isinstance(p, dict) and p.get("in") == "header" and p.get("name") == "Idempotency-Key")
            ]
        for value in node.values():
            fix(value)
    elif isinstance(node, list):
        for value in node:
            fix(value)

path = sys.argv[1]
with open(path) as f:
    spec = json.load(f)
fix(spec)
with open(path, "w") as f:
    json.dump(spec, f)
PY

TARGET="$ROOT/Sources/ControlResell/Generated"
rm -rf "$TARGET"
mkdir -p "$TARGET"
"$GENERATOR_DIR/.build/release/swift-openapi-generator" generate "$WORK/openapi.json" \
  --config "$ROOT/openapi-generator-config.yaml" \
  --output-directory "$TARGET" \
  --mode types --mode client

echo "$SHA" > "$ROOT/.spec-sha256"
echo "Generated from $SPEC (sha256 $(cat "$ROOT/.spec-sha256"))"
