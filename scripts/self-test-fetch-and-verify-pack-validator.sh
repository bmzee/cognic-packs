#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'PACK_VALIDATOR_FETCH_SELF_TEST_FAIL[%s]: %s\n' "$1" "$2" >&2
  exit 1
}

[[ $# == 0 ]] || fail USAGE "usage: $0"
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fetcher="${script_dir}/fetch-and-verify-pack-validator.sh"
fake_bin="${script_dir}/testdata/fake-bin"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/cognic-validator-fetch-self-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
acceptance_commit=e24638dc586501695e0752d5dd41801b04531064
source_sha=$acceptance_commit

release_dir="${scratch}/release"
evidence_dir="${scratch}/evidence"
lock_dir="${scratch}/lock"
mkdir -p "$release_dir" "$evidence_dir" "${lock_dir}/trust"

printf '%s\n' 'fixture public key' > "${lock_dir}/trust/public.pem"
jq -n '{
  tlogs: [],
  certificateAuthorities: [],
  ctlogs: [],
  timestampAuthorities: [{
    uri: "https://tsa.example.test/api/v1/timestamp",
    certChain: {certificates: ["leaf", "root"]}
  }]
}' > "${lock_dir}/trust/trusted-root.json"

write_validator() {
  local arch=$1
  local destination="${evidence_dir}/cognic-pack-validate-linux-${arch}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    "# fixture-arch=${arch}" \
    "if [[ \"\${1:-}\" == --version ]]; then" \
    "  printf '%s\\n' 'cognic-pack-validate 0.1.0'" \
    '  exit 0' \
    'fi' \
    "printf '%s\\n' '{\"contentSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"manifestSha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"name\":\"fixture-pack\",\"status\":\"valid\",\"version\":\"1.2.3\"}'" \
    > "$destination"
  chmod 0555 "$destination"
  jq -n --arg sha256 "$(sha256sum "$destination" | awk '{print $1}')" \
    '{sha256: $sha256}' > "${destination}.sigstore.json"
}

write_validator amd64
write_validator arm64
amd64="${evidence_dir}/cognic-pack-validate-linux-amd64"
arm64="${evidence_dir}/cognic-pack-validate-linux-arm64"
jq -S -n \
  --arg source_sha "$source_sha" \
  --arg amd64 "$(sha256sum "$amd64" | awk '{print $1}')" \
  --arg amd64_bundle "$(sha256sum "${amd64}.sigstore.json" | awk '{print $1}')" \
  --arg arm64 "$(sha256sum "$arm64" | awk '{print $1}')" \
  --arg arm64_bundle "$(sha256sum "${arm64}.sigstore.json" | awk '{print $1}')" '
  {
    schemaVersion: "1",
    releaseVersion: "9.8.7",
    source: {
      gitCommit: $source_sha,
      sourceDateEpoch: "1777777777"
    },
    artifacts: [
      {
        platform: "linux/amd64",
        file: "cognic-pack-validate-linux-amd64",
        digest: ("sha256:" + $amd64),
        sigstoreBundle: "cognic-pack-validate-linux-amd64.sigstore.json",
        sigstoreBundleDigest: ("sha256:" + $amd64_bundle)
      },
      {
        platform: "linux/arm64",
        file: "cognic-pack-validate-linux-arm64",
        digest: ("sha256:" + $arm64),
        sigstoreBundle: "cognic-pack-validate-linux-arm64.sigstore.json",
        sigstoreBundleDigest: ("sha256:" + $arm64_bundle)
      }
    ]
  }
' > "${evidence_dir}/pack-validator-binaries.release.json"
jq -S -n \
  --arg source_sha "$source_sha" \
  '{schemaVersion: "fixture-combined-evidence", sourceSha: $source_sha}' > \
  "${evidence_dir}/release.json"

(
  cd "$evidence_dir"
  sha256sum \
    cognic-pack-validate-linux-amd64 \
    cognic-pack-validate-linux-amd64.sigstore.json \
    cognic-pack-validate-linux-arm64 \
    cognic-pack-validate-linux-arm64.sigstore.json \
    pack-validator-binaries.release.json \
    release.json > SHA256SUMS
  tar -czf "${release_dir}/engine-9.8.7-evidence.tar.gz" \
    ./SHA256SUMS \
    ./cognic-pack-validate-linux-amd64 \
    ./cognic-pack-validate-linux-amd64.sigstore.json \
    ./cognic-pack-validate-linux-arm64 \
    ./cognic-pack-validate-linux-arm64.sigstore.json \
    ./pack-validator-binaries.release.json \
    ./release.json
)
archive="${release_dir}/engine-9.8.7-evidence.tar.gz"
jq -n --arg sha256 "$(sha256sum "$archive" | awk '{print $1}')" \
  '{sha256: $sha256}' > "${archive}.sigstore.json"

write_lock() {
  local archive_sha=$1
  local distribution_repository=${2:-bmzee/cognic-packs}
  local release_tag=${4:-engine-v9.8.7}
  local distribution_base_url=${3:-https://github.com/${distribution_repository}/releases/download/${release_tag}}
  jq -S -n \
    --arg acceptance_commit "$acceptance_commit" \
    --arg release_tag "$release_tag" \
    --arg archive_sha "$archive_sha" \
    --arg bundle_sha "$(sha256sum "${archive}.sigstore.json" | awk '{print $1}')" \
    --arg distribution_base_url "$distribution_base_url" \
    --arg distribution_repository "$distribution_repository" \
    --arg public_sha "$(sha256sum "${lock_dir}/trust/public.pem" | awk '{print $1}')" \
    --arg root_sha "$(sha256sum "${lock_dir}/trust/trusted-root.json" | awk '{print $1}')" \
    --arg source_sha "$source_sha" '
    {
      acceptanceCommit: $acceptance_commit,
      distributionRepository: $distribution_repository,
      schemaVersion: "1",
      status: "ready",
      sourceRepository: "bmzee/cognic-app",
      releaseTag: $release_tag,
      releaseVersion: "9.8.7",
      validatorVersion: "0.1.0",
      sourceSha: $source_sha,
      baseUrl: $distribution_base_url,
      archive: {name: "engine-9.8.7-evidence.tar.gz", sha256: $archive_sha},
      bundle: {name: "engine-9.8.7-evidence.tar.gz.sigstore.json", sha256: $bundle_sha},
      trust: {
        publicKey: "trust/public.pem",
        publicKeySha256: $public_sha,
        trustedRoot: "trust/trusted-root.json",
        trustedRootSha256: $root_sha
      }
    }
  ' > "${lock_dir}/pack-validator.lock.json"
}

run_fetch() {
  local output=$1
  local release_tag=${2:-engine-v9.8.7}
  FAKE_RELEASE_BASE_URL="https://github.com/bmzee/cognic-packs/releases/download/${release_tag}" \
  FAKE_RELEASE_DIR="$release_dir" \
  FAKE_CURL_LOG="${scratch}/curl.log" \
  FAKE_COSIGN_LOG="${scratch}/cosign.log" \
    "$fetcher" \
      --lock "${lock_dir}/pack-validator.lock.json" \
      --output "$output" \
      --cosign "${fake_bin}/cosign" \
      --curl "${fake_bin}/curl" \
      --readelf "${fake_bin}/readelf"
}

archive_sha=$(sha256sum "$archive" | awk '{print $1}')
write_lock "$archive_sha"
positive_output=$(run_fetch "${scratch}/validator-green") || \
  fail GREEN 'valid signed release fixture was refused'
grep -Fq 'PACK_VALIDATOR_FETCH_OK:' <<<"$positive_output" || \
  fail GREEN 'positive fetch omitted its success marker'
[[ -x "${scratch}/validator-green" ]] || fail GREEN 'verified validator was not installed'
diff -u <(printf '%s\n' \
  'https://github.com/bmzee/cognic-packs/releases/download/engine-v9.8.7/engine-9.8.7-evidence.tar.gz' \
  'https://github.com/bmzee/cognic-packs/releases/download/engine-v9.8.7/engine-9.8.7-evidence.tar.gz.sigstore.json') \
  "${scratch}/curl.log" >/dev/null || \
  fail GREEN 'positive fetch did not use only the exact public distribution URLs'

# A correctly signed evidence archive must attest the exact reviewed lock
# commit. Rebuild and re-sign the fixture around a different source attestation
# while leaving the lock commit unchanged; the fetch must still fail closed.
cp -- "$archive" "${scratch}/source-archive.green"
cp -- "${archive}.sigstore.json" "${scratch}/source-archive-bundle.green"
cp -- "${evidence_dir}/SHA256SUMS" "${scratch}/source-SHA256SUMS.green"
cp -- "${evidence_dir}/pack-validator-binaries.release.json" \
  "${scratch}/source-manifest.green.json"
stale_source_sha=0123456789abcdef0123456789abcdef01234567
jq --arg source "$stale_source_sha" '.source.gitCommit = $source' \
  "${scratch}/source-manifest.green.json" > \
  "${evidence_dir}/pack-validator-binaries.release.json"
(
  cd "$evidence_dir"
  sha256sum \
    cognic-pack-validate-linux-amd64 \
    cognic-pack-validate-linux-amd64.sigstore.json \
    cognic-pack-validate-linux-arm64 \
    cognic-pack-validate-linux-arm64.sigstore.json \
    pack-validator-binaries.release.json \
    release.json > SHA256SUMS
  tar -czf "$archive" \
    ./SHA256SUMS \
    ./cognic-pack-validate-linux-amd64 \
    ./cognic-pack-validate-linux-amd64.sigstore.json \
    ./cognic-pack-validate-linux-arm64 \
    ./cognic-pack-validate-linux-arm64.sigstore.json \
    ./pack-validator-binaries.release.json \
    ./release.json
)
jq -n --arg sha256 "$(sha256sum "$archive" | awk '{print $1}')" \
  '{sha256: $sha256}' > "${archive}.sigstore.json"
write_lock "$(sha256sum "$archive" | awk '{print $1}')"
if stale_output=$(run_fetch "${scratch}/validator-stale" 2>&1); then
  fail MUTATION 'signed mismatched source attestation unexpectedly passed'
fi
grep -Fq 'PACK_VALIDATOR_FETCH_FAIL[SOURCE_ATTESTATION]' <<<"$stale_output" || \
  fail MUTATION "stale source failed without SOURCE_ATTESTATION: ${stale_output}"
[[ ! -e "${scratch}/validator-stale" ]] || \
  fail TRANSACTION 'stale validator source left an executable output'
mv -- "${scratch}/source-archive.green" "$archive"
mv -- "${scratch}/source-archive-bundle.green" "${archive}.sigstore.json"
mv -- "${scratch}/source-SHA256SUMS.green" "${evidence_dir}/SHA256SUMS"
mv -- "${scratch}/source-manifest.green.json" \
  "${evidence_dir}/pack-validator-binaries.release.json"
write_lock "$archive_sha"
run_fetch "${scratch}/validator-attestation-restored" >/dev/null || \
  fail RESTORE 'restored signed source attestation did not return the gate to green'

# Distribution is trustless but its identity is closed by the reviewed lock.
# A base URL pointing anywhere except distributionRepository must be rejected.
write_lock "$archive_sha" bmzee/cognic-packs \
  https://github.com/example/other-distribution/releases/download/engine-v9.8.7
if distribution_output=$(run_fetch "${scratch}/validator-distribution-mismatch" 2>&1); then
  fail MUTATION 'mismatched public distribution URL unexpectedly passed'
fi
grep -Fq 'PACK_VALIDATOR_FETCH_FAIL[LOCK]' <<<"$distribution_output" || \
  fail MUTATION "distribution mismatch failed without LOCK: ${distribution_output}"
[[ ! -e "${scratch}/validator-distribution-mismatch" ]] || \
  fail TRANSACTION 'distribution mismatch left an executable output'
write_lock "$archive_sha"
run_fetch "${scratch}/validator-distribution-restored" >/dev/null || \
  fail RESTORE 'restored distribution binding did not return the gate to green'

# The private provenance repository can never double as public distribution,
# including through GitHub's case-insensitive repository naming.
write_lock "$archive_sha" BMZEE/COGNIC-APP \
  https://github.com/BMZEE/COGNIC-APP/releases/download/engine-v9.8.7
if source_distribution_output=$(run_fetch "${scratch}/validator-source-distribution" 2>&1); then
  fail MUTATION 'private source repository unexpectedly passed as distribution'
fi
grep -Fq 'PACK_VALIDATOR_FETCH_FAIL[LOCK]' <<<"$source_distribution_output" || \
  fail MUTATION \
    "private source distribution failed without LOCK: ${source_distribution_output}"
[[ ! -e "${scratch}/validator-source-distribution" ]] || \
  fail TRANSACTION 'private source distribution left an executable output'
write_lock "$archive_sha"
run_fetch "${scratch}/validator-source-distribution-restored" >/dev/null || \
  fail RESTORE 'restored source/distribution separation did not return the gate to green'

# Release revisions: the same pinned engine re-released with newer app
# evidence is published as engine-v<version>-r<n> (n >= 2). The lock admits
# exactly that shape; r1 (the implicit base) and any other suffix stay red.
write_lock "$archive_sha" bmzee/cognic-packs \
  https://github.com/bmzee/cognic-packs/releases/download/engine-v9.8.7-r2 engine-v9.8.7-r2
revision_output=$(run_fetch "${scratch}/validator-revision" engine-v9.8.7-r2) || \
  fail REVISION "signed revision release engine-v9.8.7-r2 was refused: ${revision_output}"
grep -Fq 'PACK_VALIDATOR_FETCH_OK:' <<<"$revision_output" || \
  fail REVISION 'revision fetch omitted its success marker'
for bad_tag in engine-v9.8.7-r1 engine-v9.8.7-r0 engine-v9.8.7-r02 engine-v9x8x7-r2 engine-v9.8.9-r2; do
  write_lock "$archive_sha" bmzee/cognic-packs \
    "https://github.com/bmzee/cognic-packs/releases/download/${bad_tag}" "$bad_tag"
  if bad_revision_output=$(run_fetch "${scratch}/validator-revision-${bad_tag}" "$bad_tag" 2>&1); then
    fail MUTATION "malformed revision tag ${bad_tag} unexpectedly passed"
  fi
  grep -Fq 'PACK_VALIDATOR_FETCH_FAIL[LOCK]' <<<"$bad_revision_output" || \
    fail MUTATION "revision tag ${bad_tag} failed without LOCK: ${bad_revision_output}"
  [[ ! -e "${scratch}/validator-revision-${bad_tag}" ]] || \
    fail TRANSACTION "revision tag ${bad_tag} left an executable output"
done
write_lock "$archive_sha"
run_fetch "${scratch}/validator-revision-restored" >/dev/null || \
  fail RESTORE 'restored base release tag did not return the gate to green'

# Required mutation proof: corrupt the pinned digest, observe red, restore it,
# and prove the identical signed fixture returns to green.
write_lock ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
if mutation_output=$(run_fetch "${scratch}/validator-corrupt" 2>&1); then
  fail MUTATION 'corrupt archive digest unexpectedly passed'
fi
grep -Fq 'PACK_VALIDATOR_FETCH_FAIL[DIGEST]' <<<"$mutation_output" || \
  fail MUTATION "corrupt digest failed without the DIGEST marker: ${mutation_output}"
[[ ! -e "${scratch}/validator-corrupt" ]] || \
  fail TRANSACTION 'corrupt digest left an executable output'
write_lock "$archive_sha"
run_fetch "${scratch}/validator-restored" >/dev/null || \
  fail RESTORE 'restored digest did not return the gate to green'

# The canonical app archive contains other release evidence, all covered by its
# outer signature and SHA256SUMS. The validator manifest still closes the
# validator namespace: a freshly signed archive may not smuggle a third binary.
cp -- "$archive" "${scratch}/archive.green"
cp -- "${archive}.sigstore.json" "${scratch}/archive-bundle.green"
cp -- "${evidence_dir}/SHA256SUMS" "${scratch}/evidence-SHA256SUMS.green"
printf '%s\n' smuggled > \
  "${evidence_dir}/cognic-pack-validate-linux-riscv64"
(
  cd "$evidence_dir"
  sha256sum \
    cognic-pack-validate-linux-amd64 \
    cognic-pack-validate-linux-amd64.sigstore.json \
    cognic-pack-validate-linux-arm64 \
    cognic-pack-validate-linux-arm64.sigstore.json \
    pack-validator-binaries.release.json \
    release.json \
    cognic-pack-validate-linux-riscv64 > SHA256SUMS
  tar -czf "$archive" \
    ./SHA256SUMS \
    ./cognic-pack-validate-linux-amd64 \
    ./cognic-pack-validate-linux-amd64.sigstore.json \
    ./cognic-pack-validate-linux-arm64 \
    ./cognic-pack-validate-linux-arm64.sigstore.json \
    ./pack-validator-binaries.release.json \
    ./release.json \
    ./cognic-pack-validate-linux-riscv64
)
jq -n --arg sha256 "$(sha256sum "$archive" | awk '{print $1}')" \
  '{sha256: $sha256}' > "${archive}.sigstore.json"
write_lock "$(sha256sum "$archive" | awk '{print $1}')"
if extra_output=$(run_fetch "${scratch}/validator-extra" 2>&1); then
  fail MUTATION 'signed and checksummed archive with an extra payload unexpectedly passed'
fi
grep -Fq 'PACK_VALIDATOR_FETCH_FAIL[PAYLOAD_SET]' <<<"$extra_output" || \
  fail MUTATION "extra payload failed without PAYLOAD_SET: ${extra_output}"
[[ ! -e "${scratch}/validator-extra" ]] || \
  fail TRANSACTION 'extra payload left an executable output'
mv -- "${scratch}/archive.green" "$archive"
mv -- "${scratch}/archive-bundle.green" "${archive}.sigstore.json"
mv -- "${scratch}/evidence-SHA256SUMS.green" "${evidence_dir}/SHA256SUMS"
rm -f -- "${evidence_dir}/cognic-pack-validate-linux-riscv64"
write_lock "$archive_sha"

if cut_output=$(FAKE_COSIGN_VERIFY_FAIL=true run_fetch \
  "${scratch}/validator-cut" 2>&1); then
  fail MUTATION 'cut signature verification unexpectedly passed'
fi
grep -Fq 'PACK_VALIDATOR_FETCH_FAIL[SIGNATURE]' <<<"$cut_output" || \
  fail MUTATION "cut verification failed without the SIGNATURE marker: ${cut_output}"
[[ ! -e "${scratch}/validator-cut" ]] || \
  fail TRANSACTION 'cut verification left an executable output'

mv "$archive" "${archive}.missing"
if missing_output=$(run_fetch "${scratch}/validator-missing" 2>&1); then
  fail MUTATION 'missing canonical artifact unexpectedly passed'
fi
grep -Fq 'PACK_VALIDATOR_FETCH_FAIL[DOWNLOAD]' <<<"$missing_output" || \
  fail MUTATION "missing artifact failed without the DOWNLOAD marker: ${missing_output}"

printf '%s\n' \
  'PACK_VALIDATOR_FETCH_SELF_TEST_OK: valid=green combined_evidence=green stale_source=red distribution_mismatch=red source_as_distribution=red revision=green malformed_revision=red corrupt_digest=red restored=green extra_validator=red verification_cut=red missing_artifact=red'
