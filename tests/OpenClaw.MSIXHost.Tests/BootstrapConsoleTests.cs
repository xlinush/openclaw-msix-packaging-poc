namespace OpenClaw.MSIXHost.Tests;

public sealed class BootstrapConsoleTests : IDisposable
{
    private readonly string _testDirectory = TestDirectory.Create();

    [Fact]
    public void PromptForFullVerificationSkipsPromptForFirstLaunch()
    {
        var output = new StringWriter();

        bool verify = BootstrapConsole.PromptForFullVerification(
            Path.Combine(_testDirectory, "missing"),
            new StringReader("r"),
            output);

        Assert.False(verify);
        Assert.Empty(output.ToString());
    }

    [Theory]
    [InlineData("")]
    [InlineData("c")]
    [InlineData("C")]
    public void PromptForFullVerificationDefaultsToFastVerification(string response)
    {
        Directory.CreateDirectory(Path.Combine(_testDirectory, "app"));

        bool verify = BootstrapConsole.PromptForFullVerification(
            Path.Combine(_testDirectory, "app"),
            new StringReader(response),
            new StringWriter());

        Assert.False(verify);
    }

    [Fact]
    public void PromptForFullVerificationAllowsRetry()
    {
        string installDirectory = Path.Combine(_testDirectory, "app");
        Directory.CreateDirectory(installDirectory);
        var output = new StringWriter();

        bool verify = BootstrapConsole.PromptForFullVerification(
            installDirectory,
            new StringReader($"invalid{Environment.NewLine}r"),
            output);

        Assert.True(verify);
        Assert.Contains(
            "Enter C to continue or R to retry",
            output.ToString(),
            StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(true, "existing prepared payload was verified and reused")]
    [InlineData(false, "packaged payload was verified and prepared")]
    public void WritePreparationSummaryUsesPackagedAlias(
        bool reused,
        string expectedStatus)
    {
        var output = new StringWriter();

        BootstrapConsole.WritePreparationSummary(
            output,
            new StagedPayload(
                Path.Combine(_testDirectory, "app"),
                new string('a', 64),
                reused));

        string summary = output.ToString();
        Assert.Contains(expectedStatus, summary, StringComparison.Ordinal);
        Assert.Contains("openclaw-poc setup", summary, StringComparison.Ordinal);
        Assert.Contains(
            "openclaw-poc gateway run",
            summary,
            StringComparison.Ordinal);
        Assert.Contains(
            "did not start the gateway automatically",
            summary,
            StringComparison.Ordinal);
    }

    [Fact]
    public void WaitForExitPrintsPersistentConsoleInstruction()
    {
        var output = new StringWriter();

        BootstrapConsole.WaitForExit(
            new StringReader(Environment.NewLine),
            output);

        Assert.Contains(
            "Press Enter to close this window",
            output.ToString(),
            StringComparison.Ordinal);
    }

    public void Dispose()
    {
        Directory.Delete(_testDirectory, recursive: true);
        GC.SuppressFinalize(this);
    }
}
