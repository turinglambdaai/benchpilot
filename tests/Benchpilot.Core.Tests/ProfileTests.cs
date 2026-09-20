using Benchpilot.Core;

namespace Benchpilot.Core.Tests;

public class ProfileTests
{
    [Fact]
    public void DefaultSimulator_exposes_target_resource_bindings()
    {
        var profile = ProfileLoader.DefaultSimulator();

        Assert.Equal("demo", profile.DefaultTarget);
        Assert.Equal("simulator", ProfileLoader.ResolveResource(profile, "power").Resource.Driver);
        Assert.Equal("simulator", ProfileLoader.ResolveResource(profile, "serial").Resource.Driver);
        Assert.Equal("simulator", ProfileLoader.ResolveResource(profile, "flash").Resource.Driver);
    }

    [Fact]
    public void Legacy_profile_is_normalized_without_breaking_P0()
    {
        const string json = """
        {
          "driver": "simulator",
          "board": { "name": "Legacy ECU", "mcu": "legacy-mcu" },
          "power": { "voltage": 12, "settleMs": 100 },
          "serial": { "port": "SIM0", "baud": 115200 },
          "flash": { "firmware": "build/app.elf" }
        }
        """;

        var profile = ProfileLoader.LoadJson(json);

        Assert.Equal("default", profile.DefaultTarget);
        Assert.Single(profile.Resources);
        Assert.Single(profile.Targets);
        Assert.Equal("simulator", ProfileLoader.ResolveResource(profile, "flash").Resource.Driver);
        Assert.Equal("legacy-mcu", ProfileLoader.ResolveTarget(profile).Mcu);
    }

    [Fact]
    public void Multi_resource_target_resolves_each_capability_independently()
    {
        const string json = """
        {
          "schemaVersion": 1,
          "name": "Radar bench",
          "defaultTarget": "radar",
          "resources": {
            "psu.main": {
              "driver": "scpi",
              "capabilities": ["power"]
            },
            "probe.radar": {
              "driver": "jlink",
              "capabilities": ["flash", "debug"]
            },
            "uart.radar": {
              "driver": "system-serial",
              "capabilities": ["serial"]
            },
            "can.vehicle": {
              "driver": "pcan",
              "capabilities": ["can"]
            }
          },
          "targets": {
            "radar": {
              "name": "Front Radar",
              "mcu": "TC397",
              "bindings": {
                "power": "psu.main",
                "flash": "probe.radar",
                "serial": "uart.radar",
                "can": "can.vehicle"
              }
            }
          }
        }
        """;

        var profile = ProfileLoader.LoadJson(json);

        Assert.Equal("scpi", ProfileLoader.ResolveResource(profile, "power").Resource.Driver);
        Assert.Equal("jlink", ProfileLoader.ResolveResource(profile, "flash").Resource.Driver);
        Assert.Equal("system-serial", ProfileLoader.ResolveResource(profile, "serial").Resource.Driver);
        Assert.Equal("pcan", ProfileLoader.ResolveResource(profile, "can").Resource.Driver);
    }

    [Fact]
    public void Invalid_binding_is_rejected_at_load_time()
    {
        const string json = """
        {
          "schemaVersion": 1,
          "defaultTarget": "ecu",
          "resources": {
            "uart": {
              "driver": "system-serial",
              "capabilities": ["serial"]
            }
          },
          "targets": {
            "ecu": {
              "bindings": {
                "flash": "uart"
              }
            }
          }
        }
        """;

        var ex = Assert.Throws<InvalidOperationException>(() => ProfileLoader.LoadJson(json));
        Assert.Contains("does not advertise", ex.Message);
    }

    [Theory]
    [InlineData("maxVoltage", 0)]
    [InlineData("maxVoltage", -1)]
    [InlineData("maxCurrentMa", 0)]
    [InlineData("maxCurrentMa", -10)]
    public void Non_positive_safety_limits_are_rejected_at_load_time(string key, double value)
    {
        var json = $$"""
        {
          "schemaVersion": 1,
          "resources": {
            "sim": {
              "driver": "simulator",
              "capabilities": ["power"]
            }
          },
          "targets": {
            "ecu": {
              "bindings": {
                "power": "sim"
              }
            }
          },
          "safety": {
            "{{key}}": {{value}}
          }
        }
        """;

        var ex = Assert.Throws<InvalidOperationException>(() => ProfileLoader.LoadJson(json));
        Assert.Contains(key, ex.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("greater than zero", ex.Message, StringComparison.OrdinalIgnoreCase);
    }
}
