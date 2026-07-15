#!/usr/bin/env bash
#
# Regenerates the embedded OpenAPI spec Swift sources from the canonical YAML files.
#
# The spec is served straight out of the compiled binary (see OpenAPISpec.swift) rather
# than from a SwiftPM resource bundle, so it works no matter how the executable is installed
# (Homebrew ships a bare binary with no bundle alongside it). Run this after editing any
# Resources/openapi.yaml; CI verifies the committed output matches.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# generate <yaml path> <output swift path>
generate() {
    local yaml="$1"
    local out="$2"

    if [[ ! -f "$yaml" ]]; then
        echo "error: missing $yaml" >&2
        exit 1
    fi

    # Pick the smallest raw-string delimiter whose terminator (""" + hashes) can't appear in
    # the content, so no escaping is ever needed.
    local hashes="#"
    while grep -qF "\"\"\"${hashes}" "$yaml"; do
        hashes="${hashes}#"
    done

    {
        printf '// Generated from %s by scripts/generate-openapi-spec.sh. Do not edit by hand.\n' "${yaml#"${repo_root}"/}"
        printf '// swiftlint:disable:next type_body_length\n'
        printf 'enum OpenAPISpec {\n'
        printf '    static let yaml = %s"""\n' "$hashes"
        # awk '{print}' emits the file verbatim at column 0 with exactly one trailing newline,
        # so the closing delimiter always lands on its own line.
        awk '{print}' "$yaml"
        printf '"""%s\n' "$hashes"
        printf '}\n'
    } > "$out"

    echo "generated ${out#"${repo_root}"/} (delimiter ${hashes}\"\"\")"
}

generate "${repo_root}/Packages/RouterApp/Sources/RouterApp/Resources/openapi.yaml" \
         "${repo_root}/Packages/RouterApp/Sources/RouterApp/Internal/OpenAPISpec.swift"

generate "${repo_root}/Packages/ExecutorApp/Sources/ExecutorApp/Resources/openapi.yaml" \
         "${repo_root}/Packages/ExecutorApp/Sources/ExecutorApp/Internal/OpenAPISpec.swift"
