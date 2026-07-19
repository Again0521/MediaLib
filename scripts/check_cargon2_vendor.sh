#!/usr/bin/env bash
set -euo pipefail

root="${1:-.}"
if [[ ! -d "${root}" ]]; then
    echo "::error::CArgon2 vendor check root does not exist: ${root}" >&2
    exit 2
fi

root="$(cd "${root}" && pwd -P)"

required_files=(
    "Sources/CArgon2/argon2.c"
    "Sources/CArgon2/core.c"
    "Sources/CArgon2/encoding.c"
    "Sources/CArgon2/ref.c"
    "Sources/CArgon2/thread.c"
    "Sources/CArgon2/medialib_crypto.c"
    "Sources/CArgon2/blake2/blake2b.c"
    "Sources/CArgon2/include/argon2.h"
    "Sources/CArgon2/include/medialib_crypto.h"
    "Sources/CArgon2/include/module.modulemap"
)

missing=0
for file in "${required_files[@]}"; do
    if [[ ! -f "${root}/${file}" ]]; then
        echo "::error file=${file}::Missing vendored CArgon2 file required by Package.swift." >&2
        missing=1
    fi
done

if [[ "${missing}" -ne 0 ]]; then
    echo "CArgon2 vendor files are incomplete; restore Sources/CArgon2 before building." >&2
    exit 1
fi

if ! grep -q 'name: "CArgon2"' "${root}/Package.swift"; then
    echo "::error file=Package.swift::Package.swift must declare the CArgon2 target." >&2
    exit 1
fi

if ! grep -q '"CArgon2"' "${root}/Package.swift"; then
    echo "::error file=Package.swift::MediaLibCore must depend on CArgon2." >&2
    exit 1
fi
