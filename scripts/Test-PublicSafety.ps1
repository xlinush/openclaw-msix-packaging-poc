[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Repository', 'Staged', 'History', 'Package')]
    [string]$Mode,

    [string]$Path,

    [string]$ProvenancePath,

    [switch]$RequireLocalConfiguration
)

$ErrorActionPreference = 'Stop'
$maximumScannableFileBytes = 256MB
$prohibitedTrackedExtensions = @(
    '.appx', '.appxbundle', '.appxsym', '.cer', '.dll', '.exe', '.key',
    '.msix', '.msixbundle', '.node', '.p12', '.pfx', '.snk'
)
$findings = [System.Collections.Generic.List[object]]::new()

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & git -C $script:repositoryRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($Arguments[0])"
    }

    return @($output)
}

function Export-GitBlob {
    param(
        [Parameter(Mandatory)]
        [string]$Object,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-C', $script:repositoryRoot, 'cat-file', 'blob', $Object)) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start git.'
    }

    $stream = [System.IO.File]::Create($Destination)
    try {
        $process.StandardOutput.BaseStream.CopyTo($stream)
    }
    finally {
        $stream.Dispose()
    }

    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        $errorText = $process.StandardError.ReadToEnd()
        throw "Unable to read a Git object. $errorText"
    }
}

function Add-Finding {
    param(
        [Parameter(Mandatory)]
        [string]$Rule,

        [Parameter(Mandatory)]
        [string]$File,

        [switch]$Sensitive
    )

    $key = "$Rule`0$File"
    if (-not $script:findingKeys.Add($key)) {
        return
    }

    $displayFile = if ($Sensitive) { '<redacted>' } else { $File }
    $script:findings.Add([pscustomobject]@{
        Rule = $Rule
        File = $displayFile
    })
}

function Test-SafeArchivePath {
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath
    )

    $normalized = $ArchivePath.Replace('\', '/')
    if (
        [string]::IsNullOrWhiteSpace($normalized) -or
        $normalized.StartsWith('/') -or
        $normalized -match '^[A-Za-z]:' -or
        @($normalized.Split('/')) -contains '..'
    ) {
        Add-Finding -Rule 'unsafe-archive-path' -File $ArchivePath
        return $false
    }

    return $true
}

function Test-ScannablePath {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [bool]$AllowBinaries
    )

    foreach ($rule in $script:rules) {
        if ($RelativePath -match $rule.Pattern) {
            Add-Finding -Rule $rule.Id -File $RelativePath -Sensitive:$rule.Sensitive
        }
    }

    if (-not $AllowBinaries) {
        $extension = [System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
        if ($script:prohibitedTrackedExtensions -contains $extension) {
            Add-Finding -Rule 'tracked-binary-or-signing-file' -File $RelativePath
        }
    }
}

