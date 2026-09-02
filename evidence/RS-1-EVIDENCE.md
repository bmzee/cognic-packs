# RS-1 release/signing lane evidence

Captured: `2026-09-01T11:21:52Z`
Worktree: `/Users/bmz/development/cognic-packs-laned`
Branch/base: `feat/release-signing-lane` at
`51d4cf88c91c3afbeb38bee9e96366d6900a02a0` (`origin/master`)

## Result

The release-lane implementation and all locally executable static, mutation,
transactionality, and real-tool compatibility gates are green. Live signed-pack
acceptance is **blocked, not waived**: eligible signed validator evidence has
not been mirrored to a public distribution release, this repository has no
release identity/configuration, and the local demo coordinate is already
occupied by different unsigned immutable evidence. No `signatureVerified: true`
transcript exists yet, and none is fabricated below.

The intentional fail-closed lock means first CI is expected to stop with
`PACK_VALIDATOR_FETCH_FAIL[LOCK_UNAVAILABLE]` until the public distribution
release exists. It must not be replaced with a local build.

## Acceptance contract read at source

Acceptance target:
`cognic-app/crates/pack-registry/src/signature.rs` at the reviewed app source.
The implemented OCI signature matches its exact requirements:

- digest-pinned `repository@sha256:<64 lowercase hex>` artifact identity;
- checksum-pinned Cosign v3.1.3;
- public-key verification with `--insecure-ignore-tlog=true`, a
  private-TSA-only trusted root, and `--use-signed-timestamps`;
- non-empty JSON signature array in which every signature reports the requested
  Docker manifest digest; and
- signed annotation
  `dev.cognic.pack.content-sha256=<canonical loaded-pack content hash>` on every
  signature.

The release lane uses GitHub OIDC to obtain an Azure workload identity, then an
Azure KMS key plus private RFC 3161 TSA. Pure keyless Fulcio/Rekor signing is not
used because it does not satisfy this public-key/private-signed-timestamp
verifier contract.

## Proven-template comparison and stated deviations

Reference reviewed:
`cognic-app/.github/workflows/release.yml` and
`cognic-app/infra/provenance/sign-and-stage-pack-validator-release-evidence.sh`
plus its self-test.

| Area | Template alignment | Pack-lane deviation and reason |
|---|---|---|
| Signing authority | Same reviewed versioned Azure KMS key, public-key fingerprint, private TSA, certificate-chain fingerprint, generated trusted-root fingerprint, Cosign 3.1.3, and OIDC-only credential posture | Repository/environment-specific federated subject is required so copying the public lane does not grant another repository signing access |
| Canonical validator | Signed outer evidence archive, strict checksums/manifest, per-binary signature, static ELF/architecture/version checks, and no fallback | `sourceRepository` remains private provenance metadata while `distributionRepository` selects a trustless public mirror; the signed manifest commit must exactly equal the reviewed lock `acceptanceCommit`, and the ready path makes no request to the private source repository |
| Published subject | Deterministic source-derived bytes, KMS/private-TSA blob signature, immediate verify, exact checksums, bounded retry | Packs additionally require a Cosign signature attached to a digest-pinned public OCI manifest because that is the subject the install verifier checks |
| Determinism | Fixed source commit, commit time, ownership, modes, ordering, gzip metadata, and two-build equality | OCI creation/source/revision/version annotations, empty config, relative layer title, layer size/digest, and manifest shape are fixed too, making the OCI manifest digest reproducible; every canonical pack name closes over a bounded `pack-sha256-<sha256(name)>` GHCR repository mapping |
| Public verification | Verify staged bytes and what was published in the same job | Pack verification deliberately drops GitHub and registry credentials, requires an immutable exact seven-asset release, exact release title/notes, independent source/release/trust pins, exact API sizes and any populated API digests, complete checksums, and anonymous OCI reads |
| Reruns | Fail closed around irreversible publication | Exact drafts may be emptied and resumed; exact immutable releases may be adopted only after OIDC reauthentication, independent KMS/root derivation, and full public verification; no published release is overwritten |

## Local gates

The complete local gate set reports:

