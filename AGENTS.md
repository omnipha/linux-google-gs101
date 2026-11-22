# Agent instructions

- Work on `main` only. Do not create development branches; synchronise with
  `git pull --ff-only origin main` before edits and push verified commits to
  `origin/main`.
- Preserve the upstream source attribution and the snapshot-history caveat in
  README.md. The Nura `tensor-master` name refers only to the external source,
  not a development branch in this repository.
- This repository is public. Never commit secrets, private keys, serial numbers,
  device dumps, proprietary firmware blobs or other private device data.
- Record reproducible kernel configuration, build inputs, artifact hashes and
  evidence. A successful compile is not proof of boot, SSH or hardware support.
- No device boot or flash without explicit operator authorization and verified
  identity, target, checksums, backups and device-specific recovery.
