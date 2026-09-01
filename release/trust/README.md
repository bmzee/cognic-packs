# Release trust material

This directory holds public verification material only. It must never contain a
private signing key, token, password, or cloud credential.

`pack-validator.lock.json` will name a checksum-pinned Cognic KMS public key and
private-TSA-only trusted root here when signed validator evidence produced by
the private `cognic-app` release lane is mirrored to the lock's public
distribution release. The source repository remains private and is never a
public fetch dependency. Until then the lock remains `status: blocked`, and CI
deliberately fails rather than building or substituting another validator.

Official pack releases derive their public key from the configured KMS during
the protected release job and construct the trusted root from public TSA
certificate-chain metadata. Both public files are published with each pack
release. Their SHA-256 fingerprints are recorded in `.release.json`, which is
covered by `SHA256SUMS` and sealed by GitHub Release immutability but is not
separately Cosign-signed. Independently distributed fingerprints remain the
authoritative trust pins for consumers.
