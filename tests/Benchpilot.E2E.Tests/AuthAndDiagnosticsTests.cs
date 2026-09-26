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
    public void Cli_Reports_Product_Version()
    {
        var (exitCode, stdout) = Env.RunCli("--version");
        Assert.Equal(0, exitCode);
        Assert.Matches(@"^\d+\.\d+\.\d+$", stdout.Trim());

        var (versionExit, versionOut) = Env.RunCli("version");
        Assert.Equal(0, versionExit);
        Assert.Equal(stdout.Trim(), versionOut.Trim());
    }

    [Fact]
    public void Healthz_And_Status_Expose_Runtime_Version()
    {
        using var http = new HttpClient();
        using var health = http.GetAsync(new Uri(Env.Endpoint, "healthz")).GetAwaiter().GetResult();
        health.EnsureSuccessStatusCode();
        using var healthBody = JsonDocument.Parse(health.Content.ReadAsStringAsync().GetAwaiter().GetResult());
        Assert.Matches(@"^\d+\.\d+\.\d+$", healthBody.RootElement.GetProperty("version").GetString());

        using (var status = Env.RunCliJson("status", "--json"))
        {
            Assert.Matches(
                @"^\d+\.\d+\.\d+$",
                status.RootElement.GetProperty("runtimeVersion").GetString());
        }
    }

    [Fact]
    public void Api_Rejects_Requests_Without_Token()
    {
        using var http = new HttpClient();
        var request = new HttpRequestMessage(HttpMethod.Get, new Uri(Env.Endpoint, "api/v1/status"));
        using var response = http.SendAsync(request).GetAwaiter().GetResult();

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        using var body = JsonDocument.Parse(response.Content.ReadAsStringAsync().GetAwaiter().GetResult());
        Assert.Equal("unauthorized", body.RootElement.GetProperty("code").GetString());
        Assert.False(string.IsNullOrWhiteSpace(body.RootElement.GetProperty("error").GetString()));
    }

    [Fact]
    public void Api_Rejects_Wrong_Token()
    {
        using var http = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(Env.Endpoint, "api/v1/status"));
        request.Headers.Add("X-Benchpilot-Token", "definitely-not-the-token");
        using var response = http.SendAsync(request).GetAwaiter().GetResult();
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public void Doctor_Reports_Healthy_Installation()
    {
        using var doctor = Env.RunCliJson("doctor", "--json");
        var root = doctor.RootElement;

        Assert.True(root.GetProperty("ok").GetBoolean());
        Assert.True(root.GetProperty("runtimeReachable").GetBoolean());
        Assert.True(root.GetProperty("tokenFound").GetBoolean());
        Assert.True(root.GetProperty("daemonFound").GetBoolean());
        Assert.True(root.GetProperty("versionMatch").GetBoolean());
        Assert.Null(root.GetProperty("remediation").GetString());
    }

    [Fact]
    public void History_Records_Completed_Mutations()
    {
        Env.RunCliJson("power", "on", "--voltage", "12", "--settle-ms", "100", "--json");
        Env.RunCliJson("power", "off", "--json");

        using var history = Env.RunCliJson("history", "--limit", "5", "--json");
        var operations = history.RootElement.GetProperty("operations").EnumerateArray().ToList();
        Assert.Contains(operations, x => x.GetProperty("kind").GetString() == "power.on");
        Assert.Contains(operations, x => x.GetProperty("state").GetString() == "completed");
    }
}
