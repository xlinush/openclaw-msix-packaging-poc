# OpenClaw MSIX packaging POC

Proof-of-concept tooling for packaging OpenClaw as an MSIX application on
Windows.

The repository currently builds Windows x64 and ARM64 OpenClaw payload
tarballs in GitHub Actions. It also contains a dependency-light C# host that
verifies and stages a payload before users explicitly launch the standard
OpenClaw CLI. The
payload workflow composes development-signed x64 and ARM64 MSIX packages with
the host, payload, and official Node.js runtime.

Artifacts produced here are for development and evaluation only.

## C# host

The host targets .NET 10, publishes with NativeAOT, and has no application
runtime dependencies beyond Windows MSIX build tooling. It:

1. validates the payload metadata and SHA-256;
2. rejects absolute paths, traversal, links, special entries, duplicate files,
   Windows device names, and oversized archives;
3. extracts into a temporary directory beside
   `%USERPROFILE%\.openclaw-msix\app`;
4. records a SHA-256 inventory of every extracted file and validates it
   against the packaged, SHA-verified tarball;
5. replaces the stable `app` directory only after extraction succeeds, with
   rollback if promotion fails;
6. hashes every file during first-run extraction, then offers fast reuse or a
   full verify-and-repair pass on subsequent bootstrap launches; and
7. prints package-valid setup and gateway commands without automatically
   starting OpenClaw.

Every host invocation appends timestamped lifecycle, staging, install-lock,
child-process, and sanitized exception details to its printed diagnostics path.
For the MSIX, the file is under:

```text
%LOCALAPPDATA%\Packages\<package-family>\LocalState\
  OpenClawMSIXPackagingPoc\Logs\openclaw-poc.log
```

The terminal also shows the current staging phase. The log does not record
forwarded OpenClaw arguments, environment variables, or child-process output.
The file can be copied while the host is running.

On a no-argument launch, complete setup with `openclaw-poc setup` or
`openclaw-poc onboard --mode local`, then launch
`openclaw-poc gateway run`.
The host automatically adds `--skip-daemon` to setup and onboarding because it
expects the Gateway to be run explicitly in the foreground. OpenClaw's
separate Windows Scheduled Task is unsupported in this POC.

Older POC packages could allow setup to create that task. If Windows reports a
missing `%USERPROFILE%\.openclaw\gateway.vbs`, remove the stale task before
installing and running the corrected package:

```powershell
openclaw-poc gateway uninstall
```

To locate and copy an MSIX log without waiting for the host to exit:

```powershell
$log = Get-ChildItem `
  "$env:LOCALAPPDATA\Packages\*\LocalState\OpenClawMSIXPackagingPoc\Logs\openclaw-poc.log" |
  Select-Object -First 1
Copy-Item $log.FullName "$HOME\Desktop\openclaw-poc.log"
```

With no OpenClaw arguments, the host prepares the payload, prints the next
steps, and keeps an interactive terminal open until Enter is pressed:

```powershell
dotnet run --project .\src\OpenClaw.MSIXHost
```

For development, point it at a payload produced by the existing workflow:

```powershell
dotnet run --project .\src\OpenClaw.MSIXHost -- `
  --host-payload C:\payload\app-x64.tar.gz `
  --host-metadata C:\payload\payload-metadata.json `
  --host-node C:\node\node.exe `
  --host-install-directory C:\OpenClawPoc\app
```

All non-host arguments are forwarded unchanged after payload preparation. Use
`--` when an OpenClaw argument happens to start with `--host-`:

```powershell
dotnet run --project .\src\OpenClaw.MSIXHost -- status --json
```

Use `--host-verify-installed-payload` to explicitly re-hash every installed
payload file before running an OpenClaw command. Normal launches avoid this
expensive scan after the installed payload has been verified once.

The MSIX places the payload under `payload\` and the verified official Node.js
runtime under `runtime\` beside the host. Packaging inputs are materialized
under the ignored `content\openclaw\` and `content\runtime\` directories before
MSBuild creates the package. Outside an MSIX build, the host falls back to
`node` from `PATH` when that packaged runtime is absent. First-run
onboarding orchestration and richer MSIX lifecycle integration remain separate
work items.

The POC intentionally maintains one stable install path rather than retaining
version directories. Stop a running Gateway before launching a newer package
version so the stable directory can be replaced safely.

The package identity and visual assets are explicitly unofficial. CI creates a
short-lived development certificate, signs the MSIX, uploads only the public
`.cer` certificate, and destroys the private key. The certificate must be
trusted locally before installing these evaluation packages.

## Build

```powershell
dotnet restore .\OpenClaw.MSIXPackaging.sln
dotnet test .\OpenClaw.MSIXPackaging.sln --configuration Release --no-restore
dotnet publish .\src\OpenClaw.MSIXHost\OpenClaw.MSIXHost.csproj `
  --configuration Release `
  --runtime win-x64 `
  --self-contained true
```

`scripts\Build-MSIX.ps1` is the local composition entry point. It requires a
payload directory, downloads Node.js from the official distribution, verifies
`SHASUMS256.txt`, stages generated content under `content\`, and invokes the
Windows SDK MSBuild MSIX targets to build a NativeAOT package with an
ephemeral development signature. The source-controlled package contract is
`src\OpenClaw.MSIXHost\Package.appxmanifest`; only a generated intermediate copy
is version-stamped during the build. NativeAOT requires Visual Studio Build
Tools with the Desktop development with C++ workload; the build script locates
its linker through `vswhere.exe`.

For a pre-push package using the current local source, including uncommitted
changes, run:

```powershell
.\scripts\Build-LocalMSIX.ps1 -Architecture x64
```

The wrapper downloads the latest successful payload from GitHub Actions,
builds the current host source with NativeAOT, and creates and signs the MSIX.
Output is written below
`artifacts\local-msix\`. Use `-PayloadDirectory` to build without downloading
an artifact, or `-PayloadRunId` to select a specific successful workflow.
