#!/usr/bin/env bash
set -euo pipefail

schema_dir="${1:?usage: gen-crd-schemas.sh SCHEMA_DIR MANIFEST_DIR...}"
shift
[ "$#" -gt 0 ] || { echo "usage: gen-crd-schemas.sh SCHEMA_DIR MANIFEST_DIR..." >&2; exit 1; }

# kubeconform reads no OpenAPI extension, so every structural constraint has to survive as plain JSON schema.
normalise='
  (.. | select(tag == "!!map" and has("properties")) | .additionalProperties) |= (. // false)
  | (.. | select(tag == "!!map" and .["x-kubernetes-preserve-unknown-fields"] == true) | .additionalProperties) |= true
  | (.. | select(tag == "!!map" and .format == "int-or-string")) |= {"oneOf": [{"type": "string"}, {"type": "integer"}]}
  | del(.additionalProperties)
'

mkdir -p "$schema_dir"
written=0

while IFS= read -r file; do
  while IFS=$'\t' read -r name group kind versions; do
    [ -n "$versions" ] || continue

    mkdir -p "$schema_dir/$group"
    IFS=$'\t' read -r -a version_names <<< "$versions"

    for version in "${version_names[@]}"; do
      export CRD="$name" VERSION="$version"
      yq -N -o=json '
        select(.kind == "CustomResourceDefinition" and .metadata.name == strenv(CRD))
        | .spec.versions[] | select(.name == strenv(VERSION))
        | .schema.openAPIV3Schema
        | '"$normalise" "$file" > "$schema_dir/$group/${kind}_${version}.json"
      written=$((written + 1))
    done
  done < <(yq -N '
    select(.kind == "CustomResourceDefinition")
    | [
        .metadata.name,
        .spec.group,
        (.spec.names.kind | downcase),
        (.spec.versions[] | select(.schema.openAPIV3Schema != null) | .name)
      ] | join("\t")
  ' "$file")
done < <(grep -rl "kind: CustomResourceDefinition" --include="*.yaml" "$@" | sort -u)

echo "Wrote $written CRD schemas to $schema_dir"
