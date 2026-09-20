using Benchpilot.Core;
using Benchpilot.Drivers.JLink;
using Benchpilot.Drivers.Serial;
using Benchpilot.Runtime;

namespace Benchpilot.Core.Tests;

public class DriverFactoryTests
{
    [Fact]
    public void System_serial_factory_builds_profile_driven_resource_without_opening_port()
    {
        var profile = ProfileLoader.LoadJson("""
        {
          "schemaVersion": 1,
          "resources": {
            "uart.ecu": {
              "driver": "system-serial",
              "capabilities": ["serial"],
              "settings": { "port": "COM_TEST", "baud": 230400 }
            }
          },
          "targets": {
            "ecu": { "bindings": { "serial": "uart.ecu" } }
          }
        }
        """);

        var factory = new SystemSerialResourceFactory();
        var channel = Assert.IsType<SystemSerialChannel>(
            factory.Create("uart.ecu", profile.Resources["uart.ecu"]));

        Assert.False(channel.IsOpen);
        channel.Dispose();
    }

    [Fact]
    public void System_serial_factory_rejects_wrong_capability()
    {
        var profile = ProfileLoader.LoadJson("""
        {
          "schemaVersion": 1,
          "resources": {
            "wrong": {
              "driver": "system-serial",
              "capabilities": ["flash"]
            }
          },
          "targets": {
            "ecu": { "bindings": { "flash": "wrong" } }
          }
        }
        """);

        var ex = Assert.Throws<InvalidOperationException>(() =>
            new SystemSerialResourceFactory().Create("wrong", profile.Resources["wrong"]));

        Assert.Contains("serial", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void JLink_factory_requires_device_setting()
    {
        var profile = ProfileLoader.LoadJson("""
        {
          "schemaVersion": 1,
          "resources": {
            "probe.ecu": {
              "driver": "jlink",
              "capabilities": ["flash"],
              "settings": { "interface": "SWD" }
            }
          },
          "targets": {
            "ecu": { "bindings": { "flash": "probe.ecu" } }
          }
        }
        """);

        var ex = Assert.Throws<InvalidOperationException>(() =>
            new JLinkResourceFactory().Create("probe.ecu", profile.Resources["probe.ecu"]));

        Assert.Contains("device", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task JLink_binary_requires_explicit_address_before_process_launch()
    {
        var temp = Path.Combine(Path.GetTempPath(), $"benchpilot-{Guid.NewGuid():N}.bin");
        await File.WriteAllBytesAsync(temp, [0x01, 0x02, 0x03, 0x04]);

        try
        {
            var target = new JLinkFlashTarget(new JLinkSettings(
                "definitely-not-installed-jlink-command",
                "TEST_DEVICE",
                "SWD",
                4000,
                null,
                5000,
                null));

            var result = await target.Flash(temp);

            Assert.False(result.Ok);
            Assert.Contains("binAddress", result.Error, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("Could not start", result.Error ?? string.Empty, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            File.Delete(temp);
        }
    }

    [Fact]
    public void Driver_registry_rejects_unsupported_profile_driver()
    {
        var profile = ProfileLoader.LoadJson("""
        {
          "schemaVersion": 1,
          "resources": {
            "mystery": {
              "driver": "unknown-vendor",
              "capabilities": ["serial"]
            }
          },
          "targets": {
            "ecu": { "bindings": { "serial": "mystery" } }
          }
        }
        """);

        var registry = new BenchDriverRegistry(Array.Empty<IBenchResourceFactory>());
        var ex = Assert.Throws<InvalidOperationException>(() => registry.CreateRuntime(profile));

        Assert.Contains("unknown-vendor", ex.Message);
        Assert.Contains("Available drivers", ex.Message);
    }

    [Fact]
    public void Runtime_disposes_driver_owned_resources()
    {
        var profile = ProfileLoader.LoadJson("""
        {
          "schemaVersion": 1,
          "resources": {
            "fake.device": {
              "driver": "fake",
              "capabilities": ["serial"]
            }
          },
          "targets": {
            "ecu": { "bindings": { "serial": "fake.device" } }
          }
        }
        """);

        var marker = new DisposableMarker();
        var registry = new BenchDriverRegistry([new FakeFactory(marker)]);
        var runtime = registry.CreateRuntime(profile);

        Assert.False(marker.Disposed);
        runtime.Dispose();
        Assert.True(marker.Disposed);
    }

    private sealed class FakeFactory(DisposableMarker marker) : IBenchResourceFactory
    {
        public string DriverName => "fake";
        public object Create(string resourceId, BenchResourceConfig config) => marker;
    }

    private sealed class DisposableMarker : IDisposable
    {
        public bool Disposed { get; private set; }
        public void Dispose() => Disposed = true;
    }
}
