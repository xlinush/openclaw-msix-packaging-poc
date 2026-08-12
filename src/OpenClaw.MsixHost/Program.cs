namespace OpenClaw.MsixHost;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            HostOptions options = HostOptions.Parse(args);
            if (options.ShowHelp)
            {
                HostOptions.WriteHelp(Console.Out);
                return 0;
            }

            var stager = new PayloadStager(options.InstallDirectory);
            StagedPayload payload = await stager.StageAsync(
                options.PayloadPath,
                options.MetadataPath,
                CancellationToken.None);

            return await GatewayLauncher.RunAsync(
                options.NodePath,
                payload.DirectoryPath,
                options.OpenClawArguments,
                CancellationToken.None);
        }
        catch (HostUsageException exception)
        {
            Console.Error.WriteLine(exception.Message);
            Console.Error.WriteLine();
            HostOptions.WriteHelp(Console.Error);
            return 2;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"openclaw-poc: {exception.Message}");
            return 1;
        }
    }
}
