using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace Benchpilot.E2E.Tests;

/// <summary>
/// Version exposure, doctor output and loopback token enforcement, all
/// through the real process/HTTP boundary.
/// </summary>
[Collection("shared-daemon")]
public sealed class AuthAndDiagnosticsTests(SharedDaemonFixture fixture)
{
    private E2EEnvironment Env => fixture.Environment;

    [Fact]
    public async Task Cli_Reports_Product_Version()
    {
        var (exitCode, stdout) = await Env.RunCliAsync("--version");
        Assert.Equal(0, exitCode);
        Assert.Matches(@"^\d+\.\d+\.\d+$", stdout.Trim());

        var (versionExit, versionOut) = await Env.RunCliAsync("version");
        Assert.Equal(0, versionExit);
        Assert.Equal(stdout.Trim(), versionOut.Trim());
    }

    [Fact]
    public async Task Healthz_And_Status_Expose_Runtime_Version()
    {
        using var http = new HttpClient();
        using var health = await http.GetAsync(new Uri(Env.Endpoint, "healthz"));
        health.EnsureSuccessStatusCode();
        using var healthBody = JsonDocument.Parse(await health.Content.ReadAsStringAsync());
        Assert.Matches(@"^\d+\.\d+\.\d+$", healthBody.RootElement.GetProperty("version").GetString());

        using (var status = await Env.RunCliJsonAsync("status", "--json"))
        {
            Assert.Matches(
                @"^\d+\.\d+\.\d+$",
                status.RootElement.GetProperty("runtimeVersion").GetString());
        }
    }

    [Fact]
    public async Task Api_Rejects_Requests_Without_Token()
    {
        using var http = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(Env.Endpoint, "api/v1/status"));
        using var response = await http.SendAsync(request);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        Assert.Equal("unauthorized", body.RootElement.GetProperty("code").GetString());
        Assert.False(string.IsNullOrWhiteSpace(body.RootElement.GetProperty("error").GetString()));
    }

    [Fact]
    public async Task Api_Rejects_Wrong_Token()
    {
        using var http = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(Env.Endpoint, "api/v1/status"));
        request.Headers.Add("X-Benchpilot-Token", "definitely-not-the-token");
        using var response = await http.SendAsync(request);
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Doctor_Reports_Healthy_Installation()
    {
        using var doctor = await Env.RunCliJsonAsync("doctor", "--json");
        var root = doctor.RootElement;

        Assert.True(root.GetProperty("ok").GetBoolean());
        Assert.True(root.GetProperty("runtimeReachable").GetBoolean());
        Assert.True(root.GetProperty("tokenFound").GetBoolean());
        Assert.True(root.GetProperty("daemonFound").GetBoolean());
        Assert.True(root.GetProperty("versionMatch").GetBoolean());
        Assert.Null(root.GetProperty("remediation").GetString());
    }

    [Fact]
    public async Task History_Records_Completed_Mutations()
    {
        await Env.RunCliJsonAsync("power", "on", "--voltage", "12", "--settle-ms", "100", "--json");
        await Env.RunCliJsonAsync("power", "off", "--json");

        using var history = await Env.RunCliJsonAsync("history", "--limit", "5", "--json");
        var operations = history.RootElement.GetProperty("operations").EnumerateArray().ToList();
        Assert.Contains(operations, x => x.GetProperty("kind").GetString() == "power.on");
        Assert.Contains(operations, x => x.GetProperty("state").GetString() == "completed");
    }
}