```text
BASH_SYNTAX_OK scripts=14
SHELLCHECK_INVENTORY_OK scripts=14
SHELLCHECK_OK scripts=14
WORKFLOW_YAML_OK files=2
ACTION_PINS_OK
WORKFLOW_EMBEDDED_BASH_OK
PACK_VALIDATOR_FETCH_SELF_TEST_OK: valid=green combined_evidence=green stale_source=red distribution_mismatch=red source_as_distribution=red corrupt_digest=red restored=green extra_validator=red verification_cut=red missing_artifact=red
PACK_RELEASE_STAGE_SELF_TEST_OK: valid=green tar_and_oci_reproducible=green corrupt_oci_digest=red invalid_oras_schema=red verification_cut=red invalid_pack_entry=red transactional=green
PUBLISHED_PACK_VERIFY_SELF_TEST_OK: valid=green nullable_api_digest=green source_substitution=red corrupt_digest=red restored=green checksum_omission=red trust_substitution=red verification_cut=red mutable_release=red missing_asset=red
COSIGN_SELF_TEST_OK: kms_sign=green private_tsa_verify=green mutation=red restored=green
SIGNING_AUTHORITY_SCHEMA_OK
PACK_CONTENT_UNTOUCHED_OK
FAIL_CLOSED_LOCK_SCHEMA_OK
FAIL_CLOSED_BOOTSTRAP_OK
PUBLIC_REPO_SECRET_SCAN_OK
READY_PATH_PRIVATE_SOURCE_NETWORK_FREE_OK
GIT_DIFF_CHECK_OK
```

The mutation gates prove that a signed validator manifest attesting any commit
other than the reviewed lock commit, a `baseUrl` outside
`distributionRepository`, use of the private source (even with different case)
as distribution, a corrupt signed digest, substituted release content or trust,
a cut signature check, an omitted checksum or asset, even a checksummed
undeclared validator payload inside otherwise accepted combined app evidence, a
mutable release, the obsolete ORAS JSON shape, or an invalid top-level pack
entry makes the lane red and leaves no partial staged assets. They also prove
that GitHub's temporarily nullable asset-digest field is safe only while exact
remote sizes, complete `SHA256SUMS`, signed subjects, and independent pins
remain enforced. Restoring the signed bytes returns the relevant gates to
green.

## Real pinned-tool compatibility evidence

Official release metadata reports these exact Linux workflow assets:

```text
oras_1.3.3_linux_amd64.tar.gz sha256:9ce999f8d2de03fc03968b29d743077a58783e545e5eaa53917ca177352d0e59
cosign-linux-amd64             sha256:4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
```

The official ORAS v1.3.3 Darwin/arm64 archive was independently downloaded to a
temporary directory, matched its published
`f33fc12753c54172b0d0d19eaa0318d3f90fe9b094d96e8b259c881713c92e1c`
SHA-256, and executed against a local OCI layout. The actual v1.3.3 output uses
top-level `digest`, `reference`, `mediaType`, `artifactType`, `size`,
`annotations`, and `referenceAsTags`. The exact strict parser passed, and two
pushes with identical content and fixed annotations returned:

```text
REAL_ORAS_1_3_3_CONTRACT_OK digest=sha256:88ece5ed6d31fd90d4d4b62272aae5b28e8dcc816c3222ee1f5a858fa433c68b
```

The fetched manifest had the enforced OCI 1.1 empty config, one exact pack
layer, relative archive-title annotation, and fixed creation/source/revision/
version annotations.

## Current external blockers

Read-only GitHub state at capture time (authenticated where labeled):

```text
authenticated cognic-app release metadata:
  engine-v0.150.1 -> 01877e835d4bef2ac49fc9167051d3727a7a979d
  engine-v0.145.0 -> e691ea2978589154e9aa20f67b6796976c82658e
both predate e24638dc586501695e0752d5dd41801b04531064
unauthenticated cognic-app releases API endpoint -> HTTP 404

cognic-packs releases: 0
cognic-packs tags: []
cognic-packs Actions variables: []
cognic-packs environments: []
cognic-packs rulesets: []
cognic-packs immutable releases: {"enabled":false,"enforced_by_owner":false}
local signer inputs present: 0
local Azure login state: unavailable
```

The source-repository 404 is expected: `cognic-app` remains private by standing
policy and is no longer a ready-path dependency. The actual validator blocker
is the absence of mirrored signed evidence in a public distribution release;
`cognic-packs releases: 0` captures that state. Together with the missing
release controls and signer configuration, these facts prevent the canonical
validator fetch, protected-tag release job, real KMS/private-TSA signing,
immutable publication, and consumer-path verification required before live
installation.

Per the fix-round scope, the committed blocked lock is byte-identical to the
previously reviewed staging. Its legacy `reason` text records that earlier
blocked capture; it is not a ready-path source-network requirement.

## Live demo transcript and coordinate collision

Read-only command (local demo database URL redacted):

