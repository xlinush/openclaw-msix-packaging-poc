namespace OpenClaw.MSIXHost;

public static class BootstrapConsole
{
    public static bool PromptForFullVerification(
        string installDirectory,
        TextReader input,
        TextWriter output)
    {
        if (!Directory.Exists(installDirectory))
        {
            return false;
        }

        output.WriteLine();
        output.WriteLine("OpenClaw files were prepared by an earlier launch:");
        output.WriteLine($"  {installDirectory}");
        output.WriteLine();
        output.WriteLine("[C] Continue with fast verification");
        output.WriteLine("[R] Retry preparation with full verification and repair");

        while (true)
        {
            output.Write("Choose an option [C]: ");
            string? response = input.ReadLine();
            if (string.IsNullOrWhiteSpace(response) ||
                response.Equals("c", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            if (response.Equals("r", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            output.WriteLine("Enter C to continue or R to retry preparation.");
        }
    }

    public static void WritePreparationSummary(
        TextWriter output,
        StagedPayload payload)
    {
        output.WriteLine();
        output.WriteLine("OpenClaw gateway files are ready.");
        output.WriteLine(
            payload.Reused
                ? "The existing prepared payload was verified and reused."
                : "The packaged payload was verified and prepared.");
        output.WriteLine($"Prepared files: {payload.DirectoryPath}");
        output.WriteLine();
        output.WriteLine("Next steps:");
        output.WriteLine("  1. Configure OpenClaw:");
        output.WriteLine("     openclaw-poc setup");
        output.WriteLine("     or: openclaw-poc onboard --mode local");
        output.WriteLine("  2. Start the gateway after setup:");
        output.WriteLine("     openclaw-poc gateway run");
        output.WriteLine();
        output.WriteLine(
            "This bootstrap launch did not start the gateway automatically.");
    }

    public static void WaitForExit(TextReader input, TextWriter output)
    {
        output.WriteLine();
        output.Write("Press Enter to close this window...");
        input.ReadLine();
    }
}
