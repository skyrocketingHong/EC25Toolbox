#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="EC25 Toolbox"
EXECUTABLE_NAME="EC25Toolbox"
OUTPUT_APP="${EC25_OUTPUT_APP:-${ROOT_DIR}/dist/${APP_NAME}.app}"
CONFIGURATION="${EC25_BUILD_CONFIGURATION:-release}"

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
SWIFT="${DEVELOPER_ROOT}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SDK_DIRECTORY="${DEVELOPER_ROOT}/Platforms/MacOSX.platform/Developer/SDKs"
SDK="${SDK_DIRECTORY}/MacOSX27.sdk"
[[ -d "${SDK}" ]] || SDK="${SDK_DIRECTORY}/MacOSX27.0.sdk"
PLUGIN_PATH="${DEVELOPER_ROOT}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

INFO_PLIST="${ROOT_DIR}/Resources/EC25Toolbox-Info.plist"
ICON_SOURCE="${ROOT_DIR}/Resources/EC25Toolbox.icon"

if [[ ! -x "${SWIFT}" ]]; then
    print -u2 "Swift toolchain not found: ${SWIFT}"
    exit 1
fi

if [[ ! -d "${SDK}" ]]; then
    print -u2 "macOS SDK not found: ${SDK}"
    exit 1
fi

/usr/bin/plutil -lint "${INFO_PLIST}" >/dev/null

BUILD_OPTIONS=(
    --disable-sandbox
    -c "${CONFIGURATION}"
    --sdk "${SDK}"
    -Xswiftc -plugin-path
    -Xswiftc "${PLUGIN_PATH}"
)

if [[ "${EC25_SKIP_SWIFT_BUILD:-0}" != "1" ]]; then
    # No --product filter: swift build honors only one product per invocation,
    # and the bundle needs the app plus both privileged helpers.
    DEVELOPER_DIR="${DEVELOPER_ROOT}" "${SWIFT}" build \
        "${BUILD_OPTIONS[@]}"
fi

BIN_DIR="$(DEVELOPER_DIR="${DEVELOPER_ROOT}" "${SWIFT}" build "${BUILD_OPTIONS[@]}" --show-bin-path)"
EXECUTABLE="${BIN_DIR}/EC25Toolbox"
IKE_HELPER_EXECUTABLE="${BIN_DIR}/EC25IKEHelper"
SYSTEM_HELPER_EXECUTABLE="${BIN_DIR}/EC25SystemHelper"
SYSTEM_HELPER_PLIST="${ROOT_DIR}/Sources/EC25SystemHelper/ing.fuyaoskyrocket.ec25toolbox.system-helper.plist"
RESOURCE_BUNDLE="${BIN_DIR}/EC25Toolbox_EC25Toolbox.bundle"

if [[ ! -x "${EXECUTABLE}" ]]; then
    print -u2 "Built executable not found: ${EXECUTABLE}"
    exit 1
fi

if [[ ! -x "${IKE_HELPER_EXECUTABLE}" ]]; then
    print -u2 "Built IKE helper not found: ${IKE_HELPER_EXECUTABLE}"
    exit 1
fi

if [[ ! -x "${SYSTEM_HELPER_EXECUTABLE}" ]]; then
    print -u2 "Built system helper not found: ${SYSTEM_HELPER_EXECUTABLE}"
    exit 1
fi

/usr/bin/plutil -lint "${SYSTEM_HELPER_PLIST}" >/dev/null

if [[ ! -d "${RESOURCE_BUNDLE}" ]]; then
    print -u2 "Localization resource bundle not found: ${RESOURCE_BUNDLE}"
    exit 1
fi

STAGING_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ec25-toolbox-package.XXXXXX")"
STAGING_APP="${STAGING_ROOT}/${APP_NAME}.app"
trap '/bin/rm -rf "${STAGING_ROOT}"' EXIT

/bin/mkdir -p "${STAGING_APP}/Contents/MacOS" "${STAGING_APP}/Contents/Resources"
/bin/mkdir -p "${STAGING_APP}/Contents/Library/PrivilegedHelperTools"
/bin/mkdir -p "${STAGING_APP}/Contents/Library/LaunchDaemons"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${EXECUTABLE}" "${STAGING_APP}/Contents/MacOS/${EXECUTABLE_NAME}"
# Legacy bless-installed IKE helper, kept as the migration rollback path.
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${IKE_HELPER_EXECUTABLE}" "${STAGING_APP}/Contents/Library/PrivilegedHelperTools/EC25IKEHelper"
# SMAppService daemon + property list (BundleProgram points at this location).
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${SYSTEM_HELPER_EXECUTABLE}" "${STAGING_APP}/Contents/Library/LaunchDaemons/EC25SystemHelper"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${SYSTEM_HELPER_PLIST}" "${STAGING_APP}/Contents/Library/LaunchDaemons/ing.fuyaoskyrocket.ec25toolbox.system-helper.plist"
/bin/cat > "${STAGING_APP}/Contents/Library/LaunchDaemons/ing.fuyaoskyrocket.ec25toolbox.ike-helper.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>ing.fuyaoskyrocket.ec25toolbox.ike-helper</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Library/PrivilegedHelperTools/ing.fuyaoskyrocket.ec25toolbox.ike-helper</string>
	</array>
	<key>MachServices</key>
	<dict>
		<key>ing.fuyaoskyrocket.ec25toolbox.ike-helper</key>
		<true/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>RunAtLoad</key>
	<false/>
	<key>ThrottleInterval</key>
	<integer>3</integer>
