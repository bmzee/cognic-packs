#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'COSIGN_SELF_TEST_FAIL[%s]: %s\n' "$1" "$2" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'usage: cosign-self-test.sh --key KMS_URI --public-key FILE --signing-config FILE --trusted-root FILE [--cosign FILE]'
}

key=''
public_key=''
signing_config=''
trusted_root=''
cosign_bin=cosign
while (( $# > 0 )); do
  case "$1" in
    --key) (( $# >= 2 )) || fail USAGE '--key requires a KMS URI'; key=$2; shift 2 ;;
    --public-key) (( $# >= 2 )) || fail USAGE '--public-key requires a file'; public_key=$2; shift 2 ;;
    --signing-config) (( $# >= 2 )) || fail USAGE '--signing-config requires a file'; signing_config=$2; shift 2 ;;
    --trusted-root) (( $# >= 2 )) || fail USAGE '--trusted-root requires a file'; trusted_root=$2; shift 2 ;;
    --cosign) (( $# >= 2 )) || fail USAGE '--cosign requires a file'; cosign_bin=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail USAGE "unknown argument: $1" ;;
  esac
done

[[ "$key" =~ ^azurekms://[^[:space:]\<\>]+$ ]] || \
  fail KEY 'self-test requires the verifier-compatible Azure KMS identity'
for file in "$public_key" "$signing_config" "$trusted_root"; do
  [[ -r "$file" && -f "$file" && ! -L "$file" ]] || \
    fail INPUT "required input is not a readable regular non-symlink file: ${file}"
done
if [[ "$cosign_bin" == */* ]]; then
  [[ -x "$cosign_bin" && -f "$cosign_bin" && ! -L "$cosign_bin" ]] || \
    fail TOOL_MISSING 'configured cosign is not an executable regular non-symlink file'
else
  command -v "$cosign_bin" >/dev/null 2>&1 || fail TOOL_MISSING 'cosign is absent'
fi
for command_name in jq mktemp sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || \
    fail TOOL_MISSING "required command is absent: ${command_name}"
done
version_output=$("$cosign_bin" version 2>&1) || fail COSIGN_VERSION 'cosign version probe failed'
grep -Fxq 'GitVersion:    v3.1.3' <<<"$version_output" || \
  fail COSIGN_VERSION 'cosign v3.1.3 is required'
jq -e '
  (.tlogs | type == "array" and length == 0) and
  (.certificateAuthorities | type == "array" and length == 0) and
  (.ctlogs | type == "array" and length == 0) and
  (.timestampAuthorities | type == "array" and length == 1) and
  (.timestampAuthorities[0].uri | test("^https://")) and
  (.timestampAuthorities[0].certChain.certificates | type == "array" and length >= 2)
' "$trusted_root" >/dev/null || fail TRUST 'trusted root is not private-TSA-only Cognic shape'

retry_delay=${PACK_RELEASE_RETRY_DELAY_SECONDS:-1}
[[ "$retry_delay" =~ ^[0-9]+$ ]] || fail INVOCATION 'retry delay must be a non-negative integer'
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cognic-cosign-self-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
probe="${scratch}/probe.txt"
original="${scratch}/probe.original.txt"
bundle="${scratch}/probe.sigstore.json"
printf '%s\n' 'cognic-cosign-kms-private-tsa-self-test-v1' > "$probe"
cp -- "$probe" "$original"

signed=false
for attempt in 1 2 3 4; do
  rm -f -- "$bundle"
  if "$cosign_bin" sign-blob \
    --yes \
    --key "$key" \
    --bundle "$bundle" \
    --signing-config "$signing_config" \
    --trusted-root "$trusted_root" \
    "$probe" >/dev/null; then
    signed=true
    break
  fi
  [[ "$attempt" == 4 ]] || sleep "$((attempt * retry_delay))"
done
[[ "$signed" == true && -s "$bundle" && -f "$bundle" && ! -L "$bundle" ]] || \
  fail SIGN 'KMS/private-TSA sign-blob failed after four bounded attempts'
jq -e 'type == "object"' "$bundle" >/dev/null || fail SIGN 'Cosign bundle is not a JSON object'

verify_probe() {
  "$cosign_bin" verify-blob \
    --bundle "$bundle" \
    --key "$public_key" \
    --insecure-ignore-tlog=true \
    --trusted-root "$trusted_root" \
    --use-signed-timestamps \
    "$probe" >/dev/null
}

verified=false
for attempt in 1 2 3 4; do
  if verify_probe; then verified=true; break; fi
  [[ "$attempt" == 4 ]] || sleep "$((attempt * retry_delay))"
done
[[ "$verified" == true ]] || fail VERIFY 'fresh Cosign bundle failed verification'
original_sha256=$(sha256sum "$probe" | awk '{print $1}')

printf '%s\n' mutation >> "$probe"
if verify_probe; then
  fail MUTATION 'signature verification still passed after signed bytes were mutated'
fi
cp -- "$original" "$probe"
[[ "$(sha256sum "$probe" | awk '{print $1}')" == "$original_sha256" ]] || \
  fail RESTORE 'probe bytes were not restored exactly'
verify_probe || fail RESTORE 'restored signed bytes did not return verification to green'

rm -rf -- "$scratch"
trap - EXIT
printf '%s\n' \
  'COSIGN_SELF_TEST_OK: kms_sign=green private_tsa_verify=green mutation=red restored=green'
