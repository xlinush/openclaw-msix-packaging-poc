using System.Formats.Tar;
using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace OpenClaw.MsixHost;

public sealed class PayloadStager(
    string installDirectory,
    Action<string>? log = null)
{
    private const int MaximumEntryCount = 250_000;
    private const long MaximumExtractedBytes = 8L * 1024 * 1024 * 1024;
    private const string InventoryFileName = ".payload-inventory.json";
    private static readonly TimeSpan InstallLockTimeout = TimeSpan.FromSeconds(30);
    private static readonly StringComparer PathComparer = StringComparer.OrdinalIgnoreCase;
    private readonly string _installDirectory = Path.GetFullPath(installDirectory);
    private readonly Action<string> _log = log ?? (_ => { });

    public async Task<StagedPayload> StageAsync(
        string payloadPath,
        string metadataPath,
        CancellationToken cancellationToken)
    {
        string fullPayloadPath = Path.GetFullPath(payloadPath);
        string fullMetadataPath = Path.GetFullPath(metadataPath);
        if (!File.Exists(fullPayloadPath))
        {
            throw new FileNotFoundException("OpenClaw payload was not found.", fullPayloadPath);
        }

        _log("Loading payload metadata.");
        PayloadMetadata metadata = await PayloadMetadata.LoadAsync(
            fullMetadataPath,
            cancellationToken);
        string processArchitecture = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => "x64",
            Architecture.Arm64 => "arm64",
            _ => throw new PlatformNotSupportedException(
                $"Unsupported process architecture: {RuntimeInformation.ProcessArchitecture}.")
        };
        if (!string.Equals(
            metadata.Architecture,
            processArchitecture,
            StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Payload architecture does not match the host process.");
        }

        if (!PathComparer.Equals(metadata.Archive, Path.GetFileName(fullPayloadPath)))
        {
            throw new InvalidDataException("Payload file name does not match its metadata.");
        }

        _log("Verifying packaged payload SHA-256.");
        string actualHash = await ComputeHashAsync(fullPayloadPath, cancellationToken);
        if (!string.Equals(actualHash, metadata.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Payload SHA-256 does not match its metadata.");
        }

        string? installRoot = Path.GetDirectoryName(_installDirectory);
        if (string.IsNullOrWhiteSpace(installRoot))
        {
            throw new InvalidOperationException(
                "The install directory must have a parent directory.");
        }

        Directory.CreateDirectory(installRoot);
        string installName = Path.GetFileName(_installDirectory);
        string temporaryDirectory = Path.Combine(installRoot, $".{installName}.staging");
        string backupDirectory = Path.Combine(installRoot, $".{installName}.previous");
        string lockPath = Path.Combine(installRoot, $".{installName}.install.lock");

        _log("Waiting for the exclusive installation lock.");
        var lockStopwatch = Stopwatch.StartNew();
        await using FileStream installLock = await AcquireInstallLockAsync(
            lockPath,
            cancellationToken);
        _log(
            $"Acquired the installation lock after {lockStopwatch.Elapsed.TotalSeconds:F1} seconds.");

        _log("Checking for an interrupted payload update.");
        RecoverInterruptedPromotion(
            _installDirectory,
            temporaryDirectory,
            backupDirectory);

        if (Directory.Exists(_installDirectory))
        {
            try
            {
                _log("Verifying the existing installed payload.");
                await VerifyStagedPayloadAsync(
                    _installDirectory,
                    actualHash,
                    fullPayloadPath,
                    cancellationToken);
                _log("The existing installed payload is valid and will be reused.");
                return new StagedPayload(_installDirectory, actualHash);
            }
            catch (InvalidDataException exception)
            {
                _log(
                    $"The existing installed payload requires repair: {exception.Message}");
            }
        }

        _log("Extracting the verified payload. First launch can take several minutes.");
        Directory.CreateDirectory(temporaryDirectory);
        bool promoted = false;
        try
        {
            IReadOnlyList<PayloadInventoryEntry> entries = await ReadPayloadAsync(
                fullPayloadPath,
                temporaryDirectory,
                cancellationToken);
            _log($"Extracted and hashed {entries.Count} payload files.");
            EnsureOpenClawEntryPoint(temporaryDirectory);

            var inventory = new PayloadInventory(actualHash, entries);
            string inventoryPath = Path.Combine(temporaryDirectory, InventoryFileName);
            await using (FileStream inventoryStream = new(
                inventoryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None))
            {
                await JsonSerializer.SerializeAsync(
                    inventoryStream,
                    inventory,
                    cancellationToken: cancellationToken);
            }

            try
            {
                _log("Promoting the staged payload into the stable install directory.");
                if (Directory.Exists(_installDirectory))
                {
                    Directory.Move(_installDirectory, backupDirectory);
                }

                Directory.Move(temporaryDirectory, _installDirectory);
                promoted = true;
                _log("Payload installation completed.");
            }
            catch
            {
                if (!Directory.Exists(_installDirectory) &&
                    Directory.Exists(backupDirectory))
                {
                    Directory.Move(backupDirectory, _installDirectory);
                }

                throw;
            }

            return new StagedPayload(_installDirectory, actualHash);
        }
        finally
        {
            DeleteDirectory(temporaryDirectory);
            if (promoted)
            {
                DeleteDirectory(backupDirectory);
            }
        }
    }

    private static async Task<FileStream> AcquireInstallLockAsync(
        string lockPath,
        CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        IOException? lastException = null;
        while (stopwatch.Elapsed < InstallLockTimeout)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                return new FileStream(
                    lockPath,
                    FileMode.OpenOrCreate,
                    FileAccess.ReadWrite,
                    FileShare.None,
                    bufferSize: 1,
                    FileOptions.Asynchronous);
            }
            catch (IOException exception)
            {
                lastException = exception;
                await Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken);
            }
        }

        throw new TimeoutException(
            "Timed out waiting for another OpenClaw installation operation.",
            lastException);
    }

    private static void RecoverInterruptedPromotion(
        string installDirectory,
        string temporaryDirectory,
        string backupDirectory)
    {
        DeleteDirectory(temporaryDirectory);

        if (!Directory.Exists(installDirectory) &&
            Directory.Exists(backupDirectory))
        {
            Directory.Move(backupDirectory, installDirectory);
        }
        else if (Directory.Exists(installDirectory))
        {
            DeleteDirectory(backupDirectory);
        }
    }

    private static async Task<IReadOnlyList<PayloadInventoryEntry>> ReadPayloadAsync(
        string payloadPath,
        string? destinationRoot,
        CancellationToken cancellationToken)
    {
        string? rootPrefix = destinationRoot is null
            ? null
            : Path.GetFullPath(destinationRoot)
                .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var seenPaths = new HashSet<string>(PathComparer);
        var inventory = new List<PayloadInventoryEntry>();
        long extractedBytes = 0;
        int entryCount = 0;

        await using FileStream payloadStream = File.OpenRead(payloadPath);
        await using var gzipStream = new GZipStream(
            payloadStream,
            CompressionMode.Decompress,
            leaveOpen: false);
        using var reader = new TarReader(gzipStream, leaveOpen: false);

        TarEntry? entry;
        while ((entry = await reader.GetNextEntryAsync(
            copyData: false,
            cancellationToken)) is not null)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (++entryCount > MaximumEntryCount)
            {
                throw new InvalidDataException("Payload contains too many archive entries.");
            }

            string relativePath = NormalizeEntryPath(entry.Name);
            if (relativePath.Length == 0)
            {
                continue;
            }

            string? destinationPath = destinationRoot is null
                ? null
                : Path.GetFullPath(Path.Combine(destinationRoot, relativePath));
            if (destinationPath is not null &&
                !destinationPath.StartsWith(rootPrefix!, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException(
                    $"Payload entry escapes the staging directory: {entry.Name}");
            }

            switch (entry.EntryType)
            {
                case TarEntryType.Directory:
                    if (destinationPath is not null)
                    {
                        Directory.CreateDirectory(destinationPath);
                    }
                    break;
                case TarEntryType.RegularFile:
                case TarEntryType.V7RegularFile:
                    if (!seenPaths.Add(relativePath))
                    {
                        throw new InvalidDataException(
                            $"Payload contains a duplicate file path: {entry.Name}");
                    }

                    extractedBytes = checked(extractedBytes + entry.Length);
                    if (extractedBytes > MaximumExtractedBytes)
                    {
                        throw new InvalidDataException("Payload is too large after extraction.");
                    }

                    if (entry.DataStream is null && entry.Length != 0)
                    {
                        throw new InvalidDataException(
                            $"Payload file has no data stream: {entry.Name}");
                    }

                    string hash;
                    if (destinationPath is null)
                    {
                        byte[] contentHash = entry.DataStream is null
                            ? SHA256.HashData(Array.Empty<byte>())
                            : await SHA256.HashDataAsync(
                                entry.DataStream,
                                cancellationToken);
                        hash = Convert.ToHexString(contentHash).ToLowerInvariant();
                    }
                    else
                    {
                        string? parentDirectory = Path.GetDirectoryName(destinationPath);
                        if (parentDirectory is not null)
                        {
                            Directory.CreateDirectory(parentDirectory);
                        }

                        await using (FileStream output = new(
                            destinationPath,
                            FileMode.CreateNew,
                            FileAccess.Write,
                            FileShare.None))
                        {
                            if (entry.DataStream is not null)
                            {
                                await entry.DataStream.CopyToAsync(
                                    output,
                                    cancellationToken);
                            }
                        }

                        hash = await ComputeHashAsync(destinationPath, cancellationToken);
                    }

                    inventory.Add(new PayloadInventoryEntry(
                        ToArchivePath(relativePath),
                        entry.Length,
                        hash));
                    break;
                default:
                    throw new InvalidDataException(
                        $"Payload entry type is not supported: {entry.EntryType}");
            }
        }

        return inventory.OrderBy(item => item.Path, PathComparer).ToArray();
    }

    private static async Task VerifyStagedPayloadAsync(
        string versionDirectory,
        string expectedPayloadHash,
        string payloadPath,
        CancellationToken cancellationToken)
    {
        string inventoryPath = Path.Combine(versionDirectory, InventoryFileName);
        if (!File.Exists(inventoryPath))
        {
            throw new InvalidDataException("Staged payload inventory is missing.");
        }

        PayloadInventory? inventory;
        try
        {
            await using FileStream stream = File.OpenRead(inventoryPath);
            inventory = await JsonSerializer.DeserializeAsync<PayloadInventory>(
                stream,
                cancellationToken: cancellationToken);
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException(
                "Staged payload inventory is malformed.",
                exception);
        }

        if (inventory is null ||
            inventory.Files is null ||
            !string.Equals(
                inventory.PayloadSha256,
                expectedPayloadHash,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Staged payload inventory is invalid.");
        }

        IReadOnlyList<PayloadInventoryEntry> trustedFiles = await ReadPayloadAsync(
            payloadPath,
            destinationRoot: null,
            cancellationToken);
        var trustedByPath = trustedFiles.ToDictionary(item => item.Path, PathComparer);
        if (inventory.Files.Count != trustedFiles.Count ||
            inventory.Files.Any(item =>
                item.Path is null ||
                !trustedByPath.TryGetValue(item.Path, out PayloadInventoryEntry? trusted) ||
                item.Length != trusted.Length ||
                !string.Equals(
                    item.Sha256,
                    trusted.Sha256,
                    StringComparison.OrdinalIgnoreCase)))
        {
            throw new InvalidDataException("Staged payload inventory is invalid.");
        }

        var expectedFiles = new HashSet<string>(
            trustedFiles.Select(item => item.Path),
            PathComparer);
        foreach (string filePath in Directory.EnumerateFiles(
            versionDirectory,
            "*",
            SearchOption.AllDirectories))
        {
            string relativePath = ToArchivePath(
                Path.GetRelativePath(versionDirectory, filePath));
            if (PathComparer.Equals(relativePath, InventoryFileName))
            {
                continue;
            }

            if (!expectedFiles.Remove(relativePath))
            {
                throw new InvalidDataException(
                    $"Staged payload contains an unexpected file: {relativePath}");
            }
        }

        if (expectedFiles.Count > 0)
        {
            throw new InvalidDataException("Staged payload is missing one or more files.");
        }

        foreach (PayloadInventoryEntry item in trustedFiles)
        {
            string filePath = Path.Combine(
                versionDirectory,
                item.Path.Replace('/', Path.DirectorySeparatorChar));
            var fileInfo = new FileInfo(filePath);
            if (fileInfo.Length != item.Length ||
                !string.Equals(
                    await ComputeHashAsync(filePath, cancellationToken),
                    item.Sha256,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException(
                    $"Staged payload file failed verification: {item.Path}");
            }
        }

        EnsureOpenClawEntryPoint(versionDirectory);
    }

    private static string NormalizeEntryPath(string entryName)
    {
        string normalized = entryName.Replace('\\', '/');
        while (normalized.StartsWith("./", StringComparison.Ordinal))
        {
            normalized = normalized[2..];
        }

        normalized = normalized.TrimEnd('/');
        if (normalized.Length == 0)
        {
            return string.Empty;
        }

        if (normalized[0] == '/' ||
            Path.IsPathFullyQualified(normalized))
        {
            throw new InvalidDataException($"Payload entry path is absolute: {entryName}");
        }

        string[] segments = normalized.Split('/');
        foreach (string segment in segments)
        {
            if (segment.Length == 0 ||
                segment is "." or ".." ||
                segment.EndsWith(' ') ||
                segment.EndsWith('.') ||
                segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                IsReservedWindowsName(segment))
            {
                throw new InvalidDataException($"Payload entry path is unsafe: {entryName}");
            }
        }

        return string.Join(Path.DirectorySeparatorChar, segments);
    }

    private static bool IsReservedWindowsName(string segment)
    {
        string baseName = segment.Split('.')[0];
        return baseName.Equals("CON", StringComparison.OrdinalIgnoreCase) ||
            baseName.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
            baseName.Equals("AUX", StringComparison.OrdinalIgnoreCase) ||
            baseName.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
            (baseName.Length == 4 &&
             (baseName.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
              baseName.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) &&
             baseName[3] is >= '1' and <= '9');
    }

    private static void EnsureOpenClawEntryPoint(string directory)
    {
        if (!File.Exists(Path.Combine(directory, "openclaw.mjs")))
        {
            throw new InvalidDataException("Payload does not contain openclaw.mjs.");
        }
    }

    private static async Task<string> ComputeHashAsync(
        string path,
        CancellationToken cancellationToken)
    {
        await using FileStream stream = File.OpenRead(path);
        byte[] hash = await SHA256.HashDataAsync(stream, cancellationToken);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static string ToArchivePath(string path) =>
        path.Replace(Path.DirectorySeparatorChar, '/');

    private static void DeleteDirectory(string path)
    {
        if (Directory.Exists(path))
        {
            Directory.Delete(path, recursive: true);
        }
    }

    private sealed record PayloadInventory(
        string PayloadSha256,
        IReadOnlyList<PayloadInventoryEntry> Files);

    private sealed record PayloadInventoryEntry(
        string Path,
        long Length,
        string Sha256);
}

public sealed record StagedPayload(string DirectoryPath, string PayloadSha256);
