[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HostPublishDirectory,

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
$publisher = 'CN=xlinush'
$identityName = 'xlinush.OpenClawMsixPackagingPoc'
$displayName = 'OpenClaw MSIX Packaging POC'

function Get-WindowsSdkTool {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $tool = Get-ChildItem -Path $kitsRoot -Filter $Name -File -Recurse |
        Where-Object { $_.Directory.Name -eq 'x64' } |
        Sort-Object {
            try {
                [version]$_.Directory.Parent.Name
            }
            catch {
                [version]'0.0'
            }
        } -Descending |
        Select-Object -First 1
    if ($null -eq $tool) {
        throw "$Name was not found in the Windows SDK."
    }

    return $tool.FullName
}

function New-PackageImage {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$Width,

        [Parameter(Mandatory)]
        [int]$Height
    )

    $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(31, 41, 55))
        $brush = [System.Drawing.SolidBrush]::new(
            [System.Drawing.Color]::FromArgb(34, 211, 238)
        )
        try {
            $margin = [Math]::Max(2, [Math]::Floor([Math]::Min($Width, $Height) / 6))
            $graphics.FillEllipse(
                $brush,
                $margin,
                $margin,
                $Width - (2 * $margin),
                $Height - (2 * $margin)
            )
        }
        finally {
            $brush.Dispose()
        }

        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
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

Test-PackageVersion
Add-Type -AssemblyName System.Drawing