```console
DATABASE_URL='<redacted-local-demo-url>' \
  /Users/bmz/development/cognic-app-laned/target/debug/cognic \
  --json pack status gl-reconciler@0.1.0
```

Actual live record:

```json
{"artifactDigest":"demo-unsigned.invalid/gl-reconciler@sha256:41cae4f1fb1bd1140e57f4e6241da6a271157270e6533ed45b93bd3f159a0fd2","contentSha256":"41cae4f1fb1bd1140e57f4e6241da6a271157270e6533ed45b93bd3f159a0fd2","coordinate":"gl-reconciler@0.1.0","evalsGreen":false,"grantSha256":"c1df8d04cfc3f376d601af529841a3e00515ca1074acdc434ded58fbb194e5f1","manifestSha256":"ea5838c866d6316a26ebe6998359e6a550a3c36643adc39c6b219605259ddc90","manifestValid":true,"name":"gl-reconciler","publisher":"anthropic-fsi","registrations":[],"riskTier":"baseline","signatureVerified":false,"status":"quarantined","version":"0.1.0"}
```

The diagnostic local validator reports current master source as:

```json
{"contentSha256":"405c08e26737adc426d39bb302f20f952ec81e754d4d148d128bc0974bd63d32","manifestSha256":"4ea1e919657b996d1540a3923c21b56996b0d71d256ec22f40369302ecba695f","name":"gl-reconciler","status":"valid","version":"0.1.0"}
```

That local validator is diagnostic evidence only; it is never a CI/release
substitute. The current source and registry hashes differ. Registry install is
immutable for a coordinate and returns an install collision when any stored
content, artifact digest, signature identity, or trust fingerprint differs.
Consequently, even after a real signed artifact exists, acceptance requires an
operator-approved removal/reset of this demo-only unsigned row or a fresh demo
database. No destructive registry action was taken.

The missing proof remains this real post-install predicate:

```text
coordinate=gl-reconciler@0.1.0
status=quarantined
signatureVerified=true
manifestValid=true
evalsGreen=false
```

## Unblock and finish acceptance

1. Have the private `cognic-app` release lane produce signed static validator
   evidence for the exact reviewed commit
   `e24638dc586501695e0752d5dd41801b04531064`. Publish the evidence archive
   (validators, their signatures, signed source manifest, and `SHA256SUMS`),
   outer signature bundle, and public trust material to an immutable,
   unauthenticated release in the public `distributionRepository`. Flip the
   lock to `ready` with `sourceRepository`, `distributionRepository`, the exact
   signed commit, and all digest/trust pins. `cognic-app` remains private; no
   `cognic-app` URL or source API request belongs in the public fetch path.
2. Configure the protected `release` environment, repository-specific Azure
   OIDC federation, committed authority-matching variables, protected release
   tag ruleset, immutable GitHub Releases, and public GHCR package namespace.
3. Land this lane, create the protected `gl-reconciler-v0.1.0` tag from current
   `master`, and require the same job's real Cosign self-test and anonymous
   post-publication verifier to pass.
4. With operator approval, use a fresh demo registry or remove only the existing
   unsigned demo coordinate; then install the extracted immutable release using
   its digest-pinned OCI reference and independently pinned Cosign/public-key/
   trusted-root hashes.
5. Attach the resulting live `signatureVerified: true`, `manifestValid: true`,
   `evalsGreen: false`, `status: quarantined` transcript here. Do not synthesize
   evaluation evidence or activate the pack.

## Intended staged manifest

No pack content is changed. The review index contains only:

```text
.github/workflows/ci.yml
.github/workflows/release.yml
README.md
RELEASING.md
evidence/RS-1-EVIDENCE.md
release/pack-validator.lock.json
release/signing-authority.json
release/trust/README.md
scripts/cosign-self-test.sh
scripts/fetch-and-verify-pack-validator.sh
scripts/self-test-fetch-and-verify-pack-validator.sh
scripts/self-test-stage-pack-release.sh
scripts/self-test-verify-published-pack-release.sh
scripts/shellcheck-files.txt
scripts/stage-pack-release.sh
scripts/testdata/cosign/public.pem
scripts/testdata/cosign/signing-config.json
scripts/testdata/cosign/trusted-root.json
scripts/testdata/fake-bin/cosign
scripts/testdata/fake-bin/cosign-release
scripts/testdata/fake-bin/curl
scripts/testdata/fake-bin/curl-release
scripts/testdata/fake-bin/oras
scripts/testdata/fake-bin/pack-validator
scripts/testdata/fake-bin/readelf
scripts/verify-published-pack-release.sh
```

No commit, push, release, tag, or pull request was created.
