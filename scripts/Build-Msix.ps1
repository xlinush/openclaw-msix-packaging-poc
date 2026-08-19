[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PayloadDirectory,

    [Parameter(Mandatory)]
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,

    [Parameter(Mandatory)]
    [string]$NodeVersion,

    [Parameter(Mandatory)]
    [string]$PackageVersion,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$SourceCommit,

    [switch]$SourceTreeDirty,

    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path $PSScriptRoot -Parent
$projectPath = Join-Path `
    $repositoryRoot `
    'src\OpenClaw.MsixHost\OpenClaw.MsixHost.csproj'
$publisher = 'CN=xlinush'

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Command,

        [Parameter(Mandatory)]
        [string]$FailureMessage
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage Exit code: $LASTEXITCODE."
    }
}

function Test-PackageVersion {
    $segments = @($PackageVersion.Split('.'))
    if ($segments.Count -ne 4) {
        throw 'PackageVersion must contain four numeric components.'
    }

    foreach ($segment in $segments) {
        [uint16]$value = 0
        if (-not [uint16]::TryParse($segment, [ref]$value)) {
            throw "Invalid MSIX package version component: $segment"
        }
    }
}

function Add-VswhereToPath {
    if (Get-Command vswhere.exe -CommandType Application -ErrorAction SilentlyContinue) {
        return
    }

    $vswhereDirectory = Join-Path `
        ${env:ProgramFiles(x86)} `
        'Microsoft Visual Studio\Installer'
    $vswherePath = Join-Path $vswhereDirectory 'vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswherePath -PathType Leaf)) {
        throw (
            'vswhere.exe was not found. Install Visual Studio Build Tools with ' +
            'the Desktop development with C++ workload.'
        )
    }

    $env:Path = "$vswhereDirectory;$env:Path"
}

Test-PackageVersion
Add-VswhereToPath

$PayloadDirectory = (Resolve-Path -LiteralPath $PayloadDirectory).Path
$payloadArchive = Join-Path $PayloadDirectory "app-$Architecture.tar.gz"
$payloadMetadata = Join-Path $PayloadDirectory 'payload-metadata.json'
foreach ($requiredPath in @($payloadArchive, $payloadMetadata)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required MSIX input was not found: $requiredPath"
    }
}

$payloadInfo = Get-Content -LiteralPath $payloadMetadata -Raw | ConvertFrom-Json
if (
    $payloadInfo.repository -ne 'https://github.com/openclaw/openclaw' -or
    $payloadInfo.contentOrigin -ne 'public-upstream' -or
    $payloadInfo.architecture -ne $Architecture -or
    $payloadInfo.archive -ne (Split-Path $payloadArchive -Leaf)
) {
    throw 'Payload metadata is not valid for this MSIX package.'
}

