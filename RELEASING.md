# Releasing Cognic packs

This repository is the public reference release lane for Cognic pack authors.
It deliberately separates three things that are easy to conflate:

- a pack directory is authoring source;
- a deterministic `tar.gz` is a portable copy of that source; and
- a digest-pinned OCI artifact with a verifier-compatible Cosign signature is
  the production admission identity.

The pull-request gate is [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
The tag-driven publisher is
[`.github/workflows/release.yml`](.github/workflows/release.yml). The scripts in
[`scripts/`](scripts/) hold the fail-closed checks so that the same invariants
can be exercised outside workflow YAML.

## The install verifier contract

`signatureVerified: true` is not inferred from a release page, a checksum file,
or a detached tarball signature. Cognic's `PackSignatureVerifier` accepts only
all of the following:

1. The artifact identity is an OCI reference of the form
   `repository@sha256:<64 lowercase hexadecimal characters>`. Tags are refused.
2. The exact, checksum-pinned executable is Cosign v3.1.3.
3. Cosign verifies the remote OCI reference with the release public key and a
   private-TSA-only trusted root, using the equivalent of:

   ```console
   cosign verify \
     --key PACK.public.pem \
     --insecure-ignore-tlog=true \
     --trusted-root PACK.trusted-root.json \
     --use-signed-timestamps \
     --output=json \
     REPOSITORY@sha256:DIGEST
   ```

4. Cosign returns a non-empty JSON signature array. Every signature must report
   the requested OCI manifest digest at
   `critical.image["docker-manifest-digest"]`.
5. Every signature must carry the exact signed annotation
   `dev.cognic.pack.content-sha256=<contentSha256>`, where the value is the hash
   produced by Cognic's canonical, closed-manifest pack loader for the unpacked
   source being installed.
6. The public key, trusted root, and Cosign executable bytes match the SHA-256
   fingerprints supplied to `cognic pack install`.
7. The trusted root has empty `tlogs`, `certificateAuthorities`, and `ctlogs`
   arrays and exactly one HTTPS timestamp authority whose certificate chain has
   at least two certificates.

The registry records the artifact digest, the signed content hash, the two
trust-material fingerprints, and the signature identity
`kms-public-key-sha256:<public-key-sha256>`. A tarball signature is also
published and verified, but it protects the downloadable transport artifact;
it is not a substitute for the OCI signature checked during installation.

### Why GitHub OIDC, Azure KMS, and a private TSA

This is intentionally not a keyless Fulcio/Rekor lane. The current installer
contract verifies with a pinned public key, disables public transparency-log
lookup, and requires a signed timestamp rooted in the supplied private-TSA
trust material. A keyless identity certificate would not satisfy that
contract.

The release job therefore exchanges GitHub's short-lived OIDC identity for an
Azure workload identity, then asks a single Azure KMS key to sign. The private
key never enters GitHub, the repository, an Actions secret, or a workflow
artifact. The TSA certificate chain and KMS public key are public verification
material. A short-lived GitHub token is used for GitHub Release and GHCR writes;
there are no static cloud or signing credentials in the repository.

The official lane pins the already-reviewed Cognic release HSM key and private
TSA in [`release/signing-authority.json`](release/signing-authority.json), the
same authority used by the proven engine and canonical-validator release lane.
Reusing that verifier-compatible authority avoids introducing an unreviewed
second trust root; a repository-and-`release`-environment-specific OIDC subject
still confines which workflow may ask it to sign. The committed file, not
mutable GitHub variables, is the review authority for the KMS URI, public-key
fingerprint, TSA identity, certificate-chain fingerprint, and generated
trusted-root fingerprint.

## One-time repository and signing setup

Create a protected GitHub environment named `release`. Require the review policy
appropriate for the publisher, and restrict deployment branches/tags to the
release policy. Enable immutable GitHub Releases before publishing the first
tag, then set the protected environment assertion
`RELEASE_IMMUTABILITY_ENABLED=true`. That assertion records the operator's
precondition and makes an absent configuration fail before publication; it is
not a substitute for enabling the setting because the workflow token cannot
read GitHub's administration-only live state. The authoritative same-job
public verifier requires the resulting release API object to report
`immutable: true`.

Allow the workflow only the scoped permissions declared in `release.yml`:
`contents: write`, `packages: write`, and `id-token: write`. Make each GHCR
package public so that an unauthenticated consumer can fetch both the pack
manifest and Cosign signature. The workflow derives the canonical repository
from the exact canonical pack-name bytes:

```console
PACK_NAME_SHA256=$(printf '%s' "$PACK_NAME" | sha256sum | awk '{print $1}')
OCI_REPOSITORY="ghcr.io/${LOWERCASE_OWNER}/cognic-packs/pack-sha256-${PACK_NAME_SHA256}"
```

This closed mapping supports every valid Cognic pack name, including one-byte
names and repeated separators, without depending on a registry's component
grammar or length limit. The public release manifest maps the readable pack
name to that repository and binds the resulting digest-pinned OCI reference.

A new GHCR package does not exist before its first push and normally starts
private. Configure an organization policy that creates public packages when
appropriate, or use this fail-closed bootstrap for each new pack namespace: let
the protected workflow push its candidate OCI artifact; expect the anonymous
OCI preflight to fail before any GitHub Release draft is created; change that
exact package to public in GitHub's package settings; then rerun the same tag
workflow. Never weaken or authenticate the anonymous preflight. See GitHub's
[package visibility guidance](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).

Configure an Azure application/federated credential for the GitHub
`release`-environment subject, and grant it only the ability required to sign
with the selected Key Vault key. Do not create a client secret. Set these as
GitHub repository or `release` environment **variables**; none is an Actions
secret, including the public certificate-chain PEM. The KMS URI, public-key
fingerprint, TSA URI, operator, validity start, and certificate-chain
fingerprint must equal `release/signing-authority.json`. The certificate PEM
must hash to the committed chain fingerprint, and the trusted root derived from
it must hash to the committed trusted-root fingerprint. Azure identity IDs and
the immutability assertion are repository-specific operational values:

| Variable | Required value |
|---|---|
| `AZURE_CLIENT_ID` | Client ID of the Azure workload identity trusted for this repository's `release` environment |
| `AZURE_TENANT_ID` | Azure tenant containing that identity |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription containing the signing resource |
| `COSIGN_KMS_KEY_URI` | Exact Cosign `azurekms://...` URI for the release key |
| `COSIGN_KMS_PUBLIC_KEY_SHA256` | Lowercase SHA-256 of the KMS public-key PEM emitted by Cosign |
| `COSIGN_TSA_URI` | HTTPS URL of the private RFC 3161 timestamp authority |
| `COSIGN_TSA_OPERATOR` | Stable operator identifier accepted by the signing configuration |
| `COSIGN_TSA_VALIDITY_START` | UTC validity boundary in `YYYY-MM-DDTHH:MM:SSZ` form |
| `COSIGN_TSA_CERTIFICATE_CHAIN_PEM` | Public TSA leaf/intermediate/root chain used to construct the trusted root |
| `COSIGN_TSA_CERTIFICATE_CHAIN_SHA256` | Lowercase SHA-256 of the exact PEM bytes above |
| `RELEASE_IMMUTABILITY_ENABLED` | Literal `true`, set only after immutable GitHub Releases are enabled |

Pin the federated credential to this repository and environment, pin Azure
authorization to the one signing key, and distribute the expected public-key
and trusted-root fingerprints through a channel independent of the release
assets. `SHA256SUMS` detects changed bytes; an independently pinned trust root
is what prevents replacement of both an asset and its advertised checksum.

Required GitHub controls are a ruleset that makes `<pack-name>-v*` tags protected,
required CI on the source branch, the chosen `release`-environment review
policy, and immutable releases. The workflow refuses a tag for which GitHub does
not report protected status. Never publish from an unreviewed pack-content
change.

## Canonical validator bootstrap

Pull-request and release jobs do not build `cognic-pack-validate` locally. They
read [`release/pack-validator.lock.json`](release/pack-validator.lock.json),
download the named evidence archive and Sigstore bundle from the lock's public
distribution repository, and then verify, in order:

- the strict separation between private-source provenance and public artifact
  distribution, including a `baseUrl` derived only from
  `distributionRepository` and a case-insensitive rejection when that
  repository is the private `sourceRepository`;
- the lock's archive and bundle SHA-256 values;
- the outer KMS/private-TSA signature;
- the combined app-evidence archive's safe top-level file layout and exact
  `SHA256SUMS` coverage, plus closure of its validator namespace against the
  signed validator manifest;
- the signed release manifest's source commit, requiring it to equal the lock's
  reviewed `acceptanceCommit` exactly, plus its version, platforms, and inner
  hashes;
- the selected binary's own KMS/private-TSA signature;
- the runner architecture, static ELF linkage, and reported validator version.

Only those verified bytes are installed and executed. A missing asset, private
or authenticated-only URL, stale digest, invalid signature, wrong architecture,
dynamic executable, or malformed archive fails the job. There is no local
build, Docker image, or open-source stand-in fallback.

A ready lock has only these top-level fields:

```json
{
  "acceptanceCommit": "<reviewed exact 40-character source commit>",
  "archive": {"name": "PACK-VALIDATOR-EVIDENCE.tar.gz", "sha256": "..."},
  "baseUrl": "https://github.com/bmzee/cognic-packs/releases/download/TAG",
  "bundle": {"name": "PACK-VALIDATOR-EVIDENCE.tar.gz.sigstore.json", "sha256": "..."},
  "distributionRepository": "bmzee/cognic-packs",
  "releaseTag": "...",
  "releaseVersion": "...",
  "schemaVersion": "1",
  "sourceRepository": "bmzee/cognic-app",
  "sourceSha": "<same exact commit as acceptanceCommit>",
  "status": "ready",
  "trust": {
    "publicKey": "trust/FILE.pem",
    "publicKeySha256": "<64 lowercase hex>",
    "trustedRoot": "trust/FILE.json",
    "trustedRootSha256": "<64 lowercase hex>"
  },
  "validatorVersion": "..."
}
```

### Release revisions

The private `cognic-app` lane may re-release the **same pinned engine** with
newer application evidence as `engine-v<version>-r<n>` (`n ≥ 2`; the base
release is the implicit revision 1). A revision carries the identical pinned
engine binary (the lane proves per-arch hash equality against the base
release before publishing) and newer supervisor/validator evidence. The lock
admits exactly `engine-v<releaseVersion>` or `engine-v<releaseVersion>-r<n>`
with `n` a positive integer ≥ 2 and no leading zeros; every other suffix is
rejected by the strict lock schema (self-test cases `revision` and
`malformed_revision`). Public distribution is `bmzee/cognic-releases`, a
distribution-only repository that never holds source; the reviewer mirrors
the sealed archive and bundle byte-for-byte and verifies the public bytes
before flipping this lock to `ready`.

### Current bootstrap blocker

The checked-in lock currently has `status: blocked`: there is no publicly
distributed signed validator evidence for commit
`e24638dc586501695e0752d5dd41801b04531064` (the canonical pack-validator
release-staging commit). CI and release publication are expected to fail loudly
at this gate. That red state is intentional and must not be silenced.

To unblock the lane, the private `cognic-app` release lane produces the signed
static validator evidence for one exact reviewed source commit. Mirror its
evidence archive (containing the validators, their signatures, strict
`SHA256SUMS`, signed source manifest, and other checksummed app release
evidence), outer signature bundle, and public trust material to an immutable,
unauthenticated release in the public
`distributionRepository`. Add the public key and private-TSA trusted root under
`release/trust/`, fingerprint every referenced byte, and replace the blocked
lock with the strict `ready` shape above. The private source repository is never
queried by the ready path: no `cognic-app` URL or GitHub source API call appears
in public fetching. Digest, signature, and trust pins make the public mirror
deliberately trustless. Run both distribution/source mutation legs before
review. Do not point the lock at an unsigned binary or make CI build one.

## Pull-request gate

Every pull request runs two jobs:

1. Parse all workflow YAML, require every action or container reference to be
   immutable, run ShellCheck across every repository shell script, and run the
   release-lane self-tests.
2. Fetch the canonical validator through the lock above and run it against
   every directory immediately beneath `packs/`.

The ShellCheck inventory is closed: adding a `.sh` file or shell-shebang script
without adding it to `scripts/shellcheck-files.txt` makes CI red, so new helpers
cannot silently escape linting. The self-tests prove both green and red paths.
They corrupt a signed digest, cut verification while preserving plausible
bytes, remove an expected asset, and restore the original input to green. The
staging test also builds the same source twice and compares bytes. A helper that
can no longer make the mutation red is itself red.

## Tag and publish flow

The release tag is `<pack-name>-v<manifest-version>`, for example
`gl-reconciler-v0.1.0`. It must select exactly one pack, the directory name must
equal `pack.yaml`'s `name`, and the semantic version in the tag must equal the
manifest version. Releases are cut only from a clean, reviewed commit; the
release job does not edit pack source or manufacture a version. The triggering
tag must be protected and resolve to the exact current `origin/master` commit.

For example, after the desired commit is on the protected source branch:

```console
PACK_NAME=gl-reconciler
PACK_VERSION=0.1.0
RELEASE_TAG="${PACK_NAME}-v${PACK_VERSION}"

git fetch --prune origin
test -z "$(git status --porcelain=v1 --untracked-files=all)"
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)"
git tag --annotate "$RELEASE_TAG" --message "Release ${PACK_NAME} ${PACK_VERSION}"
git push origin "$RELEASE_TAG"
```

One same-job transaction then:

1. rechecks the exact tag, source commit, clean tree, tool pins, shell scripts,
   self-tests, and every pack with the canonical validator;
2. obtains Azure credentials through GitHub OIDC and derives the public key
   from the configured KMS URI, refusing any fingerprint or TSA-chain drift;
3. signs and verifies a probe, corrupts the probe so verification must fail,
   restores it, and requires verification to return green;
4. creates the pack archive twice and requires byte-for-byte equality;
5. pushes the archive as the one
   `application/vnd.cognic.pack.v1.tar+gzip` layer of a public OCI artifact;
6. signs the exact OCI digest with the required content-hash annotation and
   immediately verifies it with the installer-equivalent command;
7. signs the deterministic tarball and immediately verifies that signature;
8. stages the exact release assets and checks `SHA256SUMS`;
9. uploads a draft, checks the uploaded bytes, publishes it immutably, drops
   authenticated read state, and verifies the release and OCI artifact again
   through the public URLs a consumer uses.

Registry, KMS, TSA, and release-download operations use bounded retries. A
missing artifact or exhausted retry fails the transaction; it never selects a
different implementation.

A rerun first classifies existing release state. An exact draft for the same tag
and source commit is resumed only after its partial assets are deleted with
bounded retries and the draft is observed empty; the complete seven-file set is
then uploaded and round-tripped again. An exact already-published immutable
release is adopted without rebuilding or resigning. Adoption still
reauthenticates through GitHub OIDC, derives and pins the KMS public key and
private-TSA trusted root, and supplies those independent fingerprints to the
full empty-auth public verifier; the release cannot appoint its own trust
material. Any existing release with a different target, state, tag, or
mutability fails instead of being overwritten.

### Deterministic archive contract

The archive is generated from the exact Git commit, not the working tree.
Apart from Git's source-binding pax global header, the tarball has a single
`<name>-<version>/` prefix, sorted paths, only regular files and directories,
UID/GID zero, the source commit time for every mtime, canonical `0644`/`0755`
modes, and gzip without a timestamp or original filename. The OCI manifest has
exactly one pack layer whose digest and size equal the tarball, a stable layer
title equal to the archive basename, and a creation annotation rendered from the
source commit time. Its source, revision, and version annotations are also fixed.
Consequently, both the tarball bytes and the OCI manifest digest are reproducible
for the same source commit while retaining source binding in the tar and OCI
metadata.

### Published assets

For `NAME` and `VERSION`, the GitHub release contains exactly:

```text
NAME-VERSION.tar.gz
NAME-VERSION.tar.gz.sigstore.json
NAME-VERSION.oci.sigstore.json
NAME-VERSION.public.pem
NAME-VERSION.trusted-root.json
NAME-VERSION.release.json
SHA256SUMS
```

The `.release.json` is an immutable, prepublication-hash-pinned manifest. The
job calculates its SHA-256 before draft upload and requires those exact bytes in
the authoritative public round trip. It binds the Git source, canonical pack
manifest and content hashes, archive digest, immutable OCI digest/reference,
signed annotation, bundle digests, Cosign version, and trust-material
fingerprints.

The release title is exactly the tag. Its machine-checked notes repeat the
source SHA, canonical source manifest and content hashes, and prepublication
release-manifest SHA-256. Those notes are a public consistency check, not a
trust bootstrap: publishers must also distribute the same pins through a
durable channel independent of the release assets.

The release manifest is not separately Cosign-signed. The two Cosign-signed
subjects are the deterministic tarball bytes and the immutable OCI manifest
digest. The `.oci.sigstore.json` asset is portable evidence; the install
verifier still queries the signature attached to the digest-pinned public OCI
artifact.

## Consumer verification and signed installation

Start from an expected release tag, source SHA, canonical source manifest and
content hashes, release-manifest SHA-256, and trust fingerprints obtained
independently of the release assets. The two source hashes must come from
running the canonical validator against the independently expected tagged
source, or from an equivalently durable publisher channel. Use a
checksum-pinned Cosign v3.1.3 and ORAS v1.3.3, then fetch the canonical
validator through the committed lock and run the reference public verifier:

```console
REPOSITORY=bmzee/cognic-packs
SOURCE_SHA='40-lowercase-hex-from-independent-source'
SOURCE_MANIFEST_SHA256='64-lowercase-hex-from-canonical-source-validation'
SOURCE_CONTENT_SHA256='64-lowercase-hex-from-canonical-source-validation'
RELEASE_MANIFEST_SHA256='64-lowercase-hex-from-independent-source'
PUBLIC_KEY_SHA256='64-lowercase-hex-from-independent-source'
TRUSTED_ROOT_SHA256='64-lowercase-hex-from-independent-source'
VERIFY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cognic-pack-verify.XXXXXX")
mkdir "$VERIFY_ROOT/registry-auth"
printf '%s\n' '{}' > "$VERIFY_ROOT/registry-auth/config.json"

scripts/fetch-and-verify-pack-validator.sh \
  --lock release/pack-validator.lock.json \
  --output "$VERIFY_ROOT/cognic-pack-validate"

env -u GH_TOKEN -u GITHUB_TOKEN \
  DOCKER_CONFIG="$VERIFY_ROOT/registry-auth" \
  scripts/verify-published-pack-release.sh \
    --repository "$REPOSITORY" \
    --tag gl-reconciler-v0.1.0 \
    --source-sha "$SOURCE_SHA" \
    --expected-manifest-sha256 "$SOURCE_MANIFEST_SHA256" \
    --expected-content-sha256 "$SOURCE_CONTENT_SHA256" \
    --manifest-name gl-reconciler-0.1.0.release.json \
    --manifest-sha256 "$RELEASE_MANIFEST_SHA256" \
    --public-key-sha256 "$PUBLIC_KEY_SHA256" \
    --trusted-root-sha256 "$TRUSTED_ROOT_SHA256" \
    --validator "$VERIFY_ROOT/cognic-pack-validate"
```

That helper checks the immutable GitHub release, exact title and notes, exact
seven-asset set, exact API sizes, every API digest when GitHub has populated
one, checksums over every non-checksum asset, independent source and trust
pins, source/tag/namespace bindings, tar signature and canonical metadata,
canonical pack content, deterministic OCI manifest, and installer-compatible
OCI signature through empty unauthenticated registry state. GitHub may report
an asset digest as `null` for a short period; a missing API digest never waives
the exact size, `SHA256SUMS`, signed-subject, or independent-pin checks. Its
essential signature checks are equivalent to:

```console
sha256sum --check --strict SHA256SUMS

cosign verify-blob \
  --bundle gl-reconciler-0.1.0.tar.gz.sigstore.json \
  --key gl-reconciler-0.1.0.public.pem \
  --insecure-ignore-tlog=true \
  --trusted-root gl-reconciler-0.1.0.trusted-root.json \
  --use-signed-timestamps \
  gl-reconciler-0.1.0.tar.gz

OCI_REF=$(jq -er '.oci.reference' gl-reconciler-0.1.0.release.json)
CONTENT_SHA256=$(jq -er '.pack.contentSha256' gl-reconciler-0.1.0.release.json)
cosign verify \
  --key gl-reconciler-0.1.0.public.pem \
  --insecure-ignore-tlog=true \
  --trusted-root gl-reconciler-0.1.0.trusted-root.json \
  --use-signed-timestamps \
  --output=json \
  "$OCI_REF" |
  jq -e --arg digest "${OCI_REF##*@}" --arg content "$CONTENT_SHA256" '
    type == "array" and length > 0 and
    all(.[];
      .critical.image["docker-manifest-digest"] == $digest and
      .optional["dev.cognic.pack.content-sha256"] == $content
    )
  '
```

The verifier uses private scratch space and removes its downloads on success.
For installation, download the same exact seven public assets again and check
their complete checksum set before extracting anything:

```console
TAG=gl-reconciler-v0.1.0
PACK_BASENAME=gl-reconciler-0.1.0
RELEASE_BASE="https://github.com/${REPOSITORY}/releases/download/${TAG}"
ASSET_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cognic-pack-assets.XXXXXX")
chmod 0700 "$ASSET_ROOT"
assets=(
  "${PACK_BASENAME}.tar.gz"
  "${PACK_BASENAME}.tar.gz.sigstore.json"
  "${PACK_BASENAME}.oci.sigstore.json"
  "${PACK_BASENAME}.public.pem"
  "${PACK_BASENAME}.trusted-root.json"
  "${PACK_BASENAME}.release.json"
  SHA256SUMS
)
for asset in "${assets[@]}"; do
  curl --fail --location --silent --show-error \
    --retry 5 --retry-all-errors \
    --output "$ASSET_ROOT/$asset" "$RELEASE_BASE/$asset"
done
cd "$ASSET_ROOT"
sha256sum --check --strict SHA256SUMS
test "$(sha256sum "${PACK_BASENAME}.release.json" | awk '{print $1}')" = \
  "$RELEASE_MANIFEST_SHA256"
OCI_REF=$(jq -er '.oci.reference' "${PACK_BASENAME}.release.json")
```

Compare the exact Cosign executable SHA-256, public-key SHA-256, and
trusted-root SHA-256 with your independent pins before install. The release
artifact is `tar.gz`, not a Cognic `.cpack`. Extract it into a fresh private
directory and install the directory:

```console
COSIGN_BIN=/absolute/path/to/cosign-v3.1.3
COSIGN_SHA256='64-lowercase-hex-from-independent-source'
OPERATOR=release-acceptance

test "$(sha256sum "$COSIGN_BIN" | awk '{print $1}')" = "$COSIGN_SHA256"
test "$(sha256sum "${PACK_BASENAME}.public.pem" | awk '{print $1}')" = \
  "$PUBLIC_KEY_SHA256"
test "$(sha256sum "${PACK_BASENAME}.trusted-root.json" | awk '{print $1}')" = \
  "$TRUSTED_ROOT_SHA256"
EXTRACT_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cognic-pack-install.XXXXXX")
chmod 0700 "$EXTRACT_ROOT"
tar -xzf "${PACK_BASENAME}.tar.gz" -C "$EXTRACT_ROOT"

install_json=$(
  DATABASE_URL="$DATABASE_URL" cognic --json pack install \
    "$EXTRACT_ROOT/gl-reconciler-0.1.0" \
    --artifact-digest "$OCI_REF" \
    --cosign "$COSIGN_BIN" \
    --cosign-sha256 "$COSIGN_SHA256" \
    --public-key "${PACK_BASENAME}.public.pem" \
    --public-key-sha256 "$PUBLIC_KEY_SHA256" \
    --trusted-root "${PACK_BASENAME}.trusted-root.json" \
    --trusted-root-sha256 "$TRUSTED_ROOT_SHA256" \
    --operator "$OPERATOR"
)

jq -e '
  .coordinate == "gl-reconciler@0.1.0" and
  .status == "quarantined" and
  .signatureVerified == true and
  .manifestValid == true and
  .evalsGreen == false
' <<<"$install_json"
```

That quarantined record is the successful signing-lane acceptance state:
`signatureVerified=true`, `manifestValid=true`, and `evalsGreen=false`.
Evaluation evidence is a separate lifecycle step. Do not forge or bypass it to
make activation green; activation must remain unavailable until the real eval
lane records green evidence.

## Adapting the lane in another public pack repository

Copy `.github/workflows/`, `scripts/`, `release/pack-validator.lock.json`,
`release/signing-authority.json`, and the referenced public files under
`release/trust/` together. Then:

1. configure the protected `release` environment, GitHub OIDC federation,
   Azure KMS key, private TSA, public GHCR package, immutable Releases, and the
   variables listed above;
2. change the `master` branch triggers and exact-`origin/master` assertions if
   the destination uses another default branch;
3. replace the signing-authority provenance fields and update the corresponding
   strict schema/value assertions in both workflows; the shipped checks
   intentionally name Cognic's authority source;
4. retain the workflow-derived GitHub source URL and the
   `pack-sha256-<sha256(canonical-pack-name)>` repository mapping beneath the
   lowercase-owner GHCR namespace unless the destination deliberately adopts
   another reviewed namespace convention; keep every OCI reference
   digest-pinned and publicly readable;
5. retain the canonical validator lock as the sole validator source; for newer
   evidence, review the exact private-source `acceptanceCommit`, mirror the
   signed bytes to a public `distributionRepository`, and update every digest
   and trust pin together;
6. preserve the `<pack-name>-v<version>` selection rule, deterministic archive
   rules, media types, exact content-hash annotation, strict asset set, and
   same-job sign/verify/public-round-trip sequence;
7. run ShellCheck and all mutation self-tests before the first real tag; and
8. publish the expected source SHA, canonical source manifest/content hashes,
   release-manifest SHA-256, and KMS public-key/trusted-root fingerprints in a
   durable channel independent of the release assets for consumers and
   deployment operators.

The supplied staging script intentionally accepts `azurekms://` keys only.
External publishers must replace `release/signing-authority.json` with their
own reviewed, versioned KMS/private-TSA authority and configure a matching
repository-specific OIDC federation; they must not inherit Cognic's signing
access merely by copying this repository.
Changing cloud KMS, TSA posture, Cosign version, annotation name, OCI media
types, or trust-root shape is a verifier-contract change, not a repository
branding edit. Prove such a change against the Cognic source contract and add
red-path tests before relying on it.
