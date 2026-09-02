#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'PACK_VALIDATOR_FETCH_FAIL[%s]: %s\n' "$1" "$2" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'usage: fetch-and-verify-pack-validator.sh --lock FILE --output FILE [--cosign FILE] [--curl FILE] [--readelf FILE]'
}

lock=''
output=''
cosign_bin=cosign
curl_bin=curl
readelf_bin=readelf
canonical_source_repository=bmzee/cognic-app

while (( $# > 0 )); do
  case "$1" in
    --lock) (( $# >= 2 )) || fail USAGE '--lock requires a file'; lock=$2; shift 2 ;;
    --output) (( $# >= 2 )) || fail USAGE '--output requires a file'; output=$2; shift 2 ;;
    --cosign) (( $# >= 2 )) || fail USAGE '--cosign requires a file'; cosign_bin=$2; shift 2 ;;
    --curl) (( $# >= 2 )) || fail USAGE '--curl requires a file'; curl_bin=$2; shift 2 ;;
    --readelf) (( $# >= 2 )) || fail USAGE '--readelf requires a file'; readelf_bin=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail USAGE "unknown argument: $1" ;;
  esac
done

[[ -n "$lock" && -n "$output" ]] || fail USAGE '--lock and --output are required'
[[ -r "$lock" && -f "$lock" && ! -L "$lock" ]] || \
  fail LOCK 'lock must be a readable regular non-symlink file'
output_parent=$(dirname -- "$output")
[[ -d "$output_parent" && ! -L "$output_parent" ]] || \
  fail OUTPUT 'output parent must be a non-symlink directory'
[[ ! -e "$output" && ! -L "$output" ]] || fail OUTPUT 'output already exists'

command -v jq >/dev/null 2>&1 || fail TOOL_MISSING 'required command is absent: jq'
schema_version=$(jq -er '.schemaVersion' "$lock") || fail LOCK 'lock is not valid JSON'
status=$(jq -er '.status' "$lock") || fail LOCK 'lock has no status'
[[ "$schema_version" == 1 ]] || fail LOCK 'unsupported lock schema'
if [[ "$status" != ready ]]; then
  reason=$(jq -r '.reason // "canonical validator release is not ready"' "$lock")
  fail LOCK_UNAVAILABLE "$reason"
fi

for command_name in awk basename diff dirname find grep install mktemp sha256sum sort tar; do
  command -v "$command_name" >/dev/null 2>&1 || \
    fail TOOL_MISSING "required command is absent: ${command_name}"
done
for configured in "$cosign_bin" "$curl_bin" "$readelf_bin"; do
  if [[ "$configured" == */* ]]; then
    [[ -x "$configured" && -f "$configured" && ! -L "$configured" ]] || \
      fail TOOL_MISSING "configured tool is not an executable regular non-symlink file: ${configured}"
  else
    command -v "$configured" >/dev/null 2>&1 || \
      fail TOOL_MISSING "configured tool is absent: ${configured}"
  fi
done

jq -e '
  keys == [
    "acceptanceCommit", "archive", "baseUrl", "bundle",
    "distributionRepository", "releaseTag", "releaseVersion",
    "schemaVersion", "sourceRepository", "sourceSha", "status", "trust",
    "validatorVersion"
  ] and
  .schemaVersion == "1" and .status == "ready" and
  (.acceptanceCommit | test("^[0-9a-f]{40}$")) and
  .sourceRepository == "bmzee/cognic-app" and
  (.distributionRepository | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
  ((.distributionRepository | ascii_downcase) !=
    (.sourceRepository | ascii_downcase)) and
  (.releaseTag | test("^[A-Za-z0-9][A-Za-z0-9._-]+$")) and
  (.releaseVersion | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  ((.releaseTag == ("engine-v" + .releaseVersion)) or
    (.releaseVersion as $release_version | .releaseTag |
      test("^engine-v" + ($release_version | gsub("\\."; "\\.")) + "-r([2-9]|[1-9][0-9]+)$"))) and
  (.validatorVersion | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.sourceSha | test("^[0-9a-f]{40}$")) and
  .sourceSha == .acceptanceCommit and
  (.baseUrl | test("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/[A-Za-z0-9][A-Za-z0-9._-]+$")) and
  (.baseUrl == ("https://github.com/" + .distributionRepository + "/releases/download/" + .releaseTag)) and
  (.archive | keys == ["name", "sha256"]) and
  (.bundle | keys == ["name", "sha256"]) and
  (.trust | keys == ["publicKey", "publicKeySha256", "trustedRoot", "trustedRootSha256"]) and
  (.archive.name | test("^[A-Za-z0-9][A-Za-z0-9._-]+$")) and
  (.bundle.name == (.archive.name + ".sigstore.json")) and
  (.archive.sha256 | test("^[0-9a-f]{64}$")) and
  (.bundle.sha256 | test("^[0-9a-f]{64}$")) and
  (.trust.publicKey | test("^trust/[A-Za-z0-9][A-Za-z0-9._-]+$")) and
  (.trust.trustedRoot | test("^trust/[A-Za-z0-9][A-Za-z0-9._-]+$")) and
  (.trust.publicKeySha256 | test("^[0-9a-f]{64}$")) and
  (.trust.trustedRootSha256 | test("^[0-9a-f]{64}$"))
' "$lock" >/dev/null || fail LOCK 'ready lock violates its strict schema'

lock_dir=$(CDPATH='' cd -- "$(dirname -- "$lock")" && pwd)
base_url=$(jq -er '.baseUrl' "$lock")
archive_name=$(jq -er '.archive.name' "$lock")
archive_sha256=$(jq -er '.archive.sha256' "$lock")
bundle_name=$(jq -er '.bundle.name' "$lock")
bundle_sha256=$(jq -er '.bundle.sha256' "$lock")
release_version=$(jq -er '.releaseVersion' "$lock")
source_repository=$(jq -er '.sourceRepository' "$lock")
source_sha=$(jq -er '.sourceSha' "$lock")
acceptance_commit=$(jq -er '.acceptanceCommit' "$lock")
validator_version=$(jq -er '.validatorVersion' "$lock")
[[ "$source_repository" == "$canonical_source_repository" ]] || \
  fail LOCK 'validator source repository differs from the canonical Cognic repository'
[[ "$source_sha" == "$acceptance_commit" ]] || \
  fail LOCK 'validator source SHA must exactly equal the reviewed acceptance commit'
public_key="${lock_dir}/$(jq -er '.trust.publicKey' "$lock")"
public_key_sha256=$(jq -er '.trust.publicKeySha256' "$lock")
trusted_root="${lock_dir}/$(jq -er '.trust.trustedRoot' "$lock")"
trusted_root_sha256=$(jq -er '.trust.trustedRootSha256' "$lock")

for trust_file in "$public_key" "$trusted_root"; do
  [[ -r "$trust_file" && -f "$trust_file" && ! -L "$trust_file" ]] || \
    fail TRUST "trust input is not a readable regular non-symlink file: ${trust_file}"
done
[[ "$(sha256sum "$public_key" | awk '{print $1}')" == "$public_key_sha256" ]] || \
  fail TRUST 'public-key bytes differ from the lock fingerprint'
[[ "$(sha256sum "$trusted_root" | awk '{print $1}')" == "$trusted_root_sha256" ]] || \
  fail TRUST 'trusted-root bytes differ from the lock fingerprint'
jq -e '
  (.tlogs | type == "array" and length == 0) and
  (.certificateAuthorities | type == "array" and length == 0) and
  (.ctlogs | type == "array" and length == 0) and
  (.timestampAuthorities | type == "array" and length == 1) and
  (.timestampAuthorities[0].uri | test("^https://")) and
  (.timestampAuthorities[0].certChain.certificates | type == "array" and length >= 2)
' "$trusted_root" >/dev/null || fail TRUST 'trusted root is not private-TSA-only Cognic shape'

version_output=$("$cosign_bin" version 2>&1) || fail COSIGN_VERSION 'cosign version probe failed'
grep -Fxq 'GitVersion:    v3.1.3' <<<"$version_output" || \
  fail COSIGN_VERSION 'cosign v3.1.3 is required'

case "$(uname -m)" in
  x86_64) platform=linux/amd64; expected_machine='Advanced Micro Devices X86-64' ;;
  aarch64|arm64) platform=linux/arm64; expected_machine=AArch64 ;;
  *) fail PLATFORM "unsupported runner architecture: $(uname -m)" ;;
esac

scratch=$(mktemp -d "${TMPDIR:-/tmp}/cognic-validator-fetch.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
archive="${scratch}/${archive_name}"
bundle="${scratch}/${bundle_name}"

download() {
  local name=$1
  local destination=$2
  "$curl_bin" --fail --location --silent --show-error \
    --retry 5 --retry-all-errors \
    --output "$destination" "${base_url}/${name}" || \
    fail DOWNLOAD "canonical release asset is absent or unreadable: ${name}"
  [[ -s "$destination" && -f "$destination" && ! -L "$destination" ]] || \
    fail DOWNLOAD "canonical release asset is empty or unsafe: ${name}"
}

download "$archive_name" "$archive"
download "$bundle_name" "$bundle"
[[ "$(sha256sum "$archive" | awk '{print $1}')" == "$archive_sha256" ]] || \
  fail DIGEST 'canonical evidence archive digest differs from the lock'
[[ "$(sha256sum "$bundle" | awk '{print $1}')" == "$bundle_sha256" ]] || \
  fail DIGEST 'canonical evidence bundle digest differs from the lock'
jq -e 'type == "object"' "$bundle" >/dev/null || \
  fail SIGNATURE 'canonical evidence bundle is not a JSON object'

if ! "$cosign_bin" verify-blob \
  --bundle "$bundle" \
  --key "$public_key" \
  --insecure-ignore-tlog=true \
  --trusted-root "$trusted_root" \
  --use-signed-timestamps \
  "$archive" >/dev/null; then
  fail SIGNATURE 'canonical evidence archive failed public-key/private-TSA verification'
fi

archive_listing="${scratch}/archive.list"
tar -tvzf "$archive" > "$archive_listing" || fail ARCHIVE 'evidence archive cannot be listed'
awk '
  $1 !~ /^-/ { exit 1 }
  $NF !~ /^\.\/[A-Za-z0-9][A-Za-z0-9._-]*$/ { exit 1 }
  { next }
' "$archive_listing" || fail ARCHIVE 'evidence archive contains a non-regular or unsafe entry'
extract_dir="${scratch}/evidence"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir" || fail ARCHIVE 'verified evidence archive could not be extracted'

[[ -f "${extract_dir}/SHA256SUMS" && ! -L "${extract_dir}/SHA256SUMS" ]] || \
  fail CHECKSUM 'verified evidence archive has no safe SHA256SUMS'
checksum_names="${scratch}/checksum.names"
if ! awk '
  NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
    name = $2
    sub(/^\*/, "", name)
    sub(/^\.\//, "", name)
    if (name !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || name == "SHA256SUMS") exit 1
    print name
    next
  }
  { exit 1 }
' "${extract_dir}/SHA256SUMS" | sort > "$checksum_names"; then
  fail CHECKSUM_MANIFEST 'verified evidence SHA256SUMS has malformed or unsafe entries'
fi
actual_names="${scratch}/actual.names"
while IFS= read -r -d '' extracted_file; do
  basename -- "$extracted_file"
done < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS -print0) | \
  sort > "$actual_names"
diff -u "$actual_names" "$checksum_names" >/dev/null || \
  fail CHECKSUM_MANIFEST 'verified evidence SHA256SUMS must cover every payload exactly once'
if ! (
  cd "$extract_dir"
  sha256sum --check --strict --status SHA256SUMS
); then
  fail CHECKSUM 'verified evidence archive checksum validation failed'
fi

manifest="${extract_dir}/pack-validator-binaries.release.json"
[[ -r "$manifest" && -f "$manifest" && ! -L "$manifest" ]] || \
  fail MANIFEST 'validator release manifest is missing or unsafe'
jq -e \
  --arg version "$release_version" '
    keys == ["artifacts", "releaseVersion", "schemaVersion", "source"] and
    .schemaVersion == "1" and .releaseVersion == $version and
    (.source | keys == ["gitCommit", "sourceDateEpoch"]) and
    (.source.gitCommit | test("^[0-9a-f]{40}$")) and
    (.source.sourceDateEpoch | test("^(0|[1-9][0-9]*)$")) and
    (.artifacts | length == 2) and
    ([.artifacts[].platform] == ["linux/amd64", "linux/arm64"]) and
    (all(.artifacts[];
      keys == ["digest", "file", "platform", "sigstoreBundle", "sigstoreBundleDigest"] and
      (.digest | test("^sha256:[0-9a-f]{64}$")) and
      (.sigstoreBundleDigest | test("^sha256:[0-9a-f]{64}$")) and
      (.file == ("cognic-pack-validate-" + (.platform | gsub("/"; "-")))) and
      (.sigstoreBundle == (.file + ".sigstore.json"))
    ))
  ' "$manifest" >/dev/null || fail MANIFEST 'validator release manifest violates its strict schema'
attested_source_sha=$(jq -er '.source.gitCommit' "$manifest") || \
  fail SOURCE_ATTESTATION 'signed validator manifest has no source commit attestation'
[[ "$attested_source_sha" == "$acceptance_commit" ]] || \
  fail SOURCE_ATTESTATION 'signed validator source commit differs from the reviewed lock commit'

expected_payload_names="${scratch}/expected-payload.names"
{
  jq -r '.artifacts[] | .file, .sigstoreBundle' "$manifest"
  printf '%s\n' pack-validator-binaries.release.json
} | sort > "$expected_payload_names"
actual_validator_payload_names="${scratch}/actual-validator-payload.names"
awk '
  /^cognic-pack-validate-/ || $0 == "pack-validator-binaries.release.json" {
    print
  }
' "$actual_names" > "$actual_validator_payload_names"
diff -u "$expected_payload_names" "$actual_validator_payload_names" >/dev/null || \
  fail PAYLOAD_SET \
    'verified evidence archive validator namespace differs from the strict manifest'

[[ "$(jq -r --arg platform "$platform" '[.artifacts[] | select(.platform == $platform)] | length' "$manifest")" == 1 ]] || \
  fail MANIFEST "validator manifest does not contain exactly one ${platform} artifact"
entry=$(jq -cer --arg platform "$platform" '.artifacts[] | select(.platform == $platform)' "$manifest")
binary_name=$(jq -er '.file' <<<"$entry")
binary_bundle_name=$(jq -er '.sigstoreBundle' <<<"$entry")
binary="${extract_dir}/${binary_name}"
binary_bundle="${extract_dir}/${binary_bundle_name}"
[[ -f "$binary" && ! -L "$binary" && -s "$binary" ]] || \
  fail BINARY 'selected validator binary is missing or unsafe'
[[ -f "$binary_bundle" && ! -L "$binary_bundle" && -s "$binary_bundle" ]] || \
  fail SIGNATURE 'selected validator signature bundle is missing or unsafe'

expected_binary_digest=$(jq -er '.digest | sub("^sha256:"; "")' <<<"$entry")
expected_binary_bundle_digest=$(jq -er '.sigstoreBundleDigest | sub("^sha256:"; "")' <<<"$entry")
[[ "$(sha256sum "$binary" | awk '{print $1}')" == "$expected_binary_digest" ]] || \
  fail DIGEST 'selected validator binary differs from its signed manifest digest'
[[ "$(sha256sum "$binary_bundle" | awk '{print $1}')" == "$expected_binary_bundle_digest" ]] || \
  fail DIGEST 'selected validator bundle differs from its signed manifest digest'

if ! "$cosign_bin" verify-blob \
  --bundle "$binary_bundle" \
  --key "$public_key" \
  --insecure-ignore-tlog=true \
  --trusted-root "$trusted_root" \
  --use-signed-timestamps \
  "$binary" >/dev/null; then
  fail SIGNATURE 'selected validator failed its own public-key/private-TSA verification'
fi
"$readelf_bin" -h "$binary" | grep -Eq "Machine:[[:space:]]+${expected_machine}" || \
  fail BINARY_PLATFORM 'selected validator ELF machine differs from the runner'
program_headers=$("$readelf_bin" -l "$binary") || fail BINARY 'validator program headers cannot be read'
if grep -q 'Requesting program interpreter' <<<"$program_headers"; then
  fail BINARY_STATIC 'selected validator is dynamically linked'
fi
validator_version_output=$("$binary" --version 2>&1) || fail BINARY 'verified validator version probe failed'
[[ "$validator_version_output" == "cognic-pack-validate ${validator_version}" ]] || \
  fail BINARY 'verified validator version differs from the lock'

install -m 0555 "$binary" "$output"
[[ "$(sha256sum "$output" | awk '{print $1}')" == "$expected_binary_digest" ]] || \
  fail DIGEST 'installed validator bytes changed after verification'

rm -rf -- "$scratch"
trap - EXIT
printf 'PACK_VALIDATOR_FETCH_OK: platform=%s release=%s digest=sha256:%s\n' \
  "$platform" "$release_version" "$expected_binary_digest"