$hostExecutable = Join-Path $HostPublishDirectory 'openclaw-poc.exe'
$payloadArchive = Join-Path $PayloadDirectory "app-$Architecture.tar.gz"
$payloadMetadata = Join-Path $PayloadDirectory 'payload-metadata.json'
foreach ($requiredPath in @($hostExecutable, $payloadArchive, $payloadMetadata)) {
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

$payloadHash = (Get-FileHash -LiteralPath $payloadArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($payloadInfo.sha256 -ine $payloadHash) {
    throw 'Payload hash does not match payload metadata.'
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
$layout = Join-Path $workRoot 'layout'
$nodeDownload = Join-Path $workRoot 'node'
$nodeExtract = Join-Path $workRoot 'node-extract'
$certificate = $null
New-Item -Path $layout, $nodeDownload, $nodeExtract -ItemType Directory -Force |
    Out-Null
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null

try {
    Copy-Item -Path (Join-Path $HostPublishDirectory '*') -Destination $layout -Recurse

    $payloadTarget = Join-Path $layout 'payload'
    New-Item -Path $payloadTarget -ItemType Directory | Out-Null
    Copy-Item -LiteralPath $payloadArchive -Destination $payloadTarget
    Copy-Item -LiteralPath $payloadMetadata -Destination $payloadTarget

    $nodeArchiveName = "node-v$NodeVersion-win-$Architecture.zip"
    $nodeBaseUrl = "https://nodejs.org/dist/v$NodeVersion"
    $nodeArchiveUrl = "$nodeBaseUrl/$nodeArchiveName"
    $nodeArchivePath = Join-Path $nodeDownload $nodeArchiveName
    $checksumsPath = Join-Path $nodeDownload 'SHASUMS256.txt'
    Invoke-WebRequest -Uri "$nodeBaseUrl/SHASUMS256.txt" -OutFile $checksumsPath
    Invoke-WebRequest -Uri $nodeArchiveUrl -OutFile $nodeArchivePath

    $checksumLine = Get-Content -LiteralPath $checksumsPath |
        Where-Object { $_ -match "^[0-9a-fA-F]{64}\s+$([regex]::Escape($nodeArchiveName))$" } |
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

    Expand-Archive -LiteralPath $nodeArchivePath -DestinationPath $nodeExtract
    $nodeRoot = @(Get-ChildItem -LiteralPath $nodeExtract -Directory)
    if ($nodeRoot.Count -ne 1 -or
        -not (Test-Path -LiteralPath (Join-Path $nodeRoot[0].FullName 'node.exe'))) {
        throw 'The official Node.js archive has an unexpected layout.'
    }

    $runtimeTarget = Join-Path $layout 'runtime'
    New-Item -Path $runtimeTarget -ItemType Directory | Out-Null
    Copy-Item -Path (Join-Path $nodeRoot[0].FullName '*') `
        -Destination $runtimeTarget `
        -Recurse

    $assets = Join-Path $layout 'Assets'
    New-Item -Path $assets -ItemType Directory | Out-Null
    New-PackageImage -Path (Join-Path $assets 'Square44x44Logo.png') -Width 44 -Height 44
    New-PackageImage -Path (Join-Path $assets 'Square150x150Logo.png') -Width 150 -Height 150
    New-PackageImage -Path (Join-Path $assets 'StoreLogo.png') -Width 50 -Height 50

    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package
  xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:uap5="http://schemas.microsoft.com/appx/manifest/uap/windows10/5"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  IgnorableNamespaces="uap uap5 rescap">
  <Identity
    Name="$identityName"
    Publisher="$publisher"
    Version="$PackageVersion"
    ProcessorArchitecture="$Architecture" />
  <Properties>
    <DisplayName>$displayName</DisplayName>
    <PublisherDisplayName>xlinush</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily
      Name="Windows.Desktop"
      MinVersion="10.0.19041.0"
      MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Applications>
    <Application
      Id="App"
      Executable="openclaw-poc.exe"
      EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements
        DisplayName="$displayName"
        Description="Unofficial OpenClaw MSIX packaging proof of concept"
        BackgroundColor="transparent"
        Square150x150Logo="Assets\Square150x150Logo.png"
        Square44x44Logo="Assets\Square44x44Logo.png" />
      <Extensions>
        <uap5:Extension
          Category="windows.appExecutionAlias"
          Executable="openclaw-poc.exe"
          EntryPoint="Windows.FullTrustApplication">
          <uap5:AppExecutionAlias>
            <uap5:ExecutionAlias Alias="openclaw-poc.exe" />
          </uap5:AppExecutionAlias>
        </uap5:Extension>
      </Extensions>
    </Application>
  </Applications>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
</Package>
"@
    $manifest | Set-Content `
        -LiteralPath (Join-Path $layout 'AppxManifest.xml') `
        -Encoding utf8

    $makeAppx = Get-WindowsSdkTool -Name 'makeappx.exe'
    $signTool = Get-WindowsSdkTool -Name 'signtool.exe'
    $msixName = "openclaw-poc-$Architecture.msix"
    $msixPath = Join-Path $OutputDirectory $msixName
    Remove-Item -LiteralPath $msixPath -Force -ErrorAction SilentlyContinue
    $makeAppxOutput = @(& $makeAppx pack /d $layout /p $msixPath /o 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $makeAppxOutput | Write-Error
        throw "MakeAppx failed with exit code $LASTEXITCODE."
    }
    Write-Host ($makeAppxOutput | Select-Object -Last 1)

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
    $pfxPassword = ConvertTo-SecureString $pfxPasswordText -AsPlainText -Force
    Export-PfxCertificate `
        -Cert $certificate `
        -FilePath $pfxPath `
        -Password $pfxPassword |
        Out-Null
    $cerPath = Join-Path $OutputDirectory "openclaw-poc-$Architecture.cer"
    Export-Certificate -Cert $certificate -FilePath $cerPath -Force | Out-Null

    $signOutput = @(
        & $signTool sign /fd SHA256 /f $pfxPath /p $pfxPasswordText $msixPath 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        $signOutput | Write-Error
        throw "SignTool failed with exit code $LASTEXITCODE."
    }
    Write-Host ($signOutput | Select-Object -Last 1)

    $expectedPublicFiles = [System.Collections.Generic.Dictionary[string, object]]::new(
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
            [IO.Path]::GetRelativePath($layout, $runtimeFile.FullName)
        ).Replace('\', '/')
        $expectedPublicFiles.Add(
            $relativePath,
            [pscustomobject]@{
                Hash = (
                Get-FileHash -LiteralPath $runtimeFile.FullName -Algorithm SHA256
                ).Hash.ToLowerInvariant()
                Source = $nodeArchiveUrl
            }
        )
    }

    $publicFiles = [System.Collections.Generic.List[object]]::new()
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $packageArchive = [System.IO.Compression.ZipFile]::OpenRead($msixPath)
    try {
        foreach ($entry in $packageArchive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) {
                continue
            }

            $decodedPath = [Uri]::UnescapeDataString($entry.FullName)
            $expectedEntry = $null
            if (-not $expectedPublicFiles.Remove($decodedPath, [ref]$expectedEntry)) {
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
                throw "MakeAppx changed public package content: $decodedPath"
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

    if ($expectedPublicFiles.Count -ne 0) {
        throw (
            'MakeAppx omitted public package content: ' +
            (($expectedPublicFiles.Keys | Sort-Object | Select-Object -First 5) -join ', ')
        )
    }

    $msixHash = (Get-FileHash -LiteralPath $msixPath -Algorithm SHA256).Hash.ToLowerInvariant()
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
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)" `
            -Force `
            -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}
