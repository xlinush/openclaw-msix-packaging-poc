using System.Diagnostics;

namespace OpenClaw.MsixHost;

public static class GatewayLauncher
{
    public static async Task<int> RunAsync(
        string nodePath,
        string payloadDirectory,
        IReadOnlyList<string> openClawArguments,
        CancellationToken cancellationToken)
    {
        ProcessStartInfo startInfo = CreateStartInfo(
            nodePath,
            payloadDirectory,
            openClawArguments);
        using Process process = Process.Start(startInfo) ??
            throw new InvalidOperationException("Unable to start the OpenClaw process.");
        await process.WaitForExitAsync(cancellationToken);
        return process.ExitCode;
    }

    public static ProcessStartInfo CreateStartInfo(
        string nodePath,
        string payloadDirectory,
        IReadOnlyList<string> openClawArguments)
    {
        string entryPoint = Path.Combine(payloadDirectory, "openclaw.mjs");
        if (!File.Exists(entryPoint))
        {
            throw new FileNotFoundException(
                "The staged OpenClaw entry point was not found.",
                entryPoint);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = nodePath,
            WorkingDirectory = payloadDirectory,
            UseShellExecute = false,
            RedirectStandardInput = false,
            RedirectStandardOutput = false,
            RedirectStandardError = false
        };
        startInfo.ArgumentList.Add(entryPoint);

        if (openClawArguments.Count == 0)
        {
            startInfo.ArgumentList.Add("gateway");
            startInfo.ArgumentList.Add("run");
        }
        else
        {
            foreach (string argument in openClawArguments)
            {
                startInfo.ArgumentList.Add(argument);
            }
        }

        return startInfo;
    }
}