</dict>
</plist>
EOF
if [[ "${EC25_REUSE_PACKAGED_LPAC:-0}" == "1" ]]; then
    EXISTING_LPAC="${OUTPUT_APP}/Contents/MacOS/lpac"
    if [[ ! -x "${EXISTING_LPAC}" ]]; then
        print -u2 "Existing packaged lpac not found: ${EXISTING_LPAC}"
        exit 1
    fi
    COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${EXISTING_LPAC}" "${STAGING_APP}/Contents/MacOS/lpac"
else
    /bin/zsh "${ROOT_DIR}/Tools/build_lpac.sh" "${STAGING_APP}/Contents/MacOS/lpac"
fi
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${RESOURCE_BUNDLE}" "${STAGING_APP}/Contents/Resources/EC25Toolbox_EC25Toolbox.bundle"
/bin/mkdir -p "${STAGING_APP}/Contents/Resources/ThirdParty/lpac"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${ROOT_DIR}/ThirdParty/lpac/LICENSES" "${STAGING_APP}/Contents/Resources/ThirdParty/lpac/LICENSES"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${ROOT_DIR}/ThirdParty/lpac/REUSE.toml" "${STAGING_APP}/Contents/Resources/ThirdParty/lpac/REUSE.toml"
/bin/mkdir -p "${STAGING_APP}/Contents/Resources/ThirdParty/EasyLPAC"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${ROOT_DIR}/ThirdParty/EasyLPAC-LICENSE" "${STAGING_APP}/Contents/Resources/ThirdParty/EasyLPAC/LICENSE"
/bin/mkdir -p "${STAGING_APP}/Contents/Resources/ThirdParty/VoWiFi"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${ROOT_DIR}/ThirdParty/VoWiFi-NOTICE.md" "${STAGING_APP}/Contents/Resources/ThirdParty/VoWiFi/NOTICE.md"
DEVELOPER_DIR="${DEVELOPER_ROOT}" /usr/bin/xcrun actool \
    "${ICON_SOURCE}" \
    --compile "${STAGING_APP}/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon EC25Toolbox \
    --output-partial-info-plist "${STAGING_ROOT}/IconInfo.plist" \
    --warnings \
    --notices \
    --errors
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${INFO_PLIST}" "${STAGING_APP}/Contents/Info.plist"
for locale in en zh-Hans; do
    /bin/mkdir -p "${STAGING_APP}/Contents/Resources/${locale}.lproj"
    COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc \
        "${ROOT_DIR}/Resources/${locale}.lproj/InfoPlist.strings" \
        "${STAGING_APP}/Contents/Resources/${locale}.lproj/InfoPlist.strings"
    # Localized About-panel credits; AppKit resolves "Credits.html" from the
    # matching .lproj so the GitHub/license links follow the app language.
    COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc \
        "${ROOT_DIR}/Resources/${locale}.lproj/Credits.html" \
        "${STAGING_APP}/Contents/Resources/${locale}.lproj/Credits.html"
done
/bin/chmod 755 "${STAGING_APP}/Contents/MacOS/${EXECUTABLE_NAME}"
/bin/chmod 755 "${STAGING_APP}/Contents/MacOS/lpac"
/bin/chmod 755 "${STAGING_APP}/Contents/Library/PrivilegedHelperTools/EC25IKEHelper"
/bin/chmod 755 "${STAGING_APP}/Contents/Library/LaunchDaemons/EC25SystemHelper"

/usr/bin/xattr -cr "${STAGING_APP}"
/usr/bin/codesign --force --identifier "ing.fuyaoskyrocket.ec25toolbox.ike-helper" --sign - \
    "${STAGING_APP}/Contents/Library/PrivilegedHelperTools/EC25IKEHelper"
/usr/bin/codesign --force --identifier "ing.fuyaoskyrocket.ec25toolbox.system-helper" --sign - \
    "${STAGING_APP}/Contents/Library/LaunchDaemons/EC25SystemHelper"
/usr/bin/codesign --force --deep --sign - "${STAGING_APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${STAGING_APP}"

/bin/mkdir -p "${OUTPUT_APP:h}"
/bin/rm -rf "${OUTPUT_APP}"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${STAGING_APP}" "${OUTPUT_APP}"
/usr/bin/xattr -cr "${OUTPUT_APP}"
/usr/bin/codesign --force --identifier "ing.fuyaoskyrocket.ec25toolbox.ike-helper" --sign - \
    "${OUTPUT_APP}/Contents/Library/PrivilegedHelperTools/EC25IKEHelper"
/usr/bin/codesign --force --identifier "ing.fuyaoskyrocket.ec25toolbox.system-helper" --sign - \
    "${OUTPUT_APP}/Contents/Library/LaunchDaemons/EC25SystemHelper"
/usr/bin/codesign --force --deep --sign - "${OUTPUT_APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${OUTPUT_APP}"

print "Packaged and verified: ${OUTPUT_APP}"
print "Privileged helpers (static bundle verification):"
print "  Contents/Library/PrivilegedHelperTools/EC25IKEHelper (legacy, migration rollback)"
print "  Contents/Library/LaunchDaemons/EC25SystemHelper + system-helper plist (SMAppService daemon)"
print "Ad hoc local signature: daemon registration, approval, upgrade, and removal"
print "must be accepted on a properly signed distribution build."
