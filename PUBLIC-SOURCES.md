# Public sources

Every implementation dependency or material design reference must be recorded
here before use.

| Source | Purpose | Pinning or verification |
|---|---|---|
| <https://github.com/openclaw/rfcs/pull/58> | Public architecture and scope | Host implementation reviewed against RFC commit `d6abbc1d2b45f289d14c1bf7e45a90f1768b5510` |
| <https://github.com/openclaw/openclaw> | OpenClaw payload source | Workflow input resolves to and records a full commit SHA; the archive hash and `public-upstream` content origin are recorded |
| <https://github.com/openclaw/openclaw/blob/b4ffa3106f205a2beef985c9b43887d7c2a6091f/docs/help/faq.md> | Public foreground Gateway command | Records `openclaw gateway run` as the direct foreground invocation |
| <https://nodejs.org/dist/v24.16.0/> | Node.js runtime | Architecture-specific ZIP is verified against the official `SHASUMS256.txt` before packaging |
| <https://learn.microsoft.com/windows/msix/package/create-app-package-with-makeappx-tool> | Manual MSIX composition | Package layout is created with the Windows SDK MakeAppx tool |
| <https://learn.microsoft.com/windows/msix/package/sign-app-package-using-signtool> | Development package signing | CI signs with an ephemeral self-signed certificate and publishes no private key |
| <https://learn.microsoft.com/dotnet/api/system.formats.tar.tarentry?view=net-8.0> | Safe managed tar processing API | Host targets .NET 8 and accepts only directories and regular files |
| <https://learn.microsoft.com/dotnet/api/system.security.cryptography.sha256.hashdata?view=net-8.0> | Payload and extracted-file verification | Host uses SHA-256 for payload and staged inventory verification |
| <https://learn.microsoft.com/dotnet/api/system.diagnostics.processstartinfo.argumentlist?view=net-8.0> | Shell-free argument forwarding | Host passes each OpenClaw argument through `ArgumentList` |
| <https://learn.microsoft.com/dotnet/> | Public .NET documentation | SDK pinned by `global.json` |
| <https://docs.github.com/actions> | GitHub Actions documentation | Third-party actions are pinned to full commit SHAs |
| <https://github.com/actions/setup-dotnet/tree/26b0ec14cb23fa6904739307f278c14f94c95bf1> | Install the pinned .NET SDK in CI | Workflow action pinned to the resolved `v5` commit |
| <https://www.npmjs.com/> | Public JavaScript package registry | OpenClaw lockfile and generated provenance identify resolved inputs |
| <https://www.nuget.org/packages/Microsoft.NET.Test.Sdk/17.8.0> | .NET test execution | Test-only dependency pinned in the lock file |
| <https://www.nuget.org/packages/xunit/2.5.3> | Host unit tests | Test-only dependency pinned in the lock file |
| <https://www.nuget.org/packages/xunit.runner.visualstudio/2.5.3> | Visual Studio Test adapter | Test-only dependency pinned in the lock file |
| <https://www.nuget.org/packages/coverlet.collector/6.0.0> | Test coverage data collector | Test-only dependency pinned in the lock file |

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