$payloadHash = (
    Get-FileHash -LiteralPath $payloadArchive -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($payloadInfo.sha256 -ine $payloadHash) {
    throw 'Payload hash does not match payload metadata.'
}

$contentRoot = Join-Path $repositoryRoot 'content'
$openClawContent = Join-Path $contentRoot 'openclaw'
$runtimeTarget = Join-Path (Join-Path $contentRoot 'runtime') $Architecture
New-Item -Path $openClawContent -ItemType Directory -Force | Out-Null

$stagedPayloadArchive = Join-Path `
    $openClawContent `
    (Split-Path $payloadArchive -Leaf)
$stagedPayloadMetadata = Join-Path $openClawContent 'payload-metadata.json'
if (
    [IO.Path]::GetFullPath($payloadArchive) -ne
    [IO.Path]::GetFullPath($stagedPayloadArchive)
) {
    Copy-Item -LiteralPath $payloadArchive -Destination $stagedPayloadArchive -Force
}
if (
    [IO.Path]::GetFullPath($payloadMetadata) -ne
    [IO.Path]::GetFullPath($stagedPayloadMetadata)
) {
    Copy-Item -LiteralPath $payloadMetadata -Destination $stagedPayloadMetadata -Force
}

$temporaryRoot = if ($env:RUNNER_TEMP) {
    $env:RUNNER_TEMP
}
else {
    [IO.Path]::GetTempPath()
}
$workRoot = Join-Path `
    $temporaryRoot `
    "openclaw-msix-$Architecture-$([guid]::NewGuid().ToString('N'))"
$nodeDownload = Join-Path $workRoot 'node'
$nodeExtract = Join-Path $workRoot 'node-extract'
$msixBuildDirectory = Join-Path $workRoot 'appx'
$certificate = $null
New-Item `
    -Path $nodeDownload, $nodeExtract, $msixBuildDirectory, $OutputDirectory `
    -ItemType Directory `
    -Force |
    Out-Null

try {
    $nodeArchiveName = "node-v$NodeVersion-win-$Architecture.zip"
    $nodeBaseUrl = "https://nodejs.org/dist/v$NodeVersion"
    $nodeArchiveUrl = "$nodeBaseUrl/$nodeArchiveName"
    $nodeArchivePath = Join-Path $nodeDownload $nodeArchiveName
    $checksumsPath = Join-Path $nodeDownload 'SHASUMS256.txt'
    Invoke-WebRequest -Uri "$nodeBaseUrl/SHASUMS256.txt" -OutFile $checksumsPath
    Invoke-WebRequest -Uri $nodeArchiveUrl -OutFile $nodeArchivePath

    $checksumLine = Get-Content -LiteralPath $checksumsPath |
        Where-Object {
            $_ -match "^[0-9a-fA-F]{64}\s+$([regex]::Escape($nodeArchiveName))$"
        } |
        Select-Object -First 1
    if (-not $checksumLine) {
        throw "Official checksum was not found for $nodeArchiveName."
    }

    $expectedNodeHash = ($checksumLine -split '\s+')[0].ToLowerInvariant()
    $actualNodeHash = (
        Get-FileHash -LiteralPath $nodeArchivePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($actualNodeHash -ne $expectedNodeHash) {
        throw 'Node.js archive hash does not match the official checksum.'
    }

    Copy-Item `
        -LiteralPath $nodeArchivePath `
        -Destination (Join-Path $openClawContent $nodeArchiveName) `
        -Force
    Expand-Archive -LiteralPath $nodeArchivePath -DestinationPath $nodeExtract
    $nodeRoot = @(Get-ChildItem -LiteralPath $nodeExtract -Directory)
    if (
        $nodeRoot.Count -ne 1 -or
        -not (Test-Path -LiteralPath (Join-Path $nodeRoot[0].FullName 'node.exe'))
    ) {
        throw 'The official Node.js archive has an unexpected layout.'
    }

    Remove-Item -LiteralPath $runtimeTarget -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $runtimeTarget -ItemType Directory -Force | Out-Null
    Copy-Item `
        -Path (Join-Path $nodeRoot[0].FullName '*') `
        -Destination $runtimeTarget `
        -Recurse

    $certificate = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $publisher `
        -FriendlyName 'OpenClaw MSIX Packaging POC Development' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -KeyUsage DigitalSignature `
        -KeyExportPolicy Exportable `
        -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddDays(30) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')
    $pfxPath = Join-Path $workRoot 'development-signing.pfx'
    $pfxPasswordText = [guid]::NewGuid().ToString('N')
    $pfxPassword = ConvertTo-SecureString `
        $pfxPasswordText `
        -AsPlainText `
        -Force
    Export-PfxCertificate `
        -Cert $certificate `
        -FilePath $pfxPath `
        -Password $pfxPassword |
        Out-Null

    $appxOutput = $msixBuildDirectory.TrimEnd('\') + '\'
    Write-Host "Building NativeAOT win-$Architecture MSIX with MSBuild."
    Invoke-CheckedCommand `
        -FailureMessage 'NativeAOT MSIX build failed.' `
        -Command {
            & dotnet build $projectPath `
                --configuration Release `
                --runtime "win-$Architecture" `
                --no-restore `
                "-p:Platform=$Architecture" `
                "-p:RuntimeIdentifiers=win-$Architecture" `
                -p:PublishAot=true `
                -p:SelfContained=true `
                -p:IncludePackagingContent=true `
                -p:GenerateAppxPackageOnBuild=true `
                "-p:PackageIdentityVersion=$PackageVersion" `
                "-p:AppxPackageDir=$appxOutput" `
                -p:AppxBundle=Never `
                -p:AppxPackageSigningEnabled=true `
                "-p:PackageCertificateThumbprint=$($certificate.Thumbprint)" `
                "-p:PackageCertificateKeyFile=$pfxPath" `
                "-p:PackageCertificatePassword=$pfxPasswordText" `
                -p:DebugType=None `
                --nologo
        }

    $builtPackages = @(
        Get-ChildItem `
            -LiteralPath $msixBuildDirectory `
            -Filter '*.msix' `
            -File `
            -Recurse
    )
    if ($builtPackages.Count -ne 1) {
        throw (
            "Expected one MSIX under '$msixBuildDirectory'; " +
            "found $($builtPackages.Count)."
        )
    }

    $msixName = "openclaw-poc-$Architecture.msix"
    $msixPath = Join-Path $OutputDirectory $msixName
    Copy-Item -LiteralPath $builtPackages[0].FullName -Destination $msixPath -Force
    $cerPath = Join-Path $OutputDirectory "openclaw-poc-$Architecture.cer"
    Export-Certificate -Cert $certificate -FilePath $cerPath -Force | Out-Null

    $expectedPublicFiles =
        [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    $expectedPublicFiles.Add(
        "payload/$(Split-Path $payloadArchive -Leaf)",
        [pscustomobject]@{
            Hash = $payloadHash
            Source = 'https://github.com/openclaw/openclaw'
        }
    )
    foreach ($runtimeFile in Get-ChildItem -LiteralPath $runtimeTarget -File -Recurse) {
        $relativePath = (
            [IO.Path]::GetRelativePath($runtimeTarget, $runtimeFile.FullName)
        ).Replace('\', '/')
        $expectedPublicFiles.Add(
            "runtime/$relativePath",
            [pscustomobject]@{
                Hash = (
                    Get-FileHash `
                        -LiteralPath $runtimeFile.FullName `
                        -Algorithm SHA256
                ).Hash.ToLowerInvariant()
                Source = $nodeArchiveUrl
            }
        )
    }

    $publicFiles = [System.Collections.Generic.List[object]]::new()
    $packageEntries = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $packageArchive = [System.IO.Compression.ZipFile]::OpenRead($msixPath)
    try {
        foreach ($entry in $packageArchive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) {
                continue
            }

            $decodedPath = [Uri]::UnescapeDataString($entry.FullName)
            $null = $packageEntries.Add($decodedPath)
            $expectedEntry = $null
            if (
                -not $expectedPublicFiles.Remove(
                    $decodedPath,
                    [ref]$expectedEntry
                )
            ) {
                continue
            }

            $stream = $entry.Open()
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try {
                $packagedHash = [Convert]::ToHexString(
                    $sha256.ComputeHash($stream)
                ).ToLowerInvariant()
            }
            finally {
                $sha256.Dispose()
                $stream.Dispose()
            }

            if ($packagedHash -ne $expectedEntry.Hash) {
                throw "MSBuild changed public package content: $decodedPath"
            }

            $publicFiles.Add([ordered]@{
                path = $entry.FullName
                sha256 = $packagedHash
                source = $expectedEntry.Source
            })
        }
    }
    finally {
        $packageArchive.Dispose()
    }

    if (-not $packageEntries.Contains('openclaw-poc.exe')) {
        throw 'The MSIX does not contain the NativeAOT host executable.'
    }
    foreach ($managedHostArtifact in @(
        'openclaw-poc.dll',
        'openclaw-poc.deps.json',
        'openclaw-poc.runtimeconfig.json'
    )) {
        if ($packageEntries.Contains($managedHostArtifact)) {
            throw "The MSIX contains managed host artifact: $managedHostArtifact"
        }
    }

    if ($expectedPublicFiles.Count -ne 0) {
        throw (
            'MSBuild omitted public package content: ' +
            (
                $expectedPublicFiles.Keys |
                    Sort-Object |
                    Select-Object -First 5
            ) -join ', '
        )
    }

    $msixHash = (
        Get-FileHash -LiteralPath $msixPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    [ordered]@{
        repository = 'https://github.com/xlinush/openclaw-msix-packaging-poc'
        resolvedCommit = $SourceCommit.ToLowerInvariant()
        sourceTreeDirty = $SourceTreeDirty.IsPresent
        architecture = $Architecture
        archive = $msixName
        sha256 = $msixHash
        contentOrigin = 'repository-build'
        packageVersion = $PackageVersion
        publisher = $publisher
        nodeVersion = $NodeVersion
        nodeArchive = $nodeArchiveName
        nodeArchiveSha256 = $actualNodeHash
        publicFiles = $publicFiles
    } | ConvertTo-Json -Depth 5 |
        Set-Content `
            -LiteralPath (Join-Path $OutputDirectory 'msix-metadata.json') `
            -Encoding utf8

    Write-Host "Created signed development MSIX: $msixPath"
}
finally {
    if ($null -ne $certificate) {
        Remove-Item `
            -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)" `
            -Force `
            -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}
