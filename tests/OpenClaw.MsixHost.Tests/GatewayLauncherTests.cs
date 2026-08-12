namespace OpenClaw.MsixHost.Tests;

public sealed class GatewayLauncherTests : IDisposable
{
    private readonly string _payloadDirectory = TestDirectory.Create();

    public GatewayLauncherTests()
    {
        File.WriteAllText(
            Path.Combine(_payloadDirectory, "openclaw.mjs"),
            "console.log('fixture');");
    }

    [Fact]
    public void CreateStartInfoDefaultsToForegroundGateway()
    {
        var startInfo = GatewayLauncher.CreateStartInfo(
            "node",
            _payloadDirectory,
            []);

        Assert.False(startInfo.UseShellExecute);
        Assert.Equal(_payloadDirectory, startInfo.WorkingDirectory);
        Assert.Equal(
            [
                Path.Combine(_payloadDirectory, "openclaw.mjs"),
                "gateway",
                "run"
            ],
            startInfo.ArgumentList);
    }

    [Fact]
    public void CreateStartInfoPreservesExplicitArguments()
    {
        string[] arguments = ["status", "--json", "value with spaces"];

        var startInfo = GatewayLauncher.CreateStartInfo(
            "node",
            _payloadDirectory,
            arguments);

        Assert.Equal(
            [Path.Combine(_payloadDirectory, "openclaw.mjs"), .. arguments],
            startInfo.ArgumentList);
    }

    public void Dispose()
    {
        Directory.Delete(_payloadDirectory, recursive: true);
        GC.SuppressFinalize(this);
    }
}
