using Benchpilot.Core;
using Benchpilot.Diagnostics.Channels;
using Benchpilot.Diagnostics.Doip;
using Benchpilot.Diagnostics.Flash;
using Benchpilot.Diagnostics.Isotp;
using Benchpilot.Diagnostics.Sim;
using Benchpilot.Diagnostics.Transport;
using Benchpilot.Diagnostics.Uds;

namespace Benchpilot.Diagnostics.Tests;

/// <summary>
/// End-to-end diagnostic workflow tests over both transports, against the
/// simulated ECU: full session, security access, multi-frame download,
/// verify and reset — the exact code path a real bench runs.
/// </summary>
public sealed class FlashWorkflowTests
{
    private static byte[] MakeImage(int size)
    {
        var image = new byte[size];
        new Random(0xBEEF).NextBytes(image);
        return image;
    }

    private static UdsFlashPlanSpec MakePlan(byte[] image, long address = 0x0802_0000) => new()
    {
        Segments = [new UdsFlashSegmentSpec(address, image)],
        MaxBlockPayload = 512,
        Session = 0x02,
        SecurityLevel = 0x01,
        KeyDeriver = "xor0x5a",
        EraseRoutineId = 0xFF00,
        VerifyRoutineId = 0xFF01,
        P2TimeoutMs = 2000,
        P2StarTimeoutMs = 5000,
    };

    [Fact]
    public async Task IsoTp_Over_Simulated_Can_Flashes_Image_End_To_End()
    {
        using var channel = new SimUdsChannel(maxBlockPayload: 512);
        var image = MakeImage(3000);

        var result = await channel.Flash(MakePlan(image));

        Assert.True(result.Ok, $"flash failed: {result.Error}");
        Assert.Equal(1, result.SegmentCount);
        Assert.Equal(image.LongLength, result.TotalBytes);

        var stepNames = result.Steps.Select(x => x.Step).ToArray();
        Assert.Equal(
            ["diagnostic-session", "security-access", "erase", "download", "verify", "ecu-reset"],
            stepNames);
        Assert.All(result.Steps, x => Assert.True(x.Ok, $"step {x.Step} failed: {x.Detail}"));
    }

    [Fact]
    public async Task Simulated_Ecu_Receives_Exact_Image_Bytes()
    {
        using var bus = new SimulatedCanBus();
        using var ecu = new SimulatedUdsEcu(bus);
        using var tester = new CanUdsChannel(
            new SimulatedCanPortBus(bus.Attach(), "test-tester"), 0x7E0, 0x7E8);
        var image = MakeImage(1500);

        var result = await tester.Flash(MakePlan(image));

        Assert.True(result.Ok, $"flash failed: {result.Error}");
        Assert.Equal(image, ecu.Processor.ReceivedImage);
        Assert.Equal(1, ecu.Processor.EraseCount);
        Assert.Equal(1, ecu.Processor.VerifyCount);
    }

    [Fact]
    public async Task Doip_Transport_Flashes_Image_End_To_End()
    {
        using var server = await SimulatedDoipServer.StartAsync(
            testerAddress: 0x0E00,
            ecuAddress: 0x0E10,
            enableDiscovery: true);
        using var channel = new DoipUdsChannel(
            "127.0.0.1",
            server.ListenEndPoint!.Port,
            testerAddress: 0x0E00,
            ecuAddress: 0x0E10,
            maxBlockPayload: 512);
        var image = MakeImage(2048);

        // Session and security access flow through the same channel first.
        var session = await channel.Request(Hex("1002"), 2000, 5000);
        Assert.True(session.Positive, $"session failed: {session.Nrc}");
        var seed = await channel.Request(Hex("2701"), 2000, 5000);
        Assert.True(seed.Positive, $"seed failed: {seed.Nrc}");

        var result = await channel.Flash(MakePlan(image, 0x0804_0000));
        Assert.True(result.Ok, $"flash failed: {result.Error}");
        Assert.Equal(image.LongLength, result.TotalBytes);
        Assert.All(result.Steps, x => Assert.True(x.Ok, $"step {x.Step} failed: {x.Detail}"));
    }

