#!/usr/bin/env bash
set -euo pipefail

root="${1:-.}"
if [[ ! -d "${root}" ]]; then
    echo "::error::Swift conflict-copy guard root does not exist: ${root}" >&2
    exit 2
fi

root="$(cd "${root}" && pwd -P)"
scan_roots=()
for directory in Sources Tests; do
    if [[ -d "${root}/${directory}" ]]; then
        scan_roots+=("${root}/${directory}")
    fi
done

if [[ ${#scan_roots[@]} -eq 0 ]]; then
    exit 0
fi

scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/medialib-swift-source-guard.XXXXXX")"
trap 'rm -rf "${scratch_directory}"' EXIT
source_inventory="${scratch_directory}/swift-sources.tsv"
: > "${source_inventory}"

is_conflict_copy() {
    local filename="$1"
    if [[ "${filename}" == *".sync-conflict-"*.swift ]]; then
        return 0
    fi
    if [[ "${filename}" =~ \ [0-9]+\.swift$ ]]; then
        return 0
    fi
    shopt -s nocasematch
    if [[ "${filename}" =~ \ (copy|conflicted[[:space:]-]copy)(\ [0-9]+)?\.swift$ ]]; then
        shopt -u nocasematch
        return 0
    fi
    shopt -u nocasematch
    return 1
}

found=0
while IFS= read -r -d '' file; do
    relative="${file#${root}/}"
    filename="$(basename "${file}")"
    if is_conflict_copy "${filename}"; then
        echo "::error file=${relative}::Accidental Swift conflict copy detected. Remove this duplicate before building; SwiftPM compiles every .swift file under Sources and Tests." >&2
        found=1
    fi

    target_kind="${relative%%/*}"
    target_remainder="${relative#*/}"
    target_name="${target_remainder%%/*}"
    target_path="${target_kind}/${target_name}"
    printf '%s\t%s\t%s\n' "${target_path}" "${filename}" "${relative}" >> "${source_inventory}"
done < <(find "${scan_roots[@]}" -type f -name '*.swift' -print0)

LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k3,3 "${source_inventory}" > "${source_inventory}.sorted"
if ! awk -F '\t' '
    function report_group(    path_index) {
        if (path_count < 2) {
            return
        }
        for (path_index = 1; path_index <= path_count; path_index++) {
            printf "::error file=%s::Duplicate Swift basename in target %s: %s. Every Swift source basename must be unique within a target.\n", paths[path_index], group_target, group_basename > "/dev/stderr"
        }
        duplicate_found = 1
    }
    {
        key = $1 SUBSEP $2
        if (NR > 1 && key != group_key) {
            report_group()
            delete paths
            path_count = 0
        }
        group_key = key
        group_target = $1
        group_basename = $2
        paths[++path_count] = $3
    }
    END {
        report_group()
        exit duplicate_found ? 1 : 0
    }
' "${source_inventory}.sorted"; then
    found=1
fi

if [[ "${found}" -ne 0 ]]; then
    echo "Detected ambiguous Swift sources. Remove or rename them instead of relying on manifest exclusions." >&2
    exit 1
fi
