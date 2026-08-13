namespace OpenClaw.MsixHost;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        HostDiagnosticLog? diagnostics = null;
        bool diagnosticWarningWritten = false;
        bool consoleWarningWritten = false;

        void WriteConsoleError(string message)
        {
            try
            {
                Console.Error.WriteLine(message);
            }
            catch (Exception exception) when (
                exception is IOException or ObjectDisposedException)
            {
                if (!consoleWarningWritten)
                {
                    consoleWarningWritten = true;
                    WriteDiagnostic(
                        $"Console error output failed: {exception.GetType().Name}.");
                }
            }
        }

        try
        {
            diagnostics = HostDiagnosticLog.Create();
        }
        catch (Exception exception) when (
            exception is IOException or
            UnauthorizedAccessException or
            InvalidOperationException)
        {
            diagnosticWarningWritten = true;
            WriteConsoleError(
                $"openclaw-poc: Unable to create diagnostics: {exception.Message}");
        }

        void WriteDiagnostic(string message)
        {
            if (diagnostics is null)
            {
                return;
            }

            try
            {
                diagnostics.Write(message);
            }
            catch (Exception exception) when (
                exception is IOException or
                UnauthorizedAccessException or
                ObjectDisposedException)
            {
                if (!diagnosticWarningWritten)
                {
                    diagnosticWarningWritten = true;
                    WriteConsoleError(
                        $"openclaw-poc: Unable to write diagnostics: {exception.Message}");
                }
            }
        }

        static string GetDiagnosticFailure(Exception exception) =>
            exception switch
            {
                HostUsageException or
                InvalidDataException or
                TimeoutException or
                PlatformNotSupportedException or
                FileNotFoundException =>
                    $"{exception.GetType().Name}: {exception.Message}",
                _ => exception.GetType().Name
            };

        void ReportProgress(string message)
        {
            WriteDiagnostic(message);
            WriteConsoleError($"openclaw-poc: {message}");
        }

        try
        {
            WriteDiagnostic("Host started.");
            if (diagnostics is not null)
            {
                WriteConsoleError(
                    $"openclaw-poc: Diagnostics: {diagnostics.Path}");
            }

            HostOptions options = HostOptions.Parse(args);
            if (options.ShowHelp)
            {
                WriteDiagnostic("Showing host help.");
                HostOptions.WriteHelp(Console.Out);
                return 0;
            }

            var stager = new PayloadStager(
                options.InstallDirectory,
                ReportProgress);
            StagedPayload payload = await stager.StageAsync(
                options.PayloadPath,
                options.MetadataPath,
                CancellationToken.None);

            int exitCode = await GatewayLauncher.RunAsync(
                options.NodePath,
                payload.DirectoryPath,
                options.OpenClawArguments,
                CancellationToken.None,
                ReportProgress);
            if (exitCode == 78)
            {
                ReportProgress(
                    "OpenClaw reported a configuration error (exit code 78). " +
                    "For first-run setup, run `openclaw-poc setup` or " +
                    "`openclaw-poc onboard --mode local`, then retry.");
            }

            return exitCode;
        }
        catch (HostUsageException exception)
        {
            WriteDiagnostic($"Usage error: {exception.Message}");
            WriteConsoleError(exception.Message);
            WriteConsoleError(string.Empty);
            HostOptions.WriteHelp(Console.Error);
            return 2;
        }
        catch (Exception exception)
        {
            WriteDiagnostic($"Unhandled failure: {GetDiagnosticFailure(exception)}");
            WriteConsoleError($"openclaw-poc: {exception.Message}");
            if (diagnostics is not null)
            {
                WriteConsoleError(
                    $"openclaw-poc: See diagnostics: {diagnostics.Path}");
            }
            return 1;
        }
        finally
        {
            WriteDiagnostic("Host exiting.");
            diagnostics?.Dispose();
        }
    }
}
