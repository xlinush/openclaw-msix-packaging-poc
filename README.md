# OpenClaw MSIX packaging POC

Proof-of-concept tooling for packaging OpenClaw as an MSIX application on
Windows.

The repository currently builds Windows x64 and ARM64 OpenClaw payload
tarballs in GitHub Actions. It is intended to grow to include the C# MSIX host
application and related packaging infrastructure.

Artifacts produced here are for development and evaluation only.

## Public-development boundary

This is a public, clean-room POC. Implementation must be based only on the
public RFC, upstream OpenClaw, public platform documentation, and other sources
recorded in [PUBLIC-SOURCES.md](PUBLIC-SOURCES.md). Do not copy, translate, or
adapt private source code, build definitions, manifests, binaries, or design
documents.

See [PUBLIC-DEVELOPMENT-POLICY.md](PUBLIC-DEVELOPMENT-POLICY.md) before making
changes. Run the safety check before every commit:

```powershell
pwsh -File .\scripts\Test-PublicSafety.ps1 -Mode Staged -RequireLocalConfiguration
```

Create the ignored local configuration from
[`.public-safety.local.example.json`](.public-safety.local.example.json) before
starting implementation work. CI independently scans the tracked repository,
Git history, and generated payload archives.
