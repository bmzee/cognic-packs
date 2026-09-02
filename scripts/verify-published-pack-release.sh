#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'PUBLISHED_PACK_VERIFY_FAIL[%s]: %s\n' "$1" "$2" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'usage: verify-published-pack-release.sh --repository OWNER/REPO --tag TAG --source-sha SHA --expected-manifest-sha256 SHA256 --expected-content-sha256 SHA256 --manifest-name FILE --manifest-sha256 SHA256 --public-key-sha256 SHA256 --trusted-root-sha256 SHA256 --validator FILE [--cosign FILE] [--curl FILE] [--oras FILE]'
}

repository=''
tag=''
source_sha=''
expected_manifest_sha256=''
expected_content_sha256=''
manifest_name=''
manifest_sha256=''
expected_public_key_sha256=''
expected_trusted_root_sha256=''
validator=''
cosign_bin=cosign
curl_bin=curl
oras_bin=oras
while (( $# > 0 )); do
  case "$1" in
    --repository) (( $# >= 2 )) || fail USAGE '--repository requires OWNER/REPO'; repository=$2; shift 2 ;;
    --tag) (( $# >= 2 )) || fail USAGE '--tag requires a value'; tag=$2; shift 2 ;;
    --source-sha) (( $# >= 2 )) || fail USAGE '--source-sha requires a SHA'; source_sha=$2; shift 2 ;;
    --expected-manifest-sha256) (( $# >= 2 )) || fail USAGE '--expected-manifest-sha256 requires a digest'; expected_manifest_sha256=$2; shift 2 ;;
    --expected-content-sha256) (( $# >= 2 )) || fail USAGE '--expected-content-sha256 requires a digest'; expected_content_sha256=$2; shift 2 ;;
    --manifest-name) (( $# >= 2 )) || fail USAGE '--manifest-name requires a file'; manifest_name=$2; shift 2 ;;
    --manifest-sha256) (( $# >= 2 )) || fail USAGE '--manifest-sha256 requires a digest'; manifest_sha256=$2; shift 2 ;;
    --public-key-sha256) (( $# >= 2 )) || fail USAGE '--public-key-sha256 requires a digest'; expected_public_key_sha256=$2; shift 2 ;;
    --trusted-root-sha256) (( $# >= 2 )) || fail USAGE '--trusted-root-sha256 requires a digest'; expected_trusted_root_sha256=$2; shift 2 ;;
    --validator) (( $# >= 2 )) || fail USAGE '--validator requires a file'; validator=$2; shift 2 ;;
    --cosign) (( $# >= 2 )) || fail USAGE '--cosign requires a file'; cosign_bin=$2; shift 2 ;;
    --curl) (( $# >= 2 )) || fail USAGE '--curl requires a file'; curl_bin=$2; shift 2 ;;
    --oras) (( $# >= 2 )) || fail USAGE '--oras requires a file'; oras_bin=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail USAGE "unknown argument: $1" ;;
  esac
done

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  fail REPOSITORY 'repository must be OWNER/REPO'
[[ "$tag" =~ ^[a-z0-9][a-z0-9._-]*-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  fail TAG 'release tag is malformed'
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail SOURCE_SHA 'source SHA is malformed'
[[ "$expected_manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || \
  fail SOURCE_CONTENT 'an independently validated source manifest SHA-256 is required'
[[ "$expected_content_sha256" =~ ^[0-9a-f]{64}$ ]] || \
  fail SOURCE_CONTENT 'an independently validated source content SHA-256 is required'
[[ "$manifest_name" =~ ^[a-z0-9][a-z0-9._-]*\.release\.json$ ]] || \
  fail MANIFEST 'manifest file name is malformed'
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || fail DIGEST 'manifest SHA-256 is malformed'
[[ "$expected_public_key_sha256" =~ ^[0-9a-f]{64}$ ]] || \
  fail TRUST 'an independently pinned public-key SHA-256 is required'
[[ "$expected_trusted_root_sha256" =~ ^[0-9a-f]{64}$ ]] || \
  fail TRUST 'an independently pinned trusted-root SHA-256 is required'
[[ -x "$validator" && -f "$validator" && ! -L "$validator" ]] || \
  fail VALIDATOR 'validator must be an executable regular non-symlink file'
for configured in "$cosign_bin" "$curl_bin" "$oras_bin"; do
  if [[ "$configured" == */* ]]; then
    [[ -x "$configured" && -f "$configured" && ! -L "$configured" ]] || \
      fail TOOL_MISSING "configured tool is not an executable regular non-symlink file: ${configured}"
  else
    command -v "$configured" >/dev/null 2>&1 || \
      fail TOOL_MISSING "configured tool is absent: ${configured}"
  fi
done
for command_name in awk diff find jq mktemp ruby sha256sum sort tar tr wc; do
  command -v "$command_name" >/dev/null 2>&1 || \
    fail TOOL_MISSING "required command is absent: ${command_name}"
done
cosign_version=$("$cosign_bin" version 2>&1) || fail COSIGN_VERSION 'cosign version probe failed'
grep -Fxq 'GitVersion:    v3.1.3' <<<"$cosign_version" || \
  fail COSIGN_VERSION 'cosign v3.1.3 is required'
oras_version=$("$oras_bin" version 2>&1) || fail ORAS_VERSION 'ORAS version probe failed'
grep -Eq '^Version:[[:space:]]+1\.3\.3$' <<<"$oras_version" || \
  fail ORAS_VERSION 'ORAS v1.3.3 is required'

retry_delay=${PACK_RELEASE_RETRY_DELAY_SECONDS:-5}
[[ "$retry_delay" =~ ^[0-9]+$ ]] || fail INVOCATION 'retry delay must be a non-negative integer'
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cognic-public-release.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
api_url="https://api.github.com/repos/${repository}/releases/tags/${tag}"
download_base="https://github.com/${repository}/releases/download/${tag}"
source_repository="https://github.com/${repository}"
repository_owner=${repository%%/*}
repository_owner_lower=$(printf '%s' "$repository_owner" | tr '[:upper:]' '[:lower:]')
[[ "$repository_owner_lower" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  fail REPOSITORY 'repository owner cannot form a canonical GHCR namespace'
oci_repository_prefix="ghcr.io/${repository_owner_lower}/cognic-packs/"

download() {
  local url=$1
  local output=$2
  "$curl_bin" --fail --location --silent --show-error \
    --retry 5 --retry-all-errors \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2026-03-10' \
    --output "$output" "$url"
}

retry_capture() {
  local output_file=$1
  shift
  local attempt
  for attempt in 1 2 3 4; do
    rm -f -- "$output_file" "${output_file}.error"
    if "$@" > "$output_file" 2> "${output_file}.error"; then
      rm -f -- "${output_file}.error"
      return 0
    fi
    [[ "$attempt" == 4 ]] || sleep "$((attempt * retry_delay))"
  done
  return 1
}

printf -v expected_release_body \
  "Cognic pack release \`%s\` with signed tar and OCI artifacts.\n\nSource-SHA: \`%s\`\nSource-Pack-Manifest-SHA256: \`%s\`\nSource-Pack-Content-SHA256: \`%s\`\nRelease-Manifest-SHA256: \`%s\`\n" \
  "$tag" "$source_sha" "$expected_manifest_sha256" "$expected_content_sha256" \
  "$manifest_sha256"
metadata="${scratch}/release.json"
release_ready=false
for attempt in 1 2 3 4 5 6; do
  rm -f -- "$metadata"
  if download "$api_url" "$metadata" && jq -e \
    --arg tag "$tag" \
    --arg source "$source_sha" \
    --arg body "$expected_release_body" '
      .tag_name == $tag and .name == $tag and .body == $body and
      .target_commitish == $source and
      .draft == false and .prerelease == false and .immutable == true and
      (.assets | type == "array") and
      (all(.assets[];
        .state == "uploaded" and
        (.size | type == "number" and . >= 0 and floor == .) and
        (.digest == null or (.digest | test("^sha256:[0-9a-f]{64}$")))))
    ' "$metadata" >/dev/null 2>&1; then
    release_ready=true
    break
  fi
  [[ "$attempt" == 6 ]] || sleep "$((attempt * retry_delay))"
done
[[ "$release_ready" == true ]] || \
  fail RELEASE 'public immutable release identity/assets did not become authoritative after bounded retries'

manifest="${scratch}/${manifest_name}"
download "${download_base}/${manifest_name}" "$manifest" || \
  fail DOWNLOAD 'public release manifest is absent or unreadable'
[[ "$(sha256sum "$manifest" | awk '{print $1}')" == "$manifest_sha256" ]] || \
  fail DIGEST 'public release manifest differs from the pre-publication digest'
pack_name=$(jq -er '.pack.name | select(type == "string")' "$manifest") || \
  fail MANIFEST 'public release manifest has no pack name'
[[ "${#pack_name}" -le 128 && \
  "$pack_name" =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]] || \
  fail MANIFEST 'public release manifest pack name is not canonical'
pack_name_sha256=$(printf '%s' "$pack_name" | sha256sum | awk '{print $1}')
expected_oci_repository="${oci_repository_prefix}pack-sha256-${pack_name_sha256}"
jq -e \
  --arg manifest_sha256 "$expected_manifest_sha256" \
  --arg content_sha256 "$expected_content_sha256" '
    .pack.manifestSha256 == $manifest_sha256 and
    .pack.contentSha256 == $content_sha256
  ' "$manifest" >/dev/null || \
  fail SOURCE_CONTENT 'public release pack hashes differ from the independently validated tagged source'
jq -e \
  --arg tag "$tag" \
  --arg source_sha "$source_sha" \
  --arg source_repository "$source_repository" \
  --arg pack_name "$pack_name" \
  --arg expected_manifest_sha256 "$expected_manifest_sha256" \
  --arg expected_content_sha256 "$expected_content_sha256" \
  --arg expected_oci_repository "$expected_oci_repository" \
  --arg manifest_name "$manifest_name" '
    keys == ["archive", "oci", "pack", "schemaVersion", "source", "tag", "trust"] and
    .schemaVersion == "1" and .tag == $tag and .source.gitCommit == $source_sha and
    (.source | keys == ["gitCommit", "repository", "sourceDateEpoch"]) and
    .source.repository == $source_repository and
    (.source.sourceDateEpoch | test("^(0|[1-9][0-9]*)$")) and
    (.pack | keys == ["contentSha256", "manifestSha256", "name", "version"]) and
    .pack.name == $pack_name and
    (.pack.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    .pack.contentSha256 == $expected_content_sha256 and
    .pack.manifestSha256 == $expected_manifest_sha256 and
    (.tag == (.pack.name + "-v" + .pack.version)) and
    (.archive | keys == ["digest", "file", "sigstoreBundle", "sigstoreBundleDigest"]) and
    (.archive.file == (.pack.name + "-" + .pack.version + ".tar.gz")) and
    (.archive.sigstoreBundle == (.archive.file + ".sigstore.json")) and
    (.archive.digest | test("^sha256:[0-9a-f]{64}$")) and
    (.archive.sigstoreBundleDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.oci | keys == ["contentAnnotation", "digest", "layerDigest", "reference", "repository", "sigstoreBundle", "sigstoreBundleDigest"]) and
    (.oci.repository == $expected_oci_repository) and
    (.oci.digest | test("^sha256:[0-9a-f]{64}$")) and
    (.oci.reference == (.oci.repository + "@" + .oci.digest)) and
    (.oci.layerDigest == .archive.digest) and
    (.oci.sigstoreBundle == (.pack.name + "-" + .pack.version + ".oci.sigstore.json")) and
    (.oci.contentAnnotation == {name: "dev.cognic.pack.content-sha256", value: .pack.contentSha256}) and
    (.trust | keys == ["cosignVersion", "mode", "publicKey", "publicKeySha256", "trustedRoot", "trustedRootSha256"]) and
    .trust.cosignVersion == "3.1.3" and .trust.mode == "kms-public-key-private-tsa" and
    (.trust.publicKey == (.pack.name + "-" + .pack.version + ".public.pem")) and
    (.trust.trustedRoot == (.pack.name + "-" + .pack.version + ".trusted-root.json")) and
    (.trust.publicKeySha256 | test("^[0-9a-f]{64}$")) and
    (.trust.trustedRootSha256 | test("^[0-9a-f]{64}$")) and
    ($manifest_name == (.pack.name + "-" + .pack.version + ".release.json"))
  ' "$manifest" >/dev/null || fail MANIFEST 'public release manifest violates its strict contract'

archive_name=$(jq -er '.archive.file' "$manifest")
archive_bundle_name=$(jq -er '.archive.sigstoreBundle' "$manifest")
oci_bundle_name=$(jq -er '.oci.sigstoreBundle' "$manifest")
public_key_name=$(jq -er '.trust.publicKey' "$manifest")
trusted_root_name=$(jq -er '.trust.trustedRoot' "$manifest")
for asset_name in \
  "$archive_name" "$archive_bundle_name" "$oci_bundle_name" \
  "$public_key_name" "$trusted_root_name" "$manifest_name" SHA256SUMS; do
  [[ "$asset_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]+$ ]] || \
    fail MANIFEST "manifest contains an unsafe asset name: ${asset_name}"
done

expected_assets="${scratch}/expected-assets"
printf '%s\n' \
  "$archive_name" \
  "$archive_bundle_name" \
  "$manifest_name" \
  "$oci_bundle_name" \
  "$public_key_name" \
  SHA256SUMS \
  "$trusted_root_name" | sort > "$expected_assets"
jq -r '.assets[].name' "$metadata" | sort > "${scratch}/remote-assets"
diff -u "$expected_assets" "${scratch}/remote-assets" >/dev/null || \
  fail ASSETS 'public release asset set is not exact'

while IFS= read -r asset_name; do
  [[ "$asset_name" == "$manifest_name" ]] && continue
  download "${download_base}/${asset_name}" "${scratch}/${asset_name}" || \
    fail DOWNLOAD "public release asset is absent or unreadable: ${asset_name}"
done < "$expected_assets"

while IFS= read -r asset_name; do
  remote_asset=$(jq -cer --arg name "$asset_name" '
    [.assets[] | select(.name == $name)] |
    if length == 1 then .[0] else error("asset identity is not unique") end
  ' "$metadata") || fail ASSETS "public release asset identity is not unique: ${asset_name}"
  expected_size=$(jq -er '.size' <<<"$remote_asset")
  actual_size=$(wc -c < "${scratch}/${asset_name}" | awk '{print $1}')
  [[ "$actual_size" == "$expected_size" ]] || \
    fail DIGEST "public GitHub asset size differs after round trip: ${asset_name}"
  expected_remote=$(jq -r '.digest' <<<"$remote_asset")
  actual="sha256:$(sha256sum "${scratch}/${asset_name}" | awk '{print $1}')"
  if [[ "$expected_remote" != null ]]; then
    [[ "$expected_remote" =~ ^sha256:[0-9a-f]{64}$ && "$actual" == "$expected_remote" ]] || \
      fail DIGEST "available GitHub asset digest differs after round trip: ${asset_name}"
  fi
done < "$expected_assets"

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
' "${scratch}/SHA256SUMS" | sort > "$checksum_names"; then
  fail CHECKSUM_MANIFEST 'public SHA256SUMS has malformed or unsafe entries'
fi
grep -vFx SHA256SUMS "$expected_assets" > "${scratch}/expected-checksum-names"
diff -u "${scratch}/expected-checksum-names" "$checksum_names" >/dev/null || \
  fail CHECKSUM_MANIFEST 'public SHA256SUMS must cover every non-checksum asset exactly once'
if ! (
  cd "$scratch"
  sha256sum --check --strict --status SHA256SUMS
); then
  fail CHECKSUM 'public release SHA256SUMS does not cover the exact downloaded bytes'
fi
archive="${scratch}/${archive_name}"
archive_bundle="${scratch}/${archive_bundle_name}"
oci_bundle="${scratch}/${oci_bundle_name}"
public_key="${scratch}/${public_key_name}"
trusted_root="${scratch}/${trusted_root_name}"
[[ "sha256:$(sha256sum "$archive" | awk '{print $1}')" == "$(jq -er '.archive.digest' "$manifest")" ]] || \
  fail DIGEST 'public tarball differs from the immutable release manifest'
[[ "sha256:$(sha256sum "$archive_bundle" | awk '{print $1}')" == "$(jq -er '.archive.sigstoreBundleDigest' "$manifest")" ]] || \
  fail DIGEST 'public tarball bundle differs from the immutable release manifest'
[[ "sha256:$(sha256sum "$oci_bundle" | awk '{print $1}')" == "$(jq -er '.oci.sigstoreBundleDigest' "$manifest")" ]] || \
  fail DIGEST 'public OCI bundle differs from the immutable release manifest'
actual_public_key_sha256=$(sha256sum "$public_key" | awk '{print $1}')
actual_trusted_root_sha256=$(sha256sum "$trusted_root" | awk '{print $1}')
[[ "$actual_public_key_sha256" == "$expected_public_key_sha256" ]] || \
  fail TRUST 'public key differs from the independently pinned fingerprint'
[[ "$actual_trusted_root_sha256" == "$expected_trusted_root_sha256" ]] || \
  fail TRUST 'trusted root differs from the independently pinned fingerprint'
[[ "$actual_public_key_sha256" == "$(jq -er '.trust.publicKeySha256' "$manifest")" ]] || \
  fail TRUST 'immutable release manifest declares another public key'
[[ "$actual_trusted_root_sha256" == "$(jq -er '.trust.trustedRootSha256' "$manifest")" ]] || \
  fail TRUST 'immutable release manifest declares another trusted root'
for signature_bundle in "$archive_bundle" "$oci_bundle"; do
  jq -e 'type == "object"' "$signature_bundle" >/dev/null || \
    fail SIGNATURE 'published signature bundle is not a JSON object'
done
jq -e '
  (.tlogs | type == "array" and length == 0) and
  (.certificateAuthorities | type == "array" and length == 0) and
  (.ctlogs | type == "array" and length == 0) and
  (.timestampAuthorities | type == "array" and length == 1) and
  (.timestampAuthorities[0].uri | test("^https://")) and
  (.timestampAuthorities[0].certChain.certificates | type == "array" and length >= 2)
' "$trusted_root" >/dev/null || fail TRUST 'published trusted root is not private-TSA-only Cognic shape'

if ! "$cosign_bin" verify-blob \
  --bundle "$archive_bundle" \
  --key "$public_key" \
  --insecure-ignore-tlog=true \
  --trusted-root "$trusted_root" \
  --use-signed-timestamps \
  "$archive" >/dev/null; then
  fail SIGNATURE 'public tarball failed KMS/private-TSA verification'
fi

prefix="$(jq -er '.pack.name' "$manifest")-$(jq -er '.pack.version' "$manifest")/"
source_date_epoch=$(jq -er '.source.sourceDateEpoch' "$manifest")
ruby -r rubygems/package -r zlib -e '
  archive, prefix, epoch, source_sha = ARGV
  expected_epoch = Integer(epoch, 10)
  names = []
  Zlib::GzipReader.open(archive) do |gzip|
    Gem::Package::TarReader.new(gzip) do |tar|
      tar.each do |entry|
        header = entry.header
        name = entry.full_name
        if names.empty? && name == "pax_global_header" && header.typeflag == "g"
          abort "non-zero archive ownership" unless header.uid == 0 && header.gid == 0
          abort "archive mtime drift" unless header.mtime == expected_epoch
          abort "archive source binding drift" unless entry.read.match?(
            /\A[0-9]+ comment=#{Regexp.escape(source_sha)}\n\z/
          )
          next
        end
        abort "unsafe archive path" unless name.start_with?(prefix) &&
          !name.delete_prefix(prefix).split("/").include?("..")
        abort "unsafe archive entry type" unless entry.file? || entry.directory?
        abort "non-zero archive ownership" unless header.uid == 0 && header.gid == 0
        abort "archive mtime drift" unless header.mtime == expected_epoch
        mode = header.mode & 0o777
        allowed = entry.directory? ? [0o755] : [0o644, 0o755]
        abort "archive mode drift" unless allowed.include?(mode)
        names << name
      end
    end
  end
  abort "empty archive" if names.empty?
  abort "archive order drift" unless names == names.sort
' "$archive" "$prefix" "$source_date_epoch" "$source_sha" || \
  fail ARCHIVE_METADATA 'public tarball order, ownership, mode, path, type, mtime, or source binding is not canonical'
extract_dir="${scratch}/extract"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir" || fail ARCHIVE 'public tarball cannot be extracted'
validation=$("$validator" --json "${extract_dir}/${prefix%/}") || \
  fail VALIDATOR 'canonical validator rejected the public tarball'
jq -e \
  --arg name "$(jq -er '.pack.name' "$manifest")" \
  --arg version "$(jq -er '.pack.version' "$manifest")" \
  --arg manifest_sha "$(jq -er '.pack.manifestSha256' "$manifest")" \
  --arg content_sha "$(jq -er '.pack.contentSha256' "$manifest")" '
    .status == "valid" and .name == $name and .version == $version and
    .manifestSha256 == $manifest_sha and .contentSha256 == $content_sha
  ' <<<"$validation" >/dev/null || \
  fail VALIDATOR 'public tarball content differs from the immutable release manifest'

oci_ref=$(jq -er '.oci.reference' "$manifest")
oci_manifest="${scratch}/oci-manifest.json"
retry_capture "$oci_manifest" "$oras_bin" manifest fetch "$oci_ref" || \
  fail OCI_PUBLIC 'public OCI artifact is absent or unreadable after four bounded attempts'
oci_created=$(ruby -r time -e \
  'puts Time.at(Integer(ARGV.fetch(0), 10)).utc.iso8601' "$source_date_epoch") || \
  fail SOURCE_TIME 'public source commit time cannot be rendered as RFC 3339 UTC'
archive_size=$(wc -c < "$archive" | awk '{print $1}')
[[ "$archive_size" =~ ^[1-9][0-9]*$ ]] || fail ARCHIVE 'public tarball size is malformed'
jq -e \
  --arg layer "$(jq -er '.oci.layerDigest' "$manifest")" \
  --arg title "$archive_name" \
  --arg created "$oci_created" \
  --arg source "$source_repository" \
  --arg revision "$source_sha" \
  --arg version "$(jq -er '.pack.version' "$manifest")" \
  --argjson layer_size "$archive_size" '
    .schemaVersion == 2 and
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    .artifactType == "application/vnd.cognic.pack.v1" and
    .config == {
      mediaType: "application/vnd.oci.empty.v1+json",
      digest: "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
      size: 2,
      data: "e30="
    } and
    (.layers | length == 1) and
    .layers[0].mediaType == "application/vnd.cognic.pack.v1.tar+gzip" and
    .layers[0].digest == $layer and
    .layers[0].size == $layer_size and
    .layers[0].annotations == {"org.opencontainers.image.title": $title} and
    .annotations == {
      "org.opencontainers.image.created": $created,
      "org.opencontainers.image.source": $source,
      "org.opencontainers.image.revision": $revision,
      "org.opencontainers.image.version": $version
    }
  ' "$oci_manifest" >/dev/null || \
  fail OCI_PUBLIC 'public OCI artifact does not have the exact deterministic pack shape'
verification="${scratch}/oci-verification.json"
retry_capture "$verification" \
  "$cosign_bin" verify \
    --key "$public_key" \
    --insecure-ignore-tlog=true \
    --trusted-root "$trusted_root" \
    --use-signed-timestamps \
    --output=json \
    "$oci_ref" || \
  fail SIGNATURE 'public OCI signature failed PackSignatureVerifier-compatible verification after four bounded attempts'
jq -e \
  --arg digest "$(jq -er '.oci.digest' "$manifest")" \
  --arg content "$(jq -er '.pack.contentSha256' "$manifest")" '
    type == "array" and length > 0 and
    all(.[];
      .critical.image["docker-manifest-digest"] == $digest and
      .optional["dev.cognic.pack.content-sha256"] == $content
    )
  ' "$verification" >/dev/null || \
  fail SIGNATURE 'public OCI verification output differs from PackSignatureVerifier contract'

final_archive_digest=$(jq -er '.archive.digest' "$manifest")
final_content_sha256=$(jq -er '.pack.contentSha256' "$manifest")
rm -rf -- "$scratch"
trap - EXIT
printf 'PUBLISHED_PACK_VERIFY_OK: tag=%s archive=%s oci=%s content=sha256:%s\n' \
  "$tag" "$final_archive_digest" "$oci_ref" "$final_content_sha256"
