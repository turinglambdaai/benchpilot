using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Benchpilot.Core;
using Benchpilot.Drivers.ScpiPower;

namespace Benchpilot.Core.Tests;

public class ScpiPowerTests
{
    [Fact]
    public async Task Power_supply_executes_profile_driven_tcp_scpi_flow()
    {
        await using var server = new FakeScpiServer(new Dictionary<string, string?>
        {
            ["MEAS:VOLT?"] = "12.04",
            ["MEAS:CURR?"] = "0.123",
        });

        using var supply = NewSupply(server.Port, ioTimeoutMs: 2000);

        var on = await supply.PowerOn(12, 0);
        Assert.True(on.Ok, on.Error);
        Assert.Equal(12.04, on.Voltage, 3);
        Assert.Equal(123, on.CurrentMa, 3);
        Assert.True(supply.IsOn);

        var off = await supply.PowerOff();
        Assert.True(off.Ok, off.Error);
        Assert.False(supply.IsOn);

        await server.WaitForCommand("OUTP OFF", TimeSpan.FromSeconds(2));
        var commands = server.Commands.ToArray();
        Assert.Contains("VOLT 12", commands);
        Assert.Contains("CURR 1.5", commands);
        Assert.Contains("OUTP ON", commands);
        Assert.Contains("MEAS:VOLT?", commands);
        Assert.Contains("MEAS:CURR?", commands);
        Assert.Contains("OUTP OFF", commands);
    }

    [Fact]
    public async Task Device_response_timeout_is_reported_as_device_error_and_triggers_safety_off()
    {
        await using var server = new FakeScpiServer(new Dictionary<string, string?>
        {
            ["MEAS:VOLT?"] = null,
        });

        using var supply = NewSupply(server.Port, ioTimeoutMs: 150);

        var result = await supply.PowerOn(12, 0);

        Assert.False(result.Ok);
        Assert.Contains("timed out", result.Error, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("cancel", result.Error ?? string.Empty, StringComparison.OrdinalIgnoreCase);
        Assert.False(supply.IsOn);
        await server.WaitForCommand("OUTP OFF", TimeSpan.FromSeconds(2));
    }

    [Fact]
    public async Task Health_check_uses_identify_query_without_changing_output_state()
    {
        await using var server = new FakeScpiServer(new Dictionary<string, string?>
        {
            ["*IDN?"] = "BenchCo,PSU-1,1234,1.0",
        });

        using var supply = NewSupply(server.Port, ioTimeoutMs: 2000);

        var result = await supply.CheckHealth();

        Assert.True(result.Ok, result.Error);
        Assert.Equal("BenchCo,PSU-1,1234,1.0", result.Details?["idn"]);
        Assert.False(supply.IsOn);
        await server.WaitForCommand("*IDN?", TimeSpan.FromSeconds(2));
        Assert.DoesNotContain("OUTP ON", server.Commands);
        Assert.DoesNotContain("OUTP OFF", server.Commands);
    }

    [Fact]
    public void Factory_requires_host_and_power_capability()
    {
        var missingHost = ProfileLoader.LoadJson("""
        {
          "schemaVersion": 1,
          "resources": {
            "psu": { "driver": "scpi-power", "capabilities": ["power"] }
          },
          "targets": {
            "ecu": { "bindings": { "power": "psu" } }
          }
        }
        """);

        Assert.Throws<InvalidOperationException>(() =>
            new ScpiPowerResourceFactory().Create("psu", missingHost.Resources["psu"]));

        var wrongCapability = ProfileLoader.LoadJson("""
        {
          "schemaVersion": 1,
          "resources": {
            "psu": {
              "driver": "scpi-power",
              "capabilities": ["serial"],
              "settings": { "host": "127.0.0.1" }
            }
          },
          "targets": {
            "ecu": { "bindings": { "serial": "psu" } }
          }
        }
        """);

        var ex = Assert.Throws<InvalidOperationException>(() =>
            new ScpiPowerResourceFactory().Create("psu", wrongCapability.Resources["psu"]));
        Assert.Contains("power", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Factory_rejects_multiline_command_templates()
    {
        var profile = ProfileLoader.LoadJson("""
        {
          "schemaVersion": 1,
          "resources": {
            "psu": {
              "driver": "scpi-power",
              "capabilities": ["power"],
              "settings": {
                "host": "127.0.0.1",
                "outputOn": "OUTP ON\n*RST"
              }
            }
          },
          "targets": {
            "ecu": { "bindings": { "power": "psu" } }
          }
        }
        """);

        var ex = Assert.Throws<InvalidOperationException>(() =>
            new ScpiPowerResourceFactory().Create("psu", profile.Resources["psu"]));
        Assert.Contains("single-line", ex.Message);
    }

    private static ScpiPowerSupply NewSupply(int port, int ioTimeoutMs) =>
        new(new ScpiPowerSettings(
            "127.0.0.1",
            port,
            2000,
            ioTimeoutMs,
            1.5,
            null,
            new ScpiPowerCommands(
                "VOLT {voltage}",
                "CURR {current}",
                "OUTP ON",
                "OUTP OFF",
                "MEAS:VOLT?",
                "MEAS:CURR?",
                "*IDN?")));

    private sealed class FakeScpiServer : IAsyncDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly IReadOnlyDictionary<string, string?> _responses;
        private readonly CancellationTokenSource _stop = new();
        private readonly Task _serverTask;

        public FakeScpiServer(IReadOnlyDictionary<string, string?> responses)
        {
            _responses = responses;
            _listener.Start();
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _serverTask = Run(_stop.Token);
        }

        public int Port { get; }
        public ConcurrentQueue<string> Commands { get; } = new();

        public async Task WaitForCommand(string expected, TimeSpan timeout)
        {
            using var cts = new CancellationTokenSource(timeout);
            while (!Commands.Contains(expected, StringComparer.OrdinalIgnoreCase))
                await Task.Delay(10, cts.Token);
        }

        private async Task Run(CancellationToken ct)
        {
            try
            {
                using var client = await _listener.AcceptTcpClientAsync(ct);
                using var stream = client.GetStream();
                using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true);
                using var writer = new StreamWriter(stream, Encoding.ASCII, 1024, leaveOpen: true)
                {
                    AutoFlush = true,
                    NewLine = "\n",
                };

                while (!ct.IsCancellationRequested)
                {
                    var line = await reader.ReadLineAsync(ct);
                    if (line is null) break;
                    Commands.Enqueue(line);

                    if (_responses.TryGetValue(line, out var response) && response is not null)
                        await writer.WriteLineAsync(response.AsMemory(), ct);
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
            }
            catch (ObjectDisposedException) when (ct.IsCancellationRequested)
            {
            }
        }

        public async ValueTask DisposeAsync()
        {
            _stop.Cancel();
            _listener.Stop();
            try { await _serverTask; } catch (SocketException) { }
            _stop.Dispose();
        }
    }
}
