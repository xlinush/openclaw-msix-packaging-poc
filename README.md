# OpenClaw MSIX packaging POC

Proof-of-concept tooling for packaging OpenClaw as an MSIX application on
Windows.

The repository currently builds Windows x64 and ARM64 OpenClaw payload
tarballs in GitHub Actions. It also contains a dependency-light C# host that
verifies and stages a payload before launching the standard OpenClaw CLI. The
payload workflow composes development-signed x64 and ARM64 MSIX packages with
the host, payload, and official Node.js runtime.

Artifacts produced here are for development and evaluation only.

## C# host

The host targets .NET 8 and has no runtime NuGet dependencies. It:

1. validates the public payload metadata and SHA-256;
2. rejects absolute paths, traversal, links, special entries, duplicate files,
   Windows device names, and oversized archives;
3. extracts into a temporary directory beside
   `%USERPROFILE%\.openclaw-msix\app`;
4. records a SHA-256 inventory of every extracted file and validates it
   against the packaged, SHA-verified tarball;
5. replaces the stable `app` directory only after extraction succeeds, with
   rollback if promotion fails;
6. re-verifies an existing version before every launch; and
7. launches `node openclaw.mjs` with inherited environment, working console,
   and exit code.

Every host invocation appends timestamped lifecycle, staging, install-lock,
child-process, and sanitized exception details to its printed diagnostics path.
For the MSIX, the file is under:

```text
%LOCALAPPDATA%\Packages\<package-family>\LocalState\
  OpenClawMsixPackagingPoc\Logs\openclaw-poc.log
```

The terminal also shows the current staging phase. The log does not record
forwarded OpenClaw arguments, environment variables, or child-process output.
The file can be copied while the host is running.

To locate and copy an MSIX log without waiting for the host to exit:

```powershell
$log = Get-ChildItem `
  "$env:LOCALAPPDATA\Packages\*\LocalState\OpenClawMsixPackagingPoc\Logs\openclaw-poc.log" |
  Select-Object -First 1
Copy-Item $log.FullName "$HOME\Desktop\openclaw-poc.log"
```

With no OpenClaw arguments, the host runs the Gateway in the foreground:

```powershell
dotnet run --project .\src\OpenClaw.MsixHost
```

For development, point it at a payload produced by the existing workflow:

```powershell
dotnet run --project .\src\OpenClaw.MsixHost -- `
  --host-payload C:\payload\app-x64.tar.gz `
  --host-metadata C:\payload\payload-metadata.json `
  --host-node C:\node\node.exe `
  --host-install-directory C:\OpenClawPoc\app
```

All non-host arguments are forwarded unchanged. Use `--` when an OpenClaw
argument happens to start with `--host-`:

```powershell
dotnet run --project .\src\OpenClaw.MsixHost -- status --json
```

The MSIX places the payload under `payload\` and the verified official Node.js
runtime under `runtime\` beside the host. Outside an MSIX build, the host falls
back to `node` from `PATH` when that packaged runtime is absent. First-run
onboarding orchestration and richer MSIX lifecycle integration remain separate
work items.

The POC intentionally maintains one stable install path rather than retaining
version directories. Stop a running Gateway before launching a newer package
version so the stable directory can be replaced safely.

The package identity and visual assets are explicitly unofficial. CI creates a
short-lived development certificate, signs the MSIX, uploads only the public
`.cer` certificate, and destroys the private key. The certificate must be
trusted locally before installing these evaluation packages.

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

## Build

```powershell
dotnet restore .\OpenClaw.MsixPackaging.sln --locked-mode
dotnet test .\OpenClaw.MsixPackaging.sln --configuration Release --no-restore
dotnet publish .\src\OpenClaw.MsixHost\OpenClaw.MsixHost.csproj `
  --configuration Release `
  --runtime win-x64 `
  --self-contained false
```

`scripts\Build-Msix.ps1` is the local composition entry point. It requires a
published host and payload directory, downloads Node.js from the official
distribution, verifies `SHASUMS256.txt`, creates the package with MakeAppx,
and applies an ephemeral development signature with SignTool.
