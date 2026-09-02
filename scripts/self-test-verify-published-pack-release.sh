#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'PUBLISHED_PACK_VERIFY_SELF_TEST_FAIL[%s]: %s\n' "$1" "$2" >&2
  exit 1
}

[[ $# == 0 ]] || fail USAGE "usage: $0"
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
stager="${script_dir}/stage-pack-release.sh"
verifier="${script_dir}/verify-published-pack-release.sh"
fake_bin="${script_dir}/testdata/fake-bin"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/cognic-public-release-self-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

repository="${scratch}/repository"
release_dir="${scratch}/public-release"
mkdir -p "${repository}/packs/fixture-pack/agents/fixture" "$release_dir"
printf '%s\n' \
  'name: fixture-pack' \
  'version: 1.2.3' \
  'schema_version: 1' > "${repository}/packs/fixture-pack/pack.yaml"
printf '%s\n' 'fixture agent' > "${repository}/packs/fixture-pack/agents/fixture/agent.md"
git -C "$repository" init -q
git -C "$repository" config user.name 'Release Lane Fixture'
git -C "$repository" config user.email 'release-lane@example.invalid'
git -C "$repository" add -- packs
GIT_AUTHOR_DATE='2026-05-03T03:33:20Z' \
GIT_COMMITTER_DATE='2026-05-03T03:33:20Z' \
  git -C "$repository" commit -qm 'fixture pack'
source_sha=$(git -C "$repository" rev-parse HEAD)
source_validation=$("${fake_bin}/pack-validator" --json "${repository}/packs/fixture-pack")
source_manifest_sha256=$(jq -er '.manifestSha256' <<<"$source_validation")
source_content_sha256=$(jq -er '.contentSha256' <<<"$source_validation")
pack_name_sha256=$(printf '%s' fixture-pack | sha256sum | awk '{print $1}')
oci_repository="ghcr.io/example/cognic-packs/pack-sha256-${pack_name_sha256}"

printf '%s\n' 'fixture public key' > "${scratch}/public.pem"
printf '%s\n' '{}' > "${scratch}/signing-config.json"
jq -n '{
  tlogs: [], certificateAuthorities: [], ctlogs: [],
  timestampAuthorities: [{
    uri: "https://tsa.example.test/api/v1/timestamp",
    certChain: {certificates: ["leaf", "root"]}
  }]
}' > "${scratch}/trusted-root.json"
PACK_RELEASE_RETRY_DELAY_SECONDS=0 \
FAKE_ORAS_STATE_DIR="${scratch}/oras-state" \
FAKE_COSIGN_STATE_DIR="${scratch}/cosign-state" \
FAKE_COSIGN_LOG="${scratch}/cosign.log" \
GITHUB_RUN_ID=5678 \
GITHUB_RUN_ATTEMPT=1 \
  "$stager" \
    --repo-root "$repository" \
    --source-sha "$source_sha" \
    --source-repository https://github.com/example/cognic-packs \
    --tag fixture-pack-v1.2.3 \
    --validator "${fake_bin}/pack-validator" \
    --output-dir "$release_dir" \
    --oci-repository "$oci_repository" \
    --key azurekms://fixture.vault.azure.net/release/key-version \
    --public-key "${scratch}/public.pem" \
    --signing-config "${scratch}/signing-config.json" \
    --trusted-root "${scratch}/trusted-root.json" \
    --cosign "${fake_bin}/cosign-release" \
    --oras "${fake_bin}/oras" >/dev/null || fail FIXTURE 'could not stage the public-release fixture'

assets_json="${scratch}/assets.jsonl"
while IFS= read -r -d '' asset; do
  jq -n \
    --arg name "${asset##*/}" \
    --arg digest "sha256:$(sha256sum "$asset" | awk '{print $1}')" \
    --argjson size "$(wc -c < "$asset" | tr -d ' ')" \
    '{name: $name, digest: $digest, size: $size, state: "uploaded"}' >> "$assets_json"
done < <(find "$release_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
manifest_name=fixture-pack-1.2.3.release.json
manifest_sha=$(sha256sum "${release_dir}/${manifest_name}" | awk '{print $1}')
printf -v release_body \
  "Cognic pack release \`%s\` with signed tar and OCI artifacts.\n\nSource-SHA: \`%s\`\nSource-Pack-Manifest-SHA256: \`%s\`\nSource-Pack-Content-SHA256: \`%s\`\nRelease-Manifest-SHA256: \`%s\`\n" \
  fixture-pack-v1.2.3 "$source_sha" "$source_manifest_sha256" \
  "$source_content_sha256" "$manifest_sha"
jq -S -n \
  --arg tag fixture-pack-v1.2.3 \
  --arg source "$source_sha" \
  --arg body "$release_body" \
  --slurpfile assets "$assets_json" '
  {
    tag_name: $tag,
    name: $tag,
    body: $body,
    target_commitish: $source,
    draft: false,
    prerelease: false,
    immutable: true,
    assets: $assets
  }
' > "${release_dir}/release.json"
run_verify() {
  local expected_manifest_sha256=$1
  local expected_public_key_sha256=${2:-$(sha256sum "${release_dir}/fixture-pack-1.2.3.public.pem" | awk '{print $1}')}
  local expected_trusted_root_sha256=${3:-$(sha256sum "${release_dir}/fixture-pack-1.2.3.trusted-root.json" | awk '{print $1}')}
  local expected_source_manifest_sha256=${4:-$source_manifest_sha256}
  local expected_source_content_sha256=${5:-$source_content_sha256}
  PACK_RELEASE_RETRY_DELAY_SECONDS=0 \
  FAKE_PUBLIC_RELEASE_DIR="$release_dir" \
  FAKE_ORAS_STATE_DIR="${scratch}/oras-state" \
  FAKE_COSIGN_STATE_DIR="${scratch}/cosign-state" \
  FAKE_COSIGN_LOG="${scratch}/cosign.log" \
    "$verifier" \
      --repository example/cognic-packs \
      --tag fixture-pack-v1.2.3 \
      --source-sha "$source_sha" \
      --expected-manifest-sha256 "$expected_source_manifest_sha256" \
      --expected-content-sha256 "$expected_source_content_sha256" \
      --manifest-name "$manifest_name" \
      --manifest-sha256 "$expected_manifest_sha256" \
      --public-key-sha256 "$expected_public_key_sha256" \
      --trusted-root-sha256 "$expected_trusted_root_sha256" \
      --validator "${fake_bin}/pack-validator" \
      --cosign "${fake_bin}/cosign-release" \
      --curl "${fake_bin}/curl-release" \
      --oras "${fake_bin}/oras"
}

positive=$(run_verify "$manifest_sha") || fail GREEN 'valid public release fixture was refused'
grep -Fq 'PUBLISHED_PACK_VERIFY_OK:' <<<"$positive" || fail GREEN 'success marker is missing'

cp -- "${release_dir}/release.json" "${scratch}/release-digests.green.json"
jq '(.assets[].digest) = null' "${scratch}/release-digests.green.json" > \
  "${release_dir}/release.json"
run_verify "$manifest_sha" >/dev/null || \
  fail GREEN 'authoritative public bytes were refused while API digest backfill was pending'
mv -- "${scratch}/release-digests.green.json" "${release_dir}/release.json"

manifest_path="${release_dir}/${manifest_name}"
cp -- "$manifest_path" "${scratch}/source-manifest.green.json"
cp -- "${release_dir}/SHA256SUMS" "${scratch}/source-SHA256SUMS.green"
cp -- "${release_dir}/release.json" "${scratch}/source-release.green.json"
chmod u+w "$manifest_path" "${release_dir}/SHA256SUMS" "${release_dir}/release.json"
substituted_content_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
jq --arg content "$substituted_content_sha256" \
  '.pack.contentSha256 = $content | .oci.contentAnnotation.value = $content' \
  "${scratch}/source-manifest.green.json" > "$manifest_path"
substituted_manifest_sha=$(sha256sum "$manifest_path" | awk '{print $1}')
awk \
  -v digest="$substituted_manifest_sha" \
  -v target="./${manifest_name}" '
    BEGIN { OFS = "  " }
    $2 == target { $1 = digest }
    { print $1, $2 }
  ' "${scratch}/source-SHA256SUMS.green" > "${release_dir}/SHA256SUMS"
printf -v substituted_release_body \
  "Cognic pack release \`%s\` with signed tar and OCI artifacts.\n\nSource-SHA: \`%s\`\nSource-Pack-Manifest-SHA256: \`%s\`\nSource-Pack-Content-SHA256: \`%s\`\nRelease-Manifest-SHA256: \`%s\`\n" \
  fixture-pack-v1.2.3 "$source_sha" "$source_manifest_sha256" \
  "$source_content_sha256" "$substituted_manifest_sha"
jq \
  --arg body "$substituted_release_body" \
  --arg manifest_name "$manifest_name" \
  --arg manifest_digest "sha256:${substituted_manifest_sha}" \
  --argjson manifest_size "$(wc -c < "$manifest_path" | tr -d ' ')" \
  --arg checksums_digest "sha256:$(sha256sum "${release_dir}/SHA256SUMS" | awk '{print $1}')" \
  --argjson checksums_size "$(wc -c < "${release_dir}/SHA256SUMS" | tr -d ' ')" '
    .body = $body |
    (.assets[] | select(.name == $manifest_name).digest) = $manifest_digest |
    (.assets[] | select(.name == $manifest_name).size) = $manifest_size |
    (.assets[] | select(.name == "SHA256SUMS").digest) = $checksums_digest |
    (.assets[] | select(.name == "SHA256SUMS").size) = $checksums_size
  ' "${scratch}/source-release.green.json" > "${release_dir}/release.json"
if source_output=$(run_verify "$substituted_manifest_sha" 2>&1); then
  fail MUTATION 'release-controlled source content assertion unexpectedly passed'
fi
grep -Fq 'PUBLISHED_PACK_VERIFY_FAIL[SOURCE_CONTENT]' <<<"$source_output" || \
  fail MUTATION "source substitution failed without SOURCE_CONTENT: ${source_output}"
mv -- "${scratch}/source-manifest.green.json" "$manifest_path"
mv -- "${scratch}/source-SHA256SUMS.green" "${release_dir}/SHA256SUMS"
mv -- "${scratch}/source-release.green.json" "${release_dir}/release.json"
run_verify "$manifest_sha" >/dev/null || \
  fail RESTORE 'restored independent source binding did not return the gate to green'

cp -- "$manifest_path" "${scratch}/digest-manifest.green.json"
chmod u+w "$manifest_path"
printf '\n' >> "$manifest_path"
if digest_output=$(run_verify "$manifest_sha" 2>&1); then
  fail MUTATION 'corrupt public release manifest unexpectedly passed'
fi
grep -Fq 'PUBLISHED_PACK_VERIFY_FAIL[DIGEST]' <<<"$digest_output" || \
  fail MUTATION "corrupt digest failed without DIGEST: ${digest_output}"
mv -- "${scratch}/digest-manifest.green.json" "$manifest_path"
run_verify "$manifest_sha" >/dev/null || fail RESTORE 'restored manifest digest did not return the gate to green'

cp -- "${release_dir}/SHA256SUMS" "${scratch}/SHA256SUMS.green"
cp -- "${release_dir}/release.json" "${scratch}/release-checksum.green.json"
chmod u+w "${release_dir}/SHA256SUMS" "${release_dir}/release.json"
grep -v 'fixture-pack-1.2.3.public.pem' "${scratch}/SHA256SUMS.green" > \
  "${release_dir}/SHA256SUMS"
jq \
  --arg digest "sha256:$(sha256sum "${release_dir}/SHA256SUMS" | awk '{print $1}')" \
  --argjson size "$(wc -c < "${release_dir}/SHA256SUMS" | tr -d ' ')" '
  (.assets[] | select(.name == "SHA256SUMS").digest) = $digest |
  (.assets[] | select(.name == "SHA256SUMS").size) = $size
' "${scratch}/release-checksum.green.json" > "${release_dir}/release.json"
if checksum_output=$(run_verify "$manifest_sha" 2>&1); then
  fail MUTATION 'SHA256SUMS omission unexpectedly passed'
fi
grep -Fq 'PUBLISHED_PACK_VERIFY_FAIL[CHECKSUM_MANIFEST]' <<<"$checksum_output" || \
  fail MUTATION "SHA256SUMS omission failed without CHECKSUM_MANIFEST: ${checksum_output}"
mv -- "${scratch}/SHA256SUMS.green" "${release_dir}/SHA256SUMS"
mv -- "${scratch}/release-checksum.green.json" "${release_dir}/release.json"
run_verify "$manifest_sha" >/dev/null || \
  fail RESTORE 'restored exact checksum manifest did not return the gate to green'

if trust_output=$(run_verify "$manifest_sha" \
  ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff 2>&1); then
  fail MUTATION 'release-controlled trust substitution unexpectedly passed'
fi
grep -Fq 'PUBLISHED_PACK_VERIFY_FAIL[TRUST]' <<<"$trust_output" || \
  fail MUTATION "trust substitution failed without TRUST: ${trust_output}"
run_verify "$manifest_sha" >/dev/null || \
  fail RESTORE 'restored independent trust pins did not return the gate to green'

if cut_output=$(FAKE_COSIGN_VERIFY_FAIL=true run_verify "$manifest_sha" 2>&1); then
  fail MUTATION 'cut public signature verification unexpectedly passed'
fi
grep -Fq 'PUBLISHED_PACK_VERIFY_FAIL[SIGNATURE]' <<<"$cut_output" || \
  fail MUTATION "cut verification failed without SIGNATURE: ${cut_output}"

cp -- "${release_dir}/release.json" "${scratch}/release.green.json"
jq '.immutable = false' "${scratch}/release.green.json" > "${release_dir}/release.json"
if mutable_output=$(run_verify "$manifest_sha" 2>&1); then
  fail MUTATION 'mutable public release unexpectedly passed'
fi
grep -Fq 'PUBLISHED_PACK_VERIFY_FAIL[RELEASE]' <<<"$mutable_output" || \
  fail MUTATION "mutable release failed without RELEASE: ${mutable_output}"
cp -- "${scratch}/release.green.json" "${release_dir}/release.json"

archive="${release_dir}/fixture-pack-1.2.3.tar.gz"
mv "$archive" "${archive}.missing"
if missing_output=$(run_verify "$manifest_sha" 2>&1); then
  fail MUTATION 'missing public tarball unexpectedly passed'
fi
grep -Fq 'PUBLISHED_PACK_VERIFY_FAIL[DOWNLOAD]' <<<"$missing_output" || \
  fail MUTATION "missing public asset failed without DOWNLOAD: ${missing_output}"

printf '%s\n' \
  'PUBLISHED_PACK_VERIFY_SELF_TEST_OK: valid=green nullable_api_digest=green source_substitution=red corrupt_digest=red restored=green checksum_omission=red trust_substitution=red verification_cut=red mutable_release=red missing_asset=red'