function Test-ScannableFile {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [bool]$AllowBinaries,

        [bool]$ScanContent = $true
    )

    Test-ScannablePath -RelativePath $RelativePath -AllowBinaries $AllowBinaries

    if (-not $ScanContent) {
        return
    }

    $fileInfo = Get-Item -LiteralPath $FilePath
    if ($fileInfo.Length -gt $script:maximumScannableFileBytes) {
        Add-Finding -Rule 'file-too-large-to-inspect' -File $RelativePath
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($fileInfo.FullName)
    if ($bytes.Length -eq 0) {
        return
    }

    $sampleLength = [Math]::Min($bytes.Length, 8192)
    $isBinary = [System.Array]::IndexOf(
        $bytes,
        [byte]0,
        0,
        $sampleLength
    ) -ge 0
    if ($isBinary) {
        $representations = [System.Collections.Generic.List[string]]::new()
        $latinText = [System.Text.Encoding]::Latin1.GetString($bytes)
        foreach ($match in [regex]::Matches($latinText, '[ -~]{8,}')) {
            $representations.Add($match.Value)
        }

        $unicodeText = [System.Text.Encoding]::Unicode.GetString($bytes)
        foreach ($match in [regex]::Matches($unicodeText, '[ -~]{8,}')) {
            $representations.Add($match.Value)
        }
    }
    else {
        $representations = @([System.Text.Encoding]::UTF8.GetString($bytes))
    }

    foreach ($rule in $script:rules) {
        if ($isBinary -and $rule.TextOnly) {
            continue
        }

        foreach ($content in $representations) {
            if ($content -match $rule.Pattern) {
                $sensitivePath = $rule.Sensitive -and
                    $RelativePath -match $rule.Pattern
                Add-Finding `
                    -Rule $rule.Id `
                    -File $RelativePath `
                    -Sensitive:$sensitivePath
                break
            }
        }
    }
}

function Test-WorkingTree {
    $trackedFiles = Invoke-Git -Arguments @('ls-files')
    foreach ($relativePath in $trackedFiles) {
        $fullPath = Join-Path $script:repositoryRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            Add-Finding -Rule 'tracked-file-missing' -File $relativePath
            continue
        }

        Test-ScannableFile `
            -FilePath $fullPath `
            -RelativePath $relativePath `
            -AllowBinaries $false
        $script:scannedFileCount++
    }
}

function Test-StagedTree {
    $indexEntries = Invoke-Git -Arguments @('ls-files', '--stage')
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
        'public-safety-index-' + [guid]::NewGuid().ToString('N')
    )
    New-Item -Path $temporaryDirectory -ItemType Directory | Out-Null

    try {
        foreach ($entry in $indexEntries) {
            if ($entry -notmatch '^\d+\s+(?<oid>[0-9a-f]{40,64})\s+\d+\t(?<path>.+)$') {
                throw 'Unable to parse the Git index.'
            }

            $relativePath = $Matches.path
            $temporaryFile = Join-Path $temporaryDirectory ([guid]::NewGuid().ToString('N'))
            Export-GitBlob -Object $Matches.oid -Destination $temporaryFile
            Test-ScannableFile `
                -FilePath $temporaryFile `
                -RelativePath $relativePath `
                -AllowBinaries $false
            $script:scannedFileCount++
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

function Test-GitHistory {
    $seenBlobs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
        'public-safety-history-' + [guid]::NewGuid().ToString('N')
    )
    New-Item -Path $temporaryDirectory -ItemType Directory | Out-Null

    try {
        foreach ($commit in (Invoke-Git -Arguments @('rev-list', '--all'))) {
            foreach ($entry in (Invoke-Git -Arguments @('ls-tree', '-r', '--full-tree', $commit))) {
                if ($entry -notmatch '^\d+\s+blob\s+(?<oid>[0-9a-f]{40,64})\t(?<path>.+)$') {
                    continue
                }

                $blobKey = "$($Matches.oid)`0$($Matches.path)"
                if (-not $seenBlobs.Add($blobKey)) {
                    continue
                }

                $temporaryFile = Join-Path $temporaryDirectory ([guid]::NewGuid().ToString('N'))
                Export-GitBlob -Object $Matches.oid -Destination $temporaryFile
                Test-ScannableFile `
                    -FilePath $temporaryFile `
                    -RelativePath $Matches.path `
                    -AllowBinaries $false
                Remove-Item -LiteralPath $temporaryFile -Force
                $script:scannedFileCount++
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

function Test-Provenance {
    param(
        [Parameter(Mandatory)]
        [string]$ArtifactPath,

        [Parameter(Mandatory)]
        [string]$MetadataPath
    )

    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
        Add-Finding -Rule 'missing-package-provenance' -File (
            Split-Path $ArtifactPath -Leaf
        )
        return
    }

    try {
        $metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
    }
    catch {
        Add-Finding -Rule 'invalid-package-provenance' -File (
            Split-Path $MetadataPath -Leaf
        )
        return
    }

    $artifactName = Split-Path $ArtifactPath -Leaf
    $actualHash = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash
    if (
        -not $metadata.sha256 -or
        $metadata.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        $metadata.sha256 -ine $actualHash
    ) {
        Add-Finding -Rule 'package-hash-mismatch' -File $artifactName
    }

    if ($metadata.archive -and $metadata.archive -ne $artifactName) {
        Add-Finding -Rule 'package-name-mismatch' -File $artifactName
    }

    if (
        -not $metadata.repository -or
        $metadata.repository -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$'
    ) {
        Add-Finding -Rule 'non-public-package-source' -File $artifactName
    }

    if (
        -not $metadata.resolvedCommit -or
        $metadata.resolvedCommit -notmatch '^[0-9a-fA-F]{40}$'
    ) {
        Add-Finding -Rule 'unpinned-package-source' -File $artifactName
    }

    if ($metadata.contentOrigin -notin @('public-upstream', 'repository-build')) {
        Add-Finding -Rule 'unknown-package-content-origin' -File $artifactName
    }
    elseif (
        $metadata.contentOrigin -eq 'public-upstream' -and
        $metadata.repository -ne 'https://github.com/openclaw/openclaw'
    ) {
        Add-Finding -Rule 'unapproved-upstream-content-origin' -File $artifactName
    }
    else {
        $script:packageContentOrigin = $metadata.contentOrigin
    }

    $publicFilesProperty = $metadata.PSObject.Properties['publicFiles']
    if ($publicFilesProperty) {
        foreach ($publicFile in @($publicFilesProperty.Value)) {
            $publicPath = ([string]$publicFile.path).Replace('\', '/')
            if (
                [string]::IsNullOrWhiteSpace($publicPath) -or
                -not (Test-SafeArchivePath -ArchivePath $publicPath) -or
                $publicFile.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
                $publicFile.source -notmatch '^https://(?:github\.com|nodejs\.org)/'
            ) {
                Add-Finding -Rule 'invalid-public-package-file' -File $artifactName
                continue
            }

            if (-not $script:packagePublicFiles.TryAdd(
                $publicPath,
                ([string]$publicFile.sha256).ToLowerInvariant()
            )) {
                Add-Finding -Rule 'duplicate-public-package-file' -File $artifactName
            }
        }
    }
}

function Test-Package {
    if (-not $Path) {
        throw 'Package mode requires -Path.'
    }

    $artifactPath = (Resolve-Path -LiteralPath $Path).Path
    if (-not $ProvenancePath) {
        Add-Finding -Rule 'missing-package-provenance' -File (
            Split-Path $artifactPath -Leaf
        )
    }
    else {
        Test-Provenance `
            -ArtifactPath $artifactPath `
            -MetadataPath (Resolve-Path -LiteralPath $ProvenancePath).Path
    }

    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
        'public-safety-package-' + [guid]::NewGuid().ToString('N')
    )
    New-Item -Path $temporaryDirectory -ItemType Directory | Out-Null

    try {
        if ($artifactPath -match '\.(?:tar\.gz|tgz)$') {
            $entries = & tar -tzf $artifactPath
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to list the package archive.'
            }

            foreach ($entry in $entries) {
                [void](Test-SafeArchivePath -ArchivePath $entry)
            }

            $verboseEntries = & tar -tvzf $artifactPath
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to inspect package entry types.'
            }
            foreach ($entry in $verboseEntries) {
                if ($entry -match '^[lh]') {
                    Add-Finding -Rule 'archive-link-entry' -File '<archive entry>'
                }
            }

            if ($findings.Count -eq 0) {
                & tar -xzf $artifactPath -C $temporaryDirectory
                if ($LASTEXITCODE -ne 0) {
                    throw 'Unable to extract the package archive.'
                }
            }
        }
        elseif ($artifactPath -match '\.(?:msix|appx|zip)$') {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [System.IO.Compression.ZipFile]::OpenRead($artifactPath)
            try {
                foreach ($entry in $archive.Entries) {
                    [void](Test-SafeArchivePath -ArchivePath $entry.FullName)
                    $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
                    if ($unixType -eq 0xA000) {
                        Add-Finding -Rule 'archive-link-entry' -File '<archive entry>'
                    }
                }
            }
            finally {
                $archive.Dispose()
            }

            if ($findings.Count -eq 0) {
                [System.IO.Compression.ZipFile]::ExtractToDirectory(
                    $artifactPath,
                    $temporaryDirectory
                )
            }
        }
        else {
            throw 'Package mode supports .tar.gz, .tgz, .msix, .appx, or .zip.'
        }

        if ($findings.Count -eq 0) {
            foreach ($file in (Get-ChildItem -LiteralPath $temporaryDirectory -File -Recurse)) {
                $relativePath = [System.IO.Path]::GetRelativePath(
                    $temporaryDirectory,
                    $file.FullName
                )
                $archiveRelativePath = $relativePath.Replace('\', '/')
                $scanContent = $script:packageContentOrigin -ne 'public-upstream'
                $expectedPublicHash = $null
                if ($script:packagePublicFiles.Remove(
                    $archiveRelativePath,
                    [ref]$expectedPublicHash
                )) {
                    $actualPublicHash = (
                        Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
                    ).Hash.ToLowerInvariant()
                    if ($actualPublicHash -ne $expectedPublicHash) {
                        Add-Finding `
                            -Rule 'public-package-file-hash-mismatch' `
                            -File $archiveRelativePath
                    }
                    else {
                        $scanContent = $false
                    }
                }

                Test-ScannableFile `
                    -FilePath $file.FullName `
                    -RelativePath $relativePath `
                    -AllowBinaries $true `
                    -ScanContent $scanContent
                $script:scannedFileCount++
            }

            foreach ($missingPublicPath in $script:packagePublicFiles.Keys) {
                Add-Finding `
                    -Rule 'missing-public-package-file' `
                    -File $missingPublicPath
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

$repositoryRootOutput = & git -C $PSScriptRoot rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0) {
    throw 'The safety script must be run from a Git checkout.'
}
$repositoryRoot = [System.IO.Path]::GetFullPath(($repositoryRootOutput -join ''))
$findingKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
)
$scannedFileCount = 0
$packageContentOrigin = $null
$packagePublicFiles = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$rules = [System.Collections.Generic.List[object]]::new()
$backslash = [char]92
$windowsUsersPrefix = [regex]::Escape(
    "$backslash" + 'Users' + "$backslash"
)
$macUsersPrefix = [regex]::Escape('/' + 'Users' + '/')
$uncPrefix = [regex]::Escape("$backslash$backslash")
$rules.Add([pscustomobject]@{
    Id = 'private-devops-url'
    Pattern = '(?i)https?://(?:dev\.azure\.com|[a-z0-9.-]+\.visualstudio\.com)(?:[/\\]|$)'
    Sensitive = $false
    TextOnly = $false
})
$rules.Add([pscustomobject]@{
    Id = 'absolute-user-profile-path'
    Pattern = (
        '(?i)(?:[a-z]:' + $windowsUsersPrefix + '[^\\\r\n]+' +
        [regex]::Escape("$backslash") + '|' +
        $macUsersPrefix + '[^/\r\n]+/)'
    )
    Sensitive = $false
    TextOnly = $false
})
$rules.Add([pscustomobject]@{
    Id = 'unc-network-path'
    Pattern = (
        '(?i)' + $uncPrefix + '[^\\\s]+' +
        [regex]::Escape("$backslash") + '[^\\\s]+' +
        [regex]::Escape("$backslash")
    )
    Sensitive = $false
    TextOnly = $true
})
$rules.Add([pscustomobject]@{
    Id = 'private-key'
    Pattern = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
    Sensitive = $false
    TextOnly = $false
})
$rules.Add([pscustomobject]@{
    Id = 'github-token'
    Pattern = '(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
    Sensitive = $false
    TextOnly = $false
})
$rules.Add([pscustomobject]@{
    Id = 'connection-secret'
    Pattern = '(?i)(?:AccountKey|SharedAccessSignature)=[^;\s]{8,}'
    Sensitive = $false
    TextOnly = $false
})

$localConfigurationPath = Join-Path $repositoryRoot '.public-safety.local.json'
if (Test-Path -LiteralPath $localConfigurationPath -PathType Leaf) {
    $localConfiguration = Get-Content -LiteralPath $localConfigurationPath -Raw |
        ConvertFrom-Json
    if ($localConfiguration.version -ne 1) {
        throw 'Unsupported local public-safety configuration version.'
    }

    $localRuleIndex = 0
    $literalProperty = $localConfiguration.PSObject.Properties['forbiddenLiterals']
    if ($literalProperty) {
        foreach ($literal in @($literalProperty.Value)) {
            if (
                [string]::IsNullOrWhiteSpace($literal) -or
                $literal -like 'REPLACE_WITH_*'
            ) {
                throw 'Local forbidden literals must be real, non-empty values.'
            }
            $localRuleIndex++
            $rules.Add([pscustomobject]@{
                Id = "local-literal-$localRuleIndex"
                Pattern = [regex]::Escape([string]$literal)
                Sensitive = $true
                TextOnly = $false
            })
        }
    }

    $regexProperty = $localConfiguration.PSObject.Properties['forbiddenRegexes']
    if ($regexProperty) {
        foreach ($localRule in @($regexProperty.Value)) {
            if (
                [string]::IsNullOrWhiteSpace($localRule.pattern) -or
                $localRule.pattern -like 'REPLACE_WITH_*'
            ) {
                throw 'Local forbidden regex rules require a real pattern.'
            }
            [void][regex]::new([string]$localRule.pattern)
            $localRuleIndex++
            $rules.Add([pscustomobject]@{
                Id = "local-regex-$localRuleIndex"
                Pattern = [string]$localRule.pattern
                Sensitive = $true
                TextOnly = $false
            })
        }
    }

    if ($localRuleIndex -eq 0) {
        throw 'Local public-safety configuration must define at least one rule.'
    }
}
elseif ($RequireLocalConfiguration) {
    throw (
        'Missing .public-safety.local.json. Copy the committed example, ' +
        'replace every placeholder, and keep the resulting file untracked.'
    )
}

switch ($Mode) {
    'Repository' { Test-WorkingTree }
    'Staged' { Test-StagedTree }
    'History' { Test-GitHistory }
    'Package' { Test-Package }
}

if ($findings.Count -gt 0) {
    foreach ($finding in $findings) {
        Write-Error (
            "Public-safety rule '$($finding.Rule)' failed for '$($finding.File)'."
        ) -ErrorAction Continue
    }
    throw "Public safety check failed with $($findings.Count) finding(s)."
}

Write-Host (
    "Public safety check passed: mode=$Mode; files=$scannedFileCount."
)
