# Public sources

Every implementation dependency or material design reference must be recorded
here before use.

| Source | Purpose | Pinning or verification |
|---|---|---|
| <https://github.com/openclaw/rfcs/pull/58> | Public architecture and scope | Host implementation reviewed against RFC commit `d6abbc1d2b45f289d14c1bf7e45a90f1768b5510` |
| <https://github.com/openclaw/openclaw> | OpenClaw payload source | Workflow input resolves to and records a full commit SHA; the archive hash and `public-upstream` content origin are recorded |
| <https://github.com/openclaw/openclaw/blob/b4ffa3106f205a2beef985c9b43887d7c2a6091f/docs/help/faq.md> | Public foreground Gateway command | Records `openclaw gateway run` as the direct foreground invocation |
| <https://nodejs.org/dist/v24.16.0/> | Node.js runtime | Architecture-specific ZIP is verified against the official `SHASUMS256.txt` before packaging |
| <https://learn.microsoft.com/windows/msix/desktop/desktop-to-uwp-packaging-dot-net> | MSBuild MSIX packaging | Checked-in manifest and content are packaged by the public Windows SDK MSBuild targets |
| <https://www.nuget.org/packages/Microsoft.WindowsAppSDK.Base/2.0.4> | MSIX build integration | Public package version is pinned centrally in `Directory.Packages.props` |
| <https://www.nuget.org/packages/Microsoft.Windows.SDK.BuildTools/10.0.26100.4948> | Windows SDK MSBuild tools | Public package version is pinned centrally in `Directory.Packages.props` |
| <https://learn.microsoft.com/windows/msix/package/signing-package-overview> | Development package signing | CI signs with an ephemeral self-signed certificate and publishes no private key |
| <https://learn.microsoft.com/dotnet/api/system.formats.tar.tarentry?view=net-10.0> | Safe managed tar processing API | Host targets .NET 10 and accepts only directories and regular files |
| <https://learn.microsoft.com/dotnet/api/system.security.cryptography.sha256.hashdata?view=net-10.0> | Payload and extracted-file verification | Host uses SHA-256 for payload and staged inventory verification |
| <https://learn.microsoft.com/dotnet/api/system.diagnostics.processstartinfo.argumentlist?view=net-10.0> | Shell-free argument forwarding | Host passes each OpenClaw argument through `ArgumentList` |
| <https://learn.microsoft.com/dotnet/core/deploying/native-aot/> | NativeAOT publishing | SDK is pinned by `global.json`; CI publishes and packages per Windows RID |
| <https://learn.microsoft.com/cpp/build/building-on-the-command-line> | NativeAOT Windows linker toolchain | GitHub-hosted runners and local builds use the public Visual Studio C++ build tools located through `vswhere.exe` |
| <https://learn.microsoft.com/dotnet/standard/serialization/system-text-json/source-generation> | NativeAOT-safe JSON metadata | Host JSON contracts use a source-generated serializer context |
| <https://api.nuget.org/v3/index.json> | Public .NET dependency source | Repository `nuget.config` clears inherited feeds and permits only NuGet.org |
| <https://docs.github.com/actions> | GitHub Actions documentation | Third-party actions are pinned to full commit SHAs |
| <https://github.com/actions/setup-dotnet/tree/26b0ec14cb23fa6904739307f278c14f94c95bf1> | Install the pinned .NET SDK in CI | Workflow action pinned to the resolved `v5` commit |
| <https://www.npmjs.com/> | Public JavaScript package registry | OpenClaw lockfile and generated provenance identify resolved inputs |
| <https://www.nuget.org/packages/Microsoft.NET.Test.Sdk/17.8.0> | .NET test execution | Test-only dependency pinned centrally in `Directory.Packages.props` |
| <https://www.nuget.org/packages/xunit/2.5.3> | Host unit tests | Test-only dependency pinned centrally in `Directory.Packages.props` |
| <https://www.nuget.org/packages/xunit.runner.visualstudio/2.5.3> | Visual Studio Test adapter | Test-only dependency pinned centrally in `Directory.Packages.props` |
| <https://www.nuget.org/packages/coverlet.collector/6.0.0> | Test coverage data collector | Test-only dependency pinned centrally in `Directory.Packages.props` |

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