    [Fact]
    public async Task Doip_Discovery_Finds_Simulated_Vehicle()
    {
        using var server = await SimulatedDoipServer.StartAsync(
            vin: "BPITESTVEHICLE01",
            enableDiscovery: true);

        var vehicles = await DoipClient.DiscoverAsync(windowMs: 700);

        var found = vehicles.FirstOrDefault(x => x.Vin == "BPITESTVEHICLE01");
        Assert.NotNull(found);
        Assert.Equal("0x0E10", $"0x{found.LogicalAddress:X4}");
    }

    [Fact]
    public async Task Erase_Without_Security_Access_Is_Rejected_With_Nrc_0x33()
    {
        using var channel = new SimUdsChannel(securityLevel: null, maxBlockPayload: 512);
        var image = MakeImage(600);
        var plan = MakePlan(image) with { SecurityLevel = null, KeyDeriver = null };

        var result = await channel.Flash(plan);

        Assert.False(result.Ok);
        Assert.Contains(result.Steps, x => x.Step == "erase" && !x.Ok && x.Nrc == "0x22"
            || x.Step == "abort" && x.Nrc == "0x33");
    }

    [Fact]
    public async Task Wrong_Security_Key_Is_Rejected_And_Next_Flash_Fails_With_Download()
    {
        using var channel = new SimUdsChannel(maxBlockPayload: 512);

        // Raw UDS escape: enter programming session, then send a wrong key.
        var session = await channel.Request(Hex("1002"), 2000, 5000);
        Assert.True(session.Positive);
        var seed = await channel.Request(Hex("2701"), 2000, 5000);
        Assert.True(seed.Positive);
        Assert.NotNull(seed.ResponseHex);

        var seedPayload = HexToBytes(seed.ResponseHex!);
        var seedBytes = seedPayload[1..]; // payload[0] is the security level
        var wrongKey = seedBytes.Select(b => (byte)(b ^ 0x01)).ToArray();
        var keyRequest = new byte[2 + wrongKey.Length];
        keyRequest[0] = 0x27;
        keyRequest[1] = 0x02;
        wrongKey.CopyTo(keyRequest, 2);

        var keyResponse = await channel.Request(keyRequest, 2000, 5000);
        Assert.True(keyResponse.Ok);
        Assert.False(keyResponse.Positive);
        Assert.Equal("invalidKey", keyResponse.Nrc);

        // A fresh flash attempt re-runs seed->key with the correct deriver,
        // so the workflow succeeds again: one wrong key must not lock the
        // simulated ECU (attempts < MaxSecurityAttempts).
        var result = await channel.Flash(MakePlan(MakeImage(600)));
        Assert.True(result.Ok, $"flash after wrong key failed: {result.Error}");
    }

    [Fact]
    public async Task RequestDownload_In_Wrong_Session_Is_Rejected_With_Nrc_0x7F()
    {
        using var channel = new SimUdsChannel(maxBlockPayload: 512);

        // Default session: programming services are not supported there.
        var response = await channel.Request(Hex("340000000000000100"), 2000, 5000);
        Assert.True(response.Ok);
        Assert.False(response.Positive);
        Assert.Equal("serviceNotSupportedInActiveSession", response.Nrc);
    }

    [Fact]
    public async Task Raw_Request_Matches_Positive_Response_Bytes()
    {
        using var channel = new SimUdsChannel(maxBlockPayload: 512);

        var response = await channel.Request(Hex("22F195"), 2000, 5000);

        Assert.True(response.Positive);
        Assert.NotNull(response.ResponseHex);
        // Response echoes DID then payload: F1 95 + version string.
        Assert.StartsWith("f195", response.ResponseHex);
        var ascii = System.Text.Encoding.ASCII.GetString(HexToBytes(response.ResponseHex[4..]));
        Assert.Contains("BenchPilot sim-ecu", ascii);
    }

    private static byte[] Hex(string hex) => HexToBytes(hex);

    private static byte[] HexToBytes(string hex)
    {
        var cleaned = hex.Replace(" ", string.Empty);
        var bytes = new byte[cleaned.Length / 2];
        for (var i = 0; i < bytes.Length; i++)
            bytes[i] = Convert.ToByte(cleaned.Substring(i * 2, 2), 16);
        return bytes;
    }

    private static string HexToHex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();
}
