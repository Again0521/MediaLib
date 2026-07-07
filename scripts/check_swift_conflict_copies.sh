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

is_conflict_copy() {
    local filename="$1"
    case "${filename}" in
        *" "[0-9].swift|*" "[0-9][0-9].swift|*" "[0-9][0-9][0-9].swift)
            return 0
            ;;
        *" copy.swift"|*" Copy.swift"|*" conflicted copy"*.swift|*" conflicted-copy"*.swift)
            return 0
            ;;
    esac
    return 1
}

found=0
while IFS= read -r -d '' file; do
    filename="$(basename "${file}")"
    if is_conflict_copy "${filename}"; then
        relative="${file#${root}/}"
        echo "::error file=${relative}::Accidental Swift conflict copy detected. Remove this duplicate before building; SwiftPM compiles every .swift file under Sources and Tests." >&2
        found=1
    fi
done < <(find "${scan_roots[@]}" -type f -name '*.swift' -print0)

if [[ "${found}" -ne 0 ]]; then
    echo "Detected Swift source conflict copies. Delete the duplicate files instead of keeping them under Sources or Tests." >&2
    exit 1
fi
