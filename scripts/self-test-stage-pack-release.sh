#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'PACK_RELEASE_STAGE_SELF_TEST_FAIL[%s]: %s\n' "$1" "$2" >&2
  exit 1
}

[[ $# == 0 ]] || fail USAGE "usage: $0"
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
stager="${script_dir}/stage-pack-release.sh"
fake_bin="${script_dir}/testdata/fake-bin"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/cognic-pack-stage-self-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

repository="${scratch}/repository"
mkdir -p \
  "${repository}/packs/fixture-pack/agents/fixture" \
  "${repository}/packs/other-pack/agents/other"
printf '%s\n' \
  'name: fixture-pack' \
  'version: 1.2.3' \
  'schema_version: 1' > "${repository}/packs/fixture-pack/pack.yaml"
printf '%s\n' 'fixture agent' > "${repository}/packs/fixture-pack/agents/fixture/agent.md"
printf '%s\n' \
  'name: other-pack' \
  'version: 4.5.6' \
  'schema_version: 1' > "${repository}/packs/other-pack/pack.yaml"
printf '%s\n' 'other agent' > "${repository}/packs/other-pack/agents/other/agent.md"

git -C "$repository" init -q
git -C "$repository" config user.name 'Release Lane Fixture'
git -C "$repository" config user.email 'release-lane@example.invalid'
git -C "$repository" add -- packs
GIT_AUTHOR_DATE='2026-05-03T03:33:20Z' \
GIT_COMMITTER_DATE='2026-05-03T03:33:20Z' \
  git -C "$repository" commit -qm 'fixture packs'
source_sha=$(git -C "$repository" rev-parse HEAD)
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

run_stage() {
  local output_dir=$1
  mkdir -p "$output_dir"
  PACK_RELEASE_RETRY_DELAY_SECONDS=0 \
  FAKE_ORAS_STATE_DIR="${scratch}/oras-state" \
  FAKE_COSIGN_STATE_DIR="${scratch}/cosign-state" \
  FAKE_COSIGN_LOG="${scratch}/cosign.log" \
  GITHUB_RUN_ID=1234 \
  GITHUB_RUN_ATTEMPT=1 \
    "$stager" \
      --repo-root "$repository" \
      --source-sha "$source_sha" \
      --source-repository https://github.com/example/cognic-packs \
      --tag fixture-pack-v1.2.3 \
      --validator "${fake_bin}/pack-validator" \
      --output-dir "$output_dir" \
      --oci-repository "$oci_repository" \
      --key azurekms://fixture.vault.azure.net/release/key-version \
      --public-key "${scratch}/public.pem" \
      --signing-config "${scratch}/signing-config.json" \
      --trusted-root "${scratch}/trusted-root.json" \
      --cosign "${fake_bin}/cosign-release" \
      --oras "${fake_bin}/oras"
}

positive=$(run_stage "${scratch}/output-green") || fail GREEN 'valid release fixture was refused'
grep -Fq 'PACK_RELEASE_STAGE_OK:' <<<"$positive" || fail GREEN 'success marker is missing'
manifest="${scratch}/output-green/fixture-pack-1.2.3.release.json"
jq -e '
  .tag == "fixture-pack-v1.2.3" and
  .pack.name == "fixture-pack" and .pack.version == "1.2.3" and
  .oci.contentAnnotation.name == "dev.cognic.pack.content-sha256" and
  .oci.contentAnnotation.value == .pack.contentSha256 and
  .oci.layerDigest == .archive.digest and
  .trust.mode == "kms-public-key-private-tsa"
' "$manifest" >/dev/null || fail MANIFEST 'release manifest does not bind pack, archive, OCI, and trust'
(
  cd "${scratch}/output-green"
  sha256sum --check --strict --status SHA256SUMS
) || fail CHECKSUM 'staged SHA256SUMS did not verify'
first_archive_sha=$(sha256sum "${scratch}/output-green/fixture-pack-1.2.3.tar.gz" | awk '{print $1}')
first_oci_digest=$(jq -er '.oci.digest' "$manifest")

rm -rf -- "${scratch}/oras-state" "${scratch}/cosign-state"
restore=$(run_stage "${scratch}/output-restored") || fail RESTORE 'second identical release fixture was refused'
grep -Fq 'PACK_RELEASE_STAGE_OK:' <<<"$restore" || fail RESTORE 'restored run omitted its success marker'
[[ "$first_archive_sha" == "$(sha256sum "${scratch}/output-restored/fixture-pack-1.2.3.tar.gz" | awk '{print $1}')" ]] || \
  fail REPRODUCIBILITY 'two releases of the same commit produced different tarball bytes'
[[ "$first_oci_digest" == "$(jq -er '.oci.digest' \
  "${scratch}/output-restored/fixture-pack-1.2.3.release.json")" ]] || \
  fail REPRODUCIBILITY 'two releases of the same commit produced different OCI manifest digests'

rm -rf -- "${scratch}/oras-state" "${scratch}/cosign-state"
if digest_output=$(FAKE_ORAS_CORRUPT_LAYER=true run_stage \
  "${scratch}/output-digest" 2>&1); then
  fail MUTATION 'corrupt public OCI layer digest unexpectedly passed'
fi
grep -Fq 'PACK_RELEASE_STAGE_FAIL[OCI_CONTENT]' <<<"$digest_output" || \
  fail MUTATION "corrupt digest failed without OCI_CONTENT: ${digest_output}"
[[ -z "$(find "${scratch}/output-digest" -mindepth 1 -print -quit)" ]] || \
  fail TRANSACTION 'corrupt OCI digest left partial release assets'

rm -rf -- "${scratch}/oras-state" "${scratch}/cosign-state"
if push_output=$(FAKE_ORAS_BAD_PUSH_OUTPUT=true run_stage \
  "${scratch}/output-push-schema" 2>&1); then
  fail MUTATION 'obsolete nested ORAS push output unexpectedly passed'
fi
grep -Fq 'PACK_RELEASE_STAGE_FAIL[OCI_PUSH]' <<<"$push_output" || \
  fail MUTATION "obsolete ORAS output failed without OCI_PUSH: ${push_output}"
[[ -z "$(find "${scratch}/output-push-schema" -mindepth 1 -print -quit)" ]] || \
  fail TRANSACTION 'invalid ORAS push output left partial release assets'

rm -rf -- "${scratch}/oras-state" "${scratch}/cosign-state"
if cut_output=$(FAKE_COSIGN_VERIFY_FAIL=true run_stage \
  "${scratch}/output-cut" 2>&1); then
  fail MUTATION 'cut OCI verification unexpectedly passed'
fi
grep -Fq 'PACK_RELEASE_STAGE_FAIL[SIGNATURE]' <<<"$cut_output" || \
  fail MUTATION "cut verification failed without SIGNATURE: ${cut_output}"
[[ -z "$(find "${scratch}/output-cut" -mindepth 1 -print -quit)" ]] || \
  fail TRANSACTION 'cut verification left partial release assets'

printf '%s\n' 'not a pack directory' > "${repository}/packs/unexpected.txt"
git -C "$repository" add -- packs/unexpected.txt
GIT_AUTHOR_DATE='2026-05-03T03:34:20Z' \
GIT_COMMITTER_DATE='2026-05-03T03:34:20Z' \
  git -C "$repository" commit -qm 'add invalid top-level pack entry'
source_sha=$(git -C "$repository" rev-parse HEAD)
rm -rf -- "${scratch}/oras-state" "${scratch}/cosign-state"
if pack_set_output=$(run_stage "${scratch}/output-pack-set" 2>&1); then
  fail MUTATION 'top-level non-pack entry unexpectedly passed repository validation'
fi
grep -Fq 'PACK_RELEASE_STAGE_FAIL[PACK_SET]' <<<"$pack_set_output" || \
  fail MUTATION "top-level non-pack entry failed without PACK_SET: ${pack_set_output}"
[[ -z "$(find "${scratch}/output-pack-set" -mindepth 1 -print -quit)" ]] || \
  fail TRANSACTION 'invalid top-level pack entry left partial release assets'

printf '%s\n' \
  'PACK_RELEASE_STAGE_SELF_TEST_OK: valid=green tar_and_oci_reproducible=green corrupt_oci_digest=red invalid_oras_schema=red verification_cut=red invalid_pack_entry=red transactional=green'
