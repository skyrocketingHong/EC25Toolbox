#!/bin/zsh

set -euo pipefail
setopt null_glob

ROOT_DIR="${0:A:h:h}"
LPAC_ROOT="${ROOT_DIR}/ThirdParty/lpac"
OUTPUT="${1:-${ROOT_DIR}/.build/lpac/lpac}"
# Locate an Xcode automatically instead of hardcoding a machine-specific
# path. Same priority as Tools/ec25.swift: DEVELOPER_DIR, the standard
# /Applications installs, the xcode-select selection, then Xcode installs on
# mounted volumes. A candidate only counts when it actually carries the
# Xcode toolchain and the macOS 27 SDK this build requires.
resolve_developer_root() {
    # Unmatched /Volumes globs must vanish instead of aborting the script.
    setopt local_options null_glob
    local candidate sdk_directory
    local -a candidates
    candidates=(
        "${DEVELOPER_DIR:-}"
        /Applications/Xcode.app/Contents/Developer
        /Applications/Xcode-beta.app/Contents/Developer
        "${(f)$(command xcode-select -p 2>/dev/null || true)}"
        /Volumes/*/Applications/Xcode.app/Contents/Developer
        /Volumes/*/Applications/Xcode-beta.app/Contents/Developer
    )
    for candidate in "${candidates[@]}"; do
        [[ -n "${candidate}" ]] || continue
        [[ -d "${candidate}/Toolchains/XcodeDefault.xctoolchain" ]] || continue
        sdk_directory="${candidate}/Platforms/MacOSX.platform/Developer/SDKs"
        [[ -d "${sdk_directory}/MacOSX27.sdk" || -d "${sdk_directory}/MacOSX27.0.sdk" ]] || continue
        print -r -- "${candidate}"
        return 0
    done
    return 1
}

if ! DEVELOPER_ROOT="$(resolve_developer_root)"; then
    print -u2 "No Xcode with the required macOS 27 SDK found; set DEVELOPER_DIR to point at one."
    exit 1
fi
CLANG="${DEVELOPER_ROOT}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
SDK_DIRECTORY="${DEVELOPER_ROOT}/Platforms/MacOSX.platform/Developer/SDKs"
SDK="${SDK_DIRECTORY}/MacOSX27.sdk"
[[ -d "${SDK}" ]] || SDK="${SDK_DIRECTORY}/MacOSX27.0.sdk"
MINIMUM_VERSION="26.0"

if [[ ! -x "${CLANG}" ]]; then
    print -u2 "Clang toolchain not found: ${CLANG}"
    exit 1
fi

if [[ ! -f "${LPAC_ROOT}/REUSE.toml" ]]; then
    print -u2 "Pinned lpac source not found: ${LPAC_ROOT}"
    exit 1
fi

sources=(
    "${LPAC_ROOT}/cjson/cJSON.c"
    "${LPAC_ROOT}/cjson/cJSON_ex.c"
    "${LPAC_ROOT}"/euicc/*.c
    "${LPAC_ROOT}/utils/lpac/utils.c"
    "${LPAC_ROOT}/driver/driver.c"
    "${LPAC_ROOT}/driver/apdu/stdio.c"
    "${LPAC_ROOT}/driver/http/stdio.c"
    "${LPAC_ROOT}/driver/http/curl.c"
    "${LPAC_ROOT}"/src/*.c
    "${LPAC_ROOT}"/src/applet/**/*.c
)

/bin/mkdir -p "${OUTPUT:h}"
BUILD_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ec25-lpac.XXXXXX")"
trap '/bin/rm -rf "${BUILD_ROOT}"' EXIT

ARM64_OUTPUT="${BUILD_ROOT}/lpac-arm64"
SDKROOT="${SDK}" "${CLANG}" \
    -arch arm64 \
    -mmacosx-version-min="${MINIMUM_VERSION}" \
    -std=c99 \
    -O2 \
    -DLPAC_WITH_HTTP_CURL \
    '-DLPAC_VERSION="v2.3.0"' \
    -I"${LPAC_ROOT}" \
    -I"${LPAC_ROOT}/cjson" \
    -I"${LPAC_ROOT}/driver" \
    -I"${LPAC_ROOT}/euicc" \
    -I"${LPAC_ROOT}/utils" \
    -I"${LPAC_ROOT}/src" \
    "${sources[@]}" \
    -lcurl \
    -o "${ARM64_OUTPUT}"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${ARM64_OUTPUT}" "${OUTPUT}"
/bin/chmod 755 "${OUTPUT}"

version="$(${OUTPUT} version)"
if [[ "${version}" != *'"data":"v2.3.0"'* ]]; then
    print -u2 "Unexpected lpac version output: ${version}"
    exit 1
fi

print "Built bundled lpac v2.3.0 for arm64: ${OUTPUT}"
