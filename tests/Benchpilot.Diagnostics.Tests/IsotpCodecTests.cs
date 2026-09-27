using Benchpilot.Diagnostics.Isotp;

namespace Benchpilot.Diagnostics.Tests;

public sealed class IsotpCodecTests
{
    [Fact]
    public void Single_Frame_Round_Trip_Short_Payload()
    {
        var payload = new byte[] { 0x10, 0x03 };
        var frame = IsotpCodec.EncodeSingle(payload);

        Assert.Equal(8, frame.Length);
        Assert.Equal(0x02, frame[0]);
        Assert.True(IsotpCodec.TryDecode(frame, out var decoded));
        Assert.Equal(IsotpFrameType.Single, decoded.Type);
        Assert.Equal(payload, decoded.Payload.ToArray());
    }

    [Fact]
    public void Single_Frame_Over_Seven_Bytes_Is_Rejected()
    {
        // Classic CAN: payloads above 7 bytes must use first/consecutive.
        Assert.Throws<ArgumentException>(() =>
            IsotpCodec.EncodeSingle(new byte[8]));
    }

    [Fact]
    public void First_Frame_Carries_Length_Prefix()
    {
        var payload = new byte[100];
        var frame = IsotpCodec.EncodeFirstPrefix(payload);

        // 0x1 in the type nibble, total length in the low nibble + byte 1.
        Assert.Equal(IsotpFrameType.First, (IsotpFrameType)(frame[0] >> 4));
        Assert.Equal(100, ((frame[0] & 0x0F) << 8) | frame[1]);
        Assert.True(IsotpCodec.TryDecode(frame, out var decoded));
        Assert.Equal(IsotpFrameType.First, decoded.Type);
        Assert.Equal(6, decoded.Payload.Length);
    }

    [Fact]
    public void First_Frame_Escape_Handles_Large_Lengths()
    {
        var payload = new byte[5000];
        var frame = IsotpCodec.EncodeFirstPrefix(payload);

        Assert.Equal(0x10, frame[0]);
        Assert.Equal(0x00, frame[1]);
        Assert.Equal(5000, (frame[2] << 24) | (frame[3] << 16) | (frame[4] << 8) | frame[5]);
    }

    [Fact]
    public void Consecutive_And_FlowControl_Round_Trip()
    {
        var cf = IsotpCodec.EncodeConsecutive(5, [0xAA, 0xBB]);
        Assert.Equal(0x25, cf[0]);
        Assert.True(IsotpCodec.TryDecode(cf, out var cfDecoded));
        Assert.Equal(IsotpFrameType.Consecutive, cfDecoded.Type);
        Assert.Equal(5, cfDecoded.SequenceNumber);

        var fc = IsotpCodec.EncodeFlowControl(FlowControlStatus.ContinueToSend, 8, 10);
        Assert.True(IsotpCodec.TryDecode(fc, out var fcDecoded));
        Assert.Equal(FlowControlStatus.ContinueToSend, fcDecoded.FlowStatus);
        Assert.Equal((byte)8, fcDecoded.BlockSize);
        Assert.Equal(10, fcDecoded.StMinMs);
    }

    [Fact]
    public void StMin_Encoding_Follows_Iso_Ranges()
    {
        Assert.Equal(0x00, IsotpCodec.EncodeStMin(0));
        Assert.Equal(0x0A, IsotpCodec.EncodeStMin(10));
        Assert.Equal(0x7F, IsotpCodec.EncodeStMin(200));
        Assert.Equal(0xF3, IsotpCodec.EncodeStMin(0.3));
        Assert.Equal(0.3, IsotpCodec.DecodeStMin(0xF3), 3);
        Assert.Equal(0, IsotpCodec.DecodeStMin(0x80));
    }
}
