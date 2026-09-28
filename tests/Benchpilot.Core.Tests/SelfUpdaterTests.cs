using Benchpilot.Client;

namespace Benchpilot.Core.Tests;

public sealed class SelfUpdaterTests
{
    [Theory]
    [InlineData("0.5.0", "0.5.1", -1)]
    [InlineData("0.5.1", "0.5.0", 1)]
    [InlineData("0.5.0", "0.5.0", 0)]
    [InlineData("v0.10.0", "v0.9.0", 1)]
    [InlineData("1.0.0", "0.99.99", 1)]
    [InlineData("0.5.0", "0.5.0-old", -1)]
    public void Versions_Compare_Numerically(string a, string b, int expectedSign)
    {
        var result = SelfUpdater.CompareVersions(a, b);
        Assert.Equal(expectedSign, Math.Sign(result));
    }

    [Theory]
    [InlineData("win-x64")]
    [InlineData("linux-x64")]
    [InlineData("linux-arm64")]
    [InlineData("osx-arm64")]
    public void Platform_Rid_Is_A_Package_Rid(string expectedOnSomePlatform)
    {
        var rid = SelfUpdater.PlatformRid();
        Assert.Contains(rid, new[]
        {
            "win-x64", "linux-x64", "linux-arm64", "osx-arm64",
        });
    }

    [Fact]
    public void Checksum_Verification_Accepts_Matching_Entry()
    {
        var dir = Directory.CreateTempSubdirectory("bp-checksum-");
        try
        {
            var archive = Path.Combine(dir.FullName, "benchpilot-0.5.1-win-x64.zip");
            File.WriteAllBytes(archive, [1, 2, 3, 4, 5]);
            using (var stream = File.OpenRead(archive))
            {
                var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream)).ToLowerInvariant();
                var sums = Path.Combine(dir.FullName, "SHA256SUMS.txt");
                File.WriteAllLines(sums,
                [
                    $"ffffff  benchpilot-0.5.1-linux-x64.tar.gz",
                    $"{hash}  benchpilot-0.5.1-win-x64.zip",
                ]);
                SelfUpdater.VerifyChecksum(archive, sums, "benchpilot-0.5.1-win-x64.zip");
            }
        }
        finally
        {
            dir.Delete(recursive: true);
        }
    }

    [Fact]
    public void Checksum_Verification_Rejects_Tampered_Archive()
    {
        var dir = Directory.CreateTempSubdirectory("bp-checksum-");
        try
        {
            var archive = Path.Combine(dir.FullName, "benchpilot-0.5.1-win-x64.zip");
            File.WriteAllBytes(archive, [1, 2, 3]);
            var sums = Path.Combine(dir.FullName, "SHA256SUMS.txt");
            File.WriteAllLines(sums,
            [
                $"{new string('0', 64)}  benchpilot-0.5.1-win-x64.zip",
            ]);
            Assert.Throws<InvalidOperationException>(() =>
                SelfUpdater.VerifyChecksum(archive, sums, "benchpilot-0.5.1-win-x64.zip"));
        }
        finally
        {
            dir.Delete(recursive: true);
        }
    }

    [Fact]
    public void Checksum_Verification_Rejects_Missing_Entry()
    {
        var dir = Directory.CreateTempSubdirectory("bp-checksum-");
        try
        {
            var archive = Path.Combine(dir.FullName, "benchpilot-0.5.1-win-x64.zip");
            File.WriteAllBytes(archive, [1]);
            var sums = Path.Combine(dir.FullName, "SHA256SUMS.txt");
            File.WriteAllLines(sums, ["abcdef  something-else.zip"]);
            Assert.Throws<InvalidOperationException>(() =>
                SelfUpdater.VerifyChecksum(archive, sums, "benchpilot-0.5.1-win-x64.zip"));
        }
        finally
        {
            dir.Delete(recursive: true);
        }
    }
}
