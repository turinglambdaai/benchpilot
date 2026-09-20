using Benchpilot.Drivers.JLink;

namespace Benchpilot.Core.Tests;

public class JLinkProbeDiscoveryTests
{
    private const string Sample = """
        SEGGER J-Link Commander V8.72a
        J-Link[0]: Connection: USB, Serial number: 853000808, ProductName: J-Link ULTRA+
        J-Link[1]: Connection: USB, Serial number: 59410000, ProductName: J-Link PLUS, Nickname: Bench-B
        J-Link[2]: Connection: IP, Serial number: 123456789, ProductName: J-Link PRO
        J-Link>
        """;

    [Fact]
    public void Parser_extracts_probe_identity_and_optional_nickname()
    {
        var probes = JLinkProbeDiscovery.Parse(Sample);

        Assert.Equal(3, probes.Count);
        Assert.Equal("853000808", probes[0].SerialNumber);
        Assert.Equal("J-Link ULTRA+", probes[0].ProductName);
        Assert.Null(probes[0].Nickname);
        Assert.Equal("Bench-B", probes[1].Nickname);
        Assert.Equal("IP", probes[2].Connection);
    }

    [Fact]
    public void Evaluation_fails_when_no_usb_probe_is_visible()
    {
        var result = JLinkProbeDiscovery.Evaluate(
            [new JLinkProbeInfo("IP", "123", "J-Link PRO")],
            null);

        Assert.False(result.Ok);
        Assert.Contains("No USB", result.Summary);
        Assert.Equal("0", result.Details?["usbProbeCount"]);
    }

    [Fact]
    public void Evaluation_accepts_one_usb_probe_without_configured_serial()
    {
        var probes = JLinkProbeDiscovery.Parse(
            "J-Link[0]: Connection: USB, Serial number: 853000808, ProductName: J-Link ULTRA+");

        var result = JLinkProbeDiscovery.Evaluate(probes, null);

        Assert.True(result.Ok, result.Error);
        Assert.Equal("853000808", result.Details?["selectedSerialNumber"]);
        Assert.Equal("J-Link ULTRA+", result.Details?["selectedProduct"]);
        Assert.Equal("false", result.Details?["targetConnectivityChecked"]);
    }

    [Fact]
    public void Evaluation_requires_serial_number_when_multiple_usb_probes_are_visible()
    {
        var probes = JLinkProbeDiscovery.Parse(Sample);

        var result = JLinkProbeDiscovery.Evaluate(probes, null);

        Assert.False(result.Ok);
        Assert.Contains("2 USB", result.Summary);
        Assert.Contains("serialNumber", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Evaluation_accepts_exact_configured_serial_among_multiple_probes()
    {
        var probes = JLinkProbeDiscovery.Parse(Sample);

        var result = JLinkProbeDiscovery.Evaluate(probes, "59410000");

        Assert.True(result.Ok, result.Error);
        Assert.Equal("59410000", result.Details?["selectedSerialNumber"]);
        Assert.Equal("J-Link PLUS", result.Details?["selectedProduct"]);
        Assert.Equal("Bench-B", result.Details?["selectedNickname"]);
    }

    [Fact]
    public void Evaluation_reports_configured_serial_that_is_not_connected()
    {
        var probes = JLinkProbeDiscovery.Parse(Sample);

        var result = JLinkProbeDiscovery.Evaluate(probes, "999999999");

        Assert.False(result.Ok);
        Assert.Contains("999999999", result.Summary);
        Assert.Contains("853000808", result.Error);
        Assert.Contains("59410000", result.Error);
    }
}
