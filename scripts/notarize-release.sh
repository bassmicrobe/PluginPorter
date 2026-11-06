#!/bin/bash
set -euo pipefail

package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: SIGNING_IDENTITY=<SHA1> TEAM_ID=<team> NOTARY_PROFILE=<profile> [SIGNING_KEYCHAIN=<path>] %s\n' "$0"
    printf 'Builds, signs, notarizes and verifies an arm64 ZIP in dist/notarization/run-*/.\n'
    printf 'Requires a clean Git working tree. Retains evidence on failure; never publishes or installs.\n'
    exit 0
fi
if [[ $# -ne 0 ]]; then
    printf 'Unexpected argument: %s\n' "$1" >&2
    exit 2
fi
: "${SIGNING_IDENTITY:?Set the Developer ID Application certificate SHA-1.}"
: "${TEAM_ID:?Set the expected Apple Developer Team ID.}"
: "${NOTARY_PROFILE:?Set an existing notarytool keychain profile.}"
if [[ ! "$SIGNING_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
    printf 'SIGNING_IDENTITY must be a certificate SHA-1 fingerprint.\n' >&2
    exit 2
fi
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    printf 'TEAM_ID must be the expected ten-character Apple Developer Team ID.\n' >&2
    exit 2
fi
SIGNING_IDENTITY="$(printf '%s' "$SIGNING_IDENTITY" | tr '[:lower:]' '[:upper:]')"
if [[ -n "$(git -C "$package_root" status --porcelain --untracked-files=normal)" ]]; then
    printf 'Commit or set aside source changes before creating a notarized build.\n' >&2
    exit 1
fi
source_commit="$(git -C "$package_root" rev-parse HEAD)"
source_tree="$(git -C "$package_root" rev-parse HEAD^{tree})"

mkdir -p "$package_root/dist/notarization"
run_directory="$(mktemp -d "$package_root/dist/notarization/run-$(date +%Y%m%d-%H%M%S).XXXXXX")"
bundle="$run_directory/PluginPorter.app"
executable="$bundle/Contents/MacOS/PluginPorter"
printf 'Notarization work directory: %s\n' "$run_directory"
on_exit() {
    result=$?
    if [[ $result -ne 0 ]]; then
        printf 'Exit status: %s\n' "$result" > "$run_directory/failure-status.txt"
        printf 'Stopped; work and Apple submission details are retained in %s\n' "$run_directory" >&2
    fi
}
trap on_exit EXIT
{
    printf 'Source commit: %s\nSource tree: %s\n' "$source_commit" "$source_tree"
    printf 'Build UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'DEVELOPER_DIR: %s\n' "${DEVELOPER_DIR:-<xcode-select default>}"
    printf 'Architecture: arm64\nBundle ID: local.pluginporter.app\n'
    git -C "$package_root" status --short
    sw_vers
    xcode-select -p
    xcrun swift --version
    xcrun notarytool --version
} > "$run_directory/build-context.txt"

signing_arguments=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp)
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
    signing_arguments+=(--keychain "$SIGNING_KEYCHAIN")
    security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" > "$run_directory/signing-identities.txt"
else
    security find-identity -v -p codesigning > "$run_directory/signing-identities.txt"
fi
grep -F "$SIGNING_IDENTITY" "$run_directory/signing-identities.txt" | grep -F 'Developer ID Application:'

"$package_root/build.command" "$run_directory" > "$run_directory/build.log" 2>&1
cat "$run_directory/build.log"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")"
if [[ "$bundle_id" != local.pluginporter.app ]]; then
    printf 'Unexpected Bundle ID: %s\n' "$bundle_id" >&2
    exit 1
fi
architectures="$(xcrun lipo -archs "$executable")"
printf '%s\n' "$architectures" > "$run_directory/architectures.txt"
if [[ "$architectures" != arm64 ]]; then
    printf 'Expected an arm64-only executable, found: %s\n' "$architectures" >&2
    exit 1
fi
xcrun lipo "$executable" -verify_arch arm64

# The current application contains one native executable. Embedded executable
# code requires an explicit signing order and entitlement policy before release.
while IFS= read -r -d '' bundle_file; do
    if [[ "$bundle_file" != "$executable" ]] && file -b "$bundle_file" | grep -q 'Mach-O'; then
        printf 'Embedded executable needs an explicit signing policy: %s\n' "$bundle_file" >&2
        exit 1
    fi
done < <(find "$bundle" -type f -print0)

codesign "${signing_arguments[@]}" "$bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"
codesign -d --verbose=4 "$bundle" 2> "$run_directory/signature.txt"
grep -Fx "TeamIdentifier=$TEAM_ID" "$run_directory/signature.txt"
grep -F 'Authority=Developer ID Application:' "$run_directory/signature.txt"
grep -E '^flags=.*runtime|^CodeDirectory .*flags=.*runtime' "$run_directory/signature.txt"
grep -E '^Timestamp=' "$run_directory/signature.txt"
codesign -d --extract-certificates="$run_directory/signer-" "$bundle"
openssl x509 -inform DER -in "$run_directory/signer-0" -noout -fingerprint -sha1 > "$run_directory/signer-fingerprint.txt"
actual_identity="$(sed 's/.*=//' "$run_directory/signer-fingerprint.txt" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
if [[ "$actual_identity" != "$SIGNING_IDENTITY" ]]; then
    printf 'The embedded signing certificate does not match SIGNING_IDENTITY.\n' >&2
    exit 1
fi
if [[ "$(git -C "$package_root" rev-parse HEAD)" != "$source_commit" || -n "$(git -C "$package_root" status --porcelain --untracked-files=normal)" ]]; then
    printf 'Source changed during the build; stopping before Apple submission.\n' >&2
    exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$bundle" "$run_directory/submission.zip"
xcrun notarytool submit "$run_directory/submission.zip" --keychain-profile "$NOTARY_PROFILE" --output-format json > "$run_directory/submission.json"
submission_id="$(plutil -extract id raw -o - "$run_directory/submission.json")"
printf '%s\n' "$submission_id" > "$run_directory/submission-id.txt"
printf 'Apple submission: %s\n' "$submission_id"
if ! xcrun notarytool wait "$submission_id" --keychain-profile "$NOTARY_PROFILE" --timeout 30m --output-format json > "$run_directory/status.json" 2> "$run_directory/wait-stderr.txt"; then
    xcrun notarytool info "$submission_id" --keychain-profile "$NOTARY_PROFILE" --output-format json > "$run_directory/latest-status.json" 2> "$run_directory/info-stderr.txt" || true
    xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$run_directory/notary-log.json" > "$run_directory/log-output.txt" 2> "$run_directory/log-stderr.txt" || true
    printf 'Check or resume the existing submission with notarytool info/wait %s; do not resubmit it.\n' "$submission_id" >&2
    exit 1
fi
xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$run_directory/notary-log.json"
apple_status="$(plutil -extract status raw -o - "$run_directory/status.json")"
if [[ "$apple_status" != Accepted ]]; then
    printf 'Apple status: %s. See notary-log.json.\n' "$apple_status" >&2
    exit 1
fi

xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"
spctl --assess --type execute --verbose=2 "$bundle" 2> "$run_directory/gatekeeper.txt"
grep -F 'source=Notarized Developer ID' "$run_directory/gatekeeper.txt"

release_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
release_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")"
if [[ ! "$release_version" =~ ^[[:alnum:]][[:alnum:]._-]*$ || ! "$release_build" =~ ^[[:digit:]]+$ ]]; then
    printf 'Version or build cannot be used safely in an archive filename.\n' >&2
    exit 1
fi
archive_name="PluginPorter-$release_version-build$release_build-arm64-notarized.zip"
checksum_name="$archive_name.sha256"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$run_directory/$archive_name"
unzip -tq "$run_directory/$archive_name"
(
    cd "$run_directory"
    shasum -a 256 "$archive_name" > "$checksum_name"
    shasum -a 256 -c "$checksum_name"
)

mkdir "$run_directory/extracted"
ditto -x -k "$run_directory/$archive_name" "$run_directory/extracted"
extracted_bundle="$run_directory/extracted/PluginPorter.app"
extracted_executable="$extracted_bundle/Contents/MacOS/PluginPorter"
xcrun stapler validate "$extracted_bundle"
codesign --verify --deep --strict --verbose=2 "$extracted_bundle"
codesign -d --verbose=4 "$extracted_bundle" 2> "$run_directory/extracted-signature.txt"
grep -Fx "TeamIdentifier=$TEAM_ID" "$run_directory/extracted-signature.txt"
xcrun lipo "$extracted_executable" -verify_arch arm64
cmp "$executable" "$extracted_executable"
spctl --assess --type execute --verbose=2 "$extracted_bundle" 2> "$run_directory/extracted-gatekeeper.txt"
grep -F 'source=Notarized Developer ID' "$run_directory/extracted-gatekeeper.txt"
"$extracted_executable" --cli --help > "$run_directory/extracted-cli-help.txt" 2> "$run_directory/extracted-cli-stderr.txt"
grep -F 'PluginPorter' "$run_directory/extracted-cli-help.txt"
{
    printf 'Source commit: %s\nSource tree: %s\n' "$source_commit" "$source_tree"
    printf 'Bundle ID: %s\nVersion: %s\nBuild: %s\nArchitecture: arm64\n' "$bundle_id" "$release_version" "$release_build"
    printf 'Apple submission: %s\nApple status: Accepted\n' "$submission_id"
    cat "$run_directory/$checksum_name"
} > "$run_directory/release-summary.txt"
printf '\nApple status: Accepted\nVerified release archive: %s\nChecksums: %s\n' "$run_directory/$archive_name" "$run_directory/$checksum_name"
