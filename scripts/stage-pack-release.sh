#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'PACK_RELEASE_STAGE_FAIL[%s]: %s\n' "$1" "$2" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'usage: stage-pack-release.sh --repo-root DIR --source-sha SHA --source-repository URL --tag TAG --validator FILE --output-dir DIR --oci-repository REPOSITORY --key KMS_URI --public-key FILE --signing-config FILE --trusted-root FILE [--cosign FILE] [--oras FILE]'
}

repo_root=''
source_sha=''
source_repository=''
tag=''
validator=''
output_dir=''
oci_repository=''
key=''
public_key=''
signing_config=''
trusted_root=''
cosign_bin=cosign
oras_bin=oras

while (( $# > 0 )); do
  case "$1" in
    --repo-root) (( $# >= 2 )) || fail USAGE '--repo-root requires a directory'; repo_root=$2; shift 2 ;;
    --source-sha) (( $# >= 2 )) || fail USAGE '--source-sha requires a SHA'; source_sha=$2; shift 2 ;;
    --source-repository) (( $# >= 2 )) || fail USAGE '--source-repository requires a URL'; source_repository=$2; shift 2 ;;
    --tag) (( $# >= 2 )) || fail USAGE '--tag requires a value'; tag=$2; shift 2 ;;
    --validator) (( $# >= 2 )) || fail USAGE '--validator requires a file'; validator=$2; shift 2 ;;
    --output-dir) (( $# >= 2 )) || fail USAGE '--output-dir requires a directory'; output_dir=$2; shift 2 ;;
    --oci-repository) (( $# >= 2 )) || fail USAGE '--oci-repository requires a value'; oci_repository=$2; shift 2 ;;
    --key) (( $# >= 2 )) || fail USAGE '--key requires a KMS URI'; key=$2; shift 2 ;;
    --public-key) (( $# >= 2 )) || fail USAGE '--public-key requires a file'; public_key=$2; shift 2 ;;
    --signing-config) (( $# >= 2 )) || fail USAGE '--signing-config requires a file'; signing_config=$2; shift 2 ;;
    --trusted-root) (( $# >= 2 )) || fail USAGE '--trusted-root requires a file'; trusted_root=$2; shift 2 ;;
    --cosign) (( $# >= 2 )) || fail USAGE '--cosign requires a file'; cosign_bin=$2; shift 2 ;;
    --oras) (( $# >= 2 )) || fail USAGE '--oras requires a file'; oras_bin=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail USAGE "unknown argument: $1" ;;
  esac
done

for required_name in \
  repo_root source_sha source_repository tag validator output_dir oci_repository \
  key public_key signing_config trusted_root cosign_bin oras_bin; do
  [[ -n "${!required_name}" ]] || fail USAGE "required value is empty: ${required_name}"
done
[[ -d "$repo_root" && ! -L "$repo_root" ]] || fail REPOSITORY 'repository root is invalid'
[[ -d "$output_dir" && ! -L "$output_dir" ]] || fail OUTPUT 'output directory is invalid'
[[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || \
  fail OUTPUT 'output directory must be empty'
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail SOURCE_SHA 'source SHA must be 40 lowercase hexadecimal characters'
[[ "$source_repository" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  fail SOURCE_REPOSITORY 'source repository must be an exact GitHub HTTPS URL'
[[ "$tag" =~ ^[a-z0-9][a-z0-9._-]*-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  fail TAG 'release tag must be PACK-vSEMVER using the canonical identifier vocabulary'
[[ "$oci_repository" =~ ^ghcr\.io/[a-z0-9]([a-z0-9-]*[a-z0-9])?/cognic-packs/pack-sha256-[0-9a-f]{64}$ ]] || \
  fail OCI_REPOSITORY 'OCI repository is not the canonical hashed pack namespace'
[[ "$key" =~ ^azurekms://[^[:space:]\<\>]+$ ]] || \
  fail KEY 'verifier-compatible signing requires a non-placeholder Azure KMS URI'

for file in "$validator" "$public_key" "$signing_config" "$trusted_root"; do
  [[ -r "$file" && -f "$file" && ! -L "$file" ]] || \
    fail INPUT "required input is not a readable regular non-symlink file: ${file}"
done
[[ -x "$validator" ]] || fail INPUT 'validator must be executable'
for configured in "$cosign_bin" "$oras_bin"; do
  if [[ "$configured" == */* ]]; then
    [[ -x "$configured" && -f "$configured" && ! -L "$configured" ]] || \
      fail TOOL_MISSING "configured tool is not an executable regular non-symlink file: ${configured}"
  else
    command -v "$configured" >/dev/null 2>&1 || \
      fail TOOL_MISSING "configured tool is absent: ${configured}"
  fi
done
for command_name in awk diff find git gzip install jq mktemp ruby sha256sum sort tar tr wc xargs; do
  command -v "$command_name" >/dev/null 2>&1 || \
    fail TOOL_MISSING "required command is absent: ${command_name}"
done

cosign_version=$("$cosign_bin" version 2>&1) || fail COSIGN_VERSION 'cosign version probe failed'
grep -Fxq 'GitVersion:    v3.1.3' <<<"$cosign_version" || \
  fail COSIGN_VERSION 'cosign v3.1.3 is required'
oras_version=$("$oras_bin" version 2>&1) || fail ORAS_VERSION 'ORAS version probe failed'
grep -Eq '^Version:[[:space:]]+1\.3\.3$' <<<"$oras_version" || \
  fail ORAS_VERSION 'ORAS v1.3.3 is required'
jq -e '
  (.tlogs | type == "array" and length == 0) and
  (.certificateAuthorities | type == "array" and length == 0) and
  (.ctlogs | type == "array" and length == 0) and
  (.timestampAuthorities | type == "array" and length == 1) and
  (.timestampAuthorities[0].uri | test("^https://")) and
  (.timestampAuthorities[0].certChain.certificates | type == "array" and length >= 2)
' "$trusted_root" >/dev/null || fail TRUST 'trusted root is not private-TSA-only Cognic shape'

head_sha=$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}') || \
  fail SOURCE_SHA 'repository HEAD cannot be resolved'
[[ "$head_sha" == "$source_sha" ]] || fail SOURCE_SHA 'repository HEAD differs from the requested source SHA'
[[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] || \
  fail SOURCE_DIRTY 'release checkout is not clean'
source_date_epoch=$(git -C "$repo_root" show -s --format=%ct "$source_sha") || \
  fail SOURCE_TIME 'source commit time cannot be read'
[[ "$source_date_epoch" == 0 || "$source_date_epoch" =~ ^[1-9][0-9]*$ ]] || \
  fail SOURCE_TIME 'source commit time is malformed'
source_date_rfc3339=$(ruby -r time -e \
  'puts Time.at(Integer(ARGV.fetch(0), 10)).utc.iso8601' "$source_date_epoch") || \
  fail SOURCE_TIME 'source commit time cannot be rendered as RFC 3339 UTC'
[[ "$source_date_rfc3339" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || \
  fail SOURCE_TIME 'rendered source commit time is malformed'

declare -a matches=()
selected_validation=''
selected_pack_dir=''
while IFS= read -r -d '' pack_dir; do
  [[ -d "$pack_dir" && ! -L "$pack_dir" ]] || \
    fail PACK_SET "packs/ must contain only real pack directories: ${pack_dir##*/}"
  [[ -f "${pack_dir}/pack.yaml" && ! -L "${pack_dir}/pack.yaml" ]] || \
    fail PACK_SET "pack directory has no safe pack.yaml: ${pack_dir##*/}"
  validation=$("$validator" --json "$pack_dir") || \
    fail VALIDATOR "canonical validator rejected pack: ${pack_dir##*/}"
  jq -e '
    .status == "valid" and
    (.name | type == "string" and length >= 1 and length <= 128 and
      test("^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$")) and
    (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.manifestSha256 | test("^[0-9a-f]{64}$")) and
    (.contentSha256 | test("^[0-9a-f]{64}$"))
  ' <<<"$validation" >/dev/null || \
    fail VALIDATOR "canonical validator returned malformed evidence for: ${pack_dir##*/}"
  pack_name=$(jq -er '.name' <<<"$validation")
  pack_version=$(jq -er '.version' <<<"$validation")
  [[ "${pack_dir##*/}" == "$pack_name" ]] || \
    fail PACK_SET "pack directory and manifest name differ: ${pack_dir##*/}"
  if [[ "${pack_name}-v${pack_version}" == "$tag" ]]; then
    matches+=("$pack_dir")
    selected_pack_dir=$pack_dir
    selected_validation=$validation
  fi
done < <(find "${repo_root}/packs" -mindepth 1 -maxdepth 1 -print0 | sort -z)
[[ "${#matches[@]}" == 1 ]] || \
  fail TAG 'release tag must select exactly one canonically validated pack'

pack_name=$(jq -er '.name' <<<"$selected_validation")
pack_version=$(jq -er '.version' <<<"$selected_validation")
manifest_sha256=$(jq -er '.manifestSha256' <<<"$selected_validation")
content_sha256=$(jq -er '.contentSha256' <<<"$selected_validation")
source_path=${source_repository#https://github.com/}
source_owner=${source_path%%/*}
source_owner_lower=$(printf '%s' "$source_owner" | tr '[:upper:]' '[:lower:]')
[[ "$source_owner_lower" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  fail SOURCE_REPOSITORY 'source owner cannot form a canonical GHCR namespace'
pack_name_sha256=$(printf '%s' "$pack_name" | sha256sum | awk '{print $1}')
expected_oci_repository="ghcr.io/${source_owner_lower}/cognic-packs/pack-sha256-${pack_name_sha256}"
[[ "$oci_repository" == "$expected_oci_repository" ]] || \
  fail OCI_REPOSITORY 'OCI repository does not match the source owner and pack-name hash'
archive_name="${pack_name}-${pack_version}.tar.gz"
archive_bundle_name="${archive_name}.sigstore.json"
oci_bundle_name="${pack_name}-${pack_version}.oci.sigstore.json"
manifest_name="${pack_name}-${pack_version}.release.json"
public_key_name="${pack_name}-${pack_version}.public.pem"
trusted_root_name="${pack_name}-${pack_version}.trusted-root.json"

scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cognic-pack-release.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
umask 077

build_archive() {
  local destination=$1
  local tar_file="${destination%.gz}"
  git -c tar.umask=0022 -C "$selected_pack_dir" archive \
    --format=tar \
    --prefix="${pack_name}-${pack_version}/" \
    "$source_sha" . > "$tar_file" || fail ARCHIVE 'git archive failed'
  gzip -n -9 -c "$tar_file" > "$destination" || fail ARCHIVE 'deterministic gzip failed'
  rm -f -- "$tar_file"
  [[ -s "$destination" ]] || fail ARCHIVE 'deterministic archive is empty'
}

archive="${scratch}/${archive_name}"
archive_rebuild="${scratch}/rebuild-${archive_name}"
build_archive "$archive"
build_archive "$archive_rebuild"
archive_sha256=$(sha256sum "$archive" | awk '{print $1}')
archive_size=$(wc -c < "$archive" | awk '{print $1}')
[[ "$archive_size" =~ ^[1-9][0-9]*$ ]] || fail ARCHIVE 'deterministic archive size is malformed'
[[ "$archive_sha256" == "$(sha256sum "$archive_rebuild" | awk '{print $1}')" ]] || \
  fail REPRODUCIBILITY 'building the same source twice produced different archive bytes'

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
' "$archive" "${pack_name}-${pack_version}/" "$source_date_epoch" "$source_sha" || \
  fail ARCHIVE_METADATA 'archive order, ownership, mode, path, type, or mtime is not canonical'

extract_dir="${scratch}/extract"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir" || fail ARCHIVE 'deterministic archive cannot be extracted'
extracted_validation=$("$validator" --json "${extract_dir}/${pack_name}-${pack_version}") || \
  fail ARCHIVE_CONTENT 'canonical validator rejected the extracted release archive'
jq -e \
  --arg name "$pack_name" \
  --arg version "$pack_version" \
  --arg manifest "$manifest_sha256" \
  --arg content "$content_sha256" '
    .status == "valid" and .name == $name and .version == $version and
    .manifestSha256 == $manifest and .contentSha256 == $content
  ' <<<"$extracted_validation" >/dev/null || \
  fail ARCHIVE_CONTENT 'extracted release archive differs from the validated source'

retry_capture() {
  local output_file=$1
  shift 2
  local attempt
  for attempt in 1 2 3 4; do
    rm -f -- "$output_file"
    if "$@" > "$output_file" 2> "${output_file}.error"; then
      rm -f -- "${output_file}.error"
      return 0
    fi
    [[ "$attempt" == 4 ]] || sleep "$((attempt * retry_delay))"
  done
  return 1
}

retry_delay=${PACK_RELEASE_RETRY_DELAY_SECONDS:-1}
[[ "$retry_delay" =~ ^[0-9]+$ ]] || fail INVOCATION 'retry delay must be a non-negative integer'
run_id=${GITHUB_RUN_ID:-local}
run_attempt=${GITHUB_RUN_ATTEMPT:-1}
[[ "$run_id" == local || "$run_id" =~ ^[1-9][0-9]{0,29}$ ]] || \
  fail INVOCATION 'run ID must be local or a bounded positive GitHub run ID'
[[ "$run_attempt" =~ ^[1-9][0-9]{0,9}$ ]] || \
  fail INVOCATION 'run identity is malformed'
candidate_tag="candidate-${source_sha:0:16}-${run_id}-${run_attempt}"
[[ "${#candidate_tag}" -le 128 ]] || fail INVOCATION 'candidate OCI tag exceeds 128 characters'
oci_tag="${oci_repository}:${candidate_tag}"
push_output="${scratch}/oras-push.json"
push_oci() {
  (
    cd "$scratch"
    "$oras_bin" push \
      --artifact-type application/vnd.cognic.pack.v1 \
      --annotation "org.opencontainers.image.created=${source_date_rfc3339}" \
      --annotation "org.opencontainers.image.source=${source_repository}" \
      --annotation "org.opencontainers.image.revision=${source_sha}" \
      --annotation "org.opencontainers.image.version=${pack_version}" \
      --format json \
      "$oci_tag" \
      "${archive_name}:application/vnd.cognic.pack.v1.tar+gzip"
  )
}
retry_capture "$push_output" 'OCI artifact push' push_oci || \
  fail NETWORK 'OCI artifact push failed after four bounded attempts'
jq -e \
  --arg repository "$oci_repository" \
  --arg tag "$oci_tag" \
  --arg created "$source_date_rfc3339" \
  --arg source "$source_repository" \
  --arg revision "$source_sha" \
  --arg version "$pack_version" '
    type == "object" and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    .reference == ($repository + "@" + .digest) and
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    .artifactType == "application/vnd.cognic.pack.v1" and
    (.size | type == "number" and . > 0 and floor == .) and
    .referenceAsTags == [$tag] and
    .annotations["org.opencontainers.image.created"] == $created and
    .annotations["org.opencontainers.image.source"] == $source and
    .annotations["org.opencontainers.image.revision"] == $revision and
    .annotations["org.opencontainers.image.version"] == $version
  ' "$push_output" >/dev/null || \
  fail OCI_PUSH 'ORAS push output did not bind the expected manifest, tag, and annotations'
oci_digest=$(jq -er '.digest' "$push_output") || \
  fail OCI_PUSH 'ORAS push did not return its validated manifest digest'
oci_ref="${oci_repository}@${oci_digest}"

resolved_output="${scratch}/oras-resolve.txt"
retry_capture "$resolved_output" 'OCI digest refetch' "$oras_bin" resolve "$oci_tag" || \
  fail NETWORK 'OCI digest refetch failed after four bounded attempts'
[[ "$(<"$resolved_output")" == "$oci_digest" ]] || \
  fail OCI_PUSH 'registry-refetched candidate tag differs from the pushed digest'
oci_manifest="${scratch}/oci-manifest.json"
retry_capture "$oci_manifest" 'OCI manifest refetch' "$oras_bin" manifest fetch "$oci_ref" || \
  fail NETWORK 'OCI manifest refetch failed after four bounded attempts'
jq -e \
  --arg artifact_digest "sha256:${archive_sha256}" \
  --arg artifact_title "$archive_name" \
  --arg created "$source_date_rfc3339" \
  --arg source "$source_repository" \
  --arg revision "$source_sha" \
  --arg version "$pack_version" \
  --argjson artifact_size "$archive_size" '
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
    .layers[0].digest == $artifact_digest and
    .layers[0].size == $artifact_size and
    .layers[0].annotations == {"org.opencontainers.image.title": $artifact_title} and
    .annotations == {
      "org.opencontainers.image.created": $created,
      "org.opencontainers.image.source": $source,
      "org.opencontainers.image.revision": $revision,
      "org.opencontainers.image.version": $version
    }
  ' "$oci_manifest" >/dev/null || \
  fail OCI_CONTENT 'public OCI manifest does not have the exact deterministic pack shape'

oci_bundle="${scratch}/${oci_bundle_name}"
sign_oci() {
  rm -f -- "$oci_bundle"
  "$cosign_bin" sign \
    --yes \
    --key "$key" \
    --bundle "$oci_bundle" \
    --signing-config "$signing_config" \
    --trusted-root "$trusted_root" \
    --tlog-upload=false \
    --annotations "dev.cognic.pack.content-sha256=${content_sha256}" \
    "$oci_ref" >/dev/null
}
signed=false
for attempt in 1 2 3 4; do
  if sign_oci; then signed=true; break; fi
  [[ "$attempt" == 4 ]] || sleep "$((attempt * retry_delay))"
done
[[ "$signed" == true && -s "$oci_bundle" && -f "$oci_bundle" && ! -L "$oci_bundle" ]] || \
  fail SIGNATURE 'OCI KMS/private-TSA signing failed after four bounded attempts'
jq -e 'type == "object"' "$oci_bundle" >/dev/null || fail SIGNATURE 'OCI signature bundle is not a JSON object'

verification_json="${scratch}/oci-verification.json"
retry_capture "$verification_json" 'OCI signature verification' \
  "$cosign_bin" verify \
    --key "$public_key" \
    --insecure-ignore-tlog=true \
    --trusted-root "$trusted_root" \
    --use-signed-timestamps \
    --output=json \
    "$oci_ref" || fail SIGNATURE 'OCI signature verification failed after four bounded attempts'
jq -e \
  --arg digest "$oci_digest" \
  --arg content "$content_sha256" '
    type == "array" and length > 0 and
    all(.[];
      .critical.image["docker-manifest-digest"] == $digest and
      .optional["dev.cognic.pack.content-sha256"] == $content
    )
  ' "$verification_json" >/dev/null || \
  fail SIGNATURE 'OCI verification output does not match PackSignatureVerifier contract'

archive_bundle="${scratch}/${archive_bundle_name}"
sign_blob() {
  rm -f -- "$archive_bundle"
  "$cosign_bin" sign-blob \
    --yes \
    --key "$key" \
    --bundle "$archive_bundle" \
    --signing-config "$signing_config" \
    --trusted-root "$trusted_root" \
    "$archive" >/dev/null
}
blob_signed=false
for attempt in 1 2 3 4; do
  if sign_blob; then blob_signed=true; break; fi
  [[ "$attempt" == 4 ]] || sleep "$((attempt * retry_delay))"
done
[[ "$blob_signed" == true && -s "$archive_bundle" && -f "$archive_bundle" && ! -L "$archive_bundle" ]] || \
  fail SIGNATURE 'tarball KMS/private-TSA signing failed after four bounded attempts'
if ! "$cosign_bin" verify-blob \
  --bundle "$archive_bundle" \
  --key "$public_key" \
  --insecure-ignore-tlog=true \
  --trusted-root "$trusted_root" \
  --use-signed-timestamps \
  "$archive" >/dev/null; then
  fail SIGNATURE 'tarball failed immediate public-key/private-TSA verification'
fi
[[ "$(sha256sum "$archive" | awk '{print $1}')" == "$archive_sha256" ]] || \
  fail POST_SIGN_DIGEST 'tarball changed during signing or verification'

staging="${scratch}/release-assets"
mkdir -p "$staging"
install -m 0444 "$archive" "${staging}/${archive_name}"
install -m 0444 "$archive_bundle" "${staging}/${archive_bundle_name}"
install -m 0444 "$oci_bundle" "${staging}/${oci_bundle_name}"
install -m 0444 "$public_key" "${staging}/${public_key_name}"
install -m 0444 "$trusted_root" "${staging}/${trusted_root_name}"
public_key_sha256=$(sha256sum "${staging}/${public_key_name}" | awk '{print $1}')
trusted_root_sha256=$(sha256sum "${staging}/${trusted_root_name}" | awk '{print $1}')

jq -S -n \
  --arg tag "$tag" \
  --arg source_repository "$source_repository" \
  --arg source_sha "$source_sha" \
  --arg source_date_epoch "$source_date_epoch" \
  --arg name "$pack_name" \
  --arg version "$pack_version" \
  --arg manifest_sha256 "$manifest_sha256" \
  --arg content_sha256 "$content_sha256" \
  --arg archive_file "$archive_name" \
  --arg archive_sha256 "$archive_sha256" \
  --arg archive_bundle "$archive_bundle_name" \
  --arg archive_bundle_sha256 "$(sha256sum "$archive_bundle" | awk '{print $1}')" \
  --arg oci_repository "$oci_repository" \
  --arg oci_digest "$oci_digest" \
  --arg oci_ref "$oci_ref" \
  --arg oci_bundle "$oci_bundle_name" \
  --arg oci_bundle_sha256 "$(sha256sum "$oci_bundle" | awk '{print $1}')" \
  --arg public_key_file "$public_key_name" \
  --arg public_key_sha256 "$public_key_sha256" \
  --arg trusted_root_file "$trusted_root_name" \
  --arg trusted_root_sha256 "$trusted_root_sha256" '
  {
    schemaVersion: "1",
    tag: $tag,
    source: {
      repository: $source_repository,
      gitCommit: $source_sha,
      sourceDateEpoch: $source_date_epoch
    },
    pack: {
      name: $name,
      version: $version,
      manifestSha256: $manifest_sha256,
      contentSha256: $content_sha256
    },
    archive: {
      file: $archive_file,
      digest: ("sha256:" + $archive_sha256),
      sigstoreBundle: $archive_bundle,
      sigstoreBundleDigest: ("sha256:" + $archive_bundle_sha256)
    },
    oci: {
      repository: $oci_repository,
      digest: $oci_digest,
      reference: $oci_ref,
      layerDigest: ("sha256:" + $archive_sha256),
      contentAnnotation: {
        name: "dev.cognic.pack.content-sha256",
        value: $content_sha256
      },
      sigstoreBundle: $oci_bundle,
      sigstoreBundleDigest: ("sha256:" + $oci_bundle_sha256)
    },
    trust: {
      cosignVersion: "3.1.3",
      mode: "kms-public-key-private-tsa",
      publicKey: $public_key_file,
      publicKeySha256: $public_key_sha256,
      trustedRoot: $trusted_root_file,
      trustedRootSha256: $trusted_root_sha256
    }
  }
' > "${staging}/${manifest_name}"

jq -e '
  keys == ["archive", "oci", "pack", "schemaVersion", "source", "tag", "trust"] and
  .schemaVersion == "1" and
  (.oci.reference == (.oci.repository + "@" + .oci.digest)) and
  (.oci.layerDigest == .archive.digest) and
  (.oci.contentAnnotation.name == "dev.cognic.pack.content-sha256") and
  (.oci.contentAnnotation.value == .pack.contentSha256) and
  (.trust.cosignVersion == "3.1.3") and
  (.trust.mode == "kms-public-key-private-tsa")
' "${staging}/${manifest_name}" >/dev/null || \
  fail MANIFEST 'generated release manifest violates its strict contract'

(
  cd "$staging"
  checksum_file="${scratch}/release-assets.SHA256SUMS"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 | \
    sort -z | xargs -0 sha256sum > "$checksum_file"
  mv "$checksum_file" SHA256SUMS
  sha256sum --check --strict --status SHA256SUMS
) || fail CHECKSUM 'release SHA256SUMS generation or verification failed'

while IFS= read -r -d '' asset; do
  install -m 0444 "$asset" "${output_dir}/${asset##*/}"
done < <(find "$staging" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
manifest_digest=$(sha256sum "${output_dir}/${manifest_name}" | awk '{print $1}')

rm -rf -- "$scratch"
trap - EXIT
printf 'PACK_RELEASE_STAGE_OK: tag=%s archive=sha256:%s oci=%s manifest=sha256:%s\n' \
  "$tag" "$archive_sha256" "$oci_ref" "$manifest_digest"
