# Public sources

Every implementation dependency or material design reference must be recorded
here before use.

| Source | Purpose | Pinning or verification |
|---|---|---|
| <https://github.com/openclaw/rfcs/pull/58> | Public architecture and scope | Review the current PR revision before implementation |
| <https://github.com/openclaw/openclaw> | OpenClaw payload source | Workflow input resolves to and records a full commit SHA; the archive hash and `public-upstream` content origin are recorded |
| <https://nodejs.org/> | Node.js runtime and documentation | Use an explicit version and official checksums |
| <https://learn.microsoft.com/windows/msix/> | Public MSIX platform documentation | Record material pages in the implementing PR |
| <https://learn.microsoft.com/dotnet/> | Public .NET documentation | Pin the SDK when the host project is introduced |
| <https://docs.github.com/actions> | GitHub Actions documentation | Third-party actions are pinned to full commit SHAs |
| <https://www.npmjs.com/> | Public JavaScript package registry | OpenClaw lockfile and generated provenance identify resolved inputs |

## Recording a new source

Add its canonical public URL, the implementation purpose, and an immutable
version, commit, checksum, or other verification method. A public URL alone is
not sufficient provenance for a binary.

Payloads marked `public-upstream` are accepted only from the official OpenClaw
repository at a full commit SHA. Package inspection verifies provenance,
archive integrity, entry paths, and entry types without treating public
upstream source examples and syntax definitions as private-data findings.
Artifacts built from this repository use `repository-build` and receive full
content scanning.
