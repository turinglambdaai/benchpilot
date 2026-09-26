using Xunit;

// E2E tests manage real daemons and share the per-user token file; keep the
// whole assembly serialized so environments never race each other.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Benchpilot.E2E.Tests;

/// <summary>
/// One daemon shared by the command-surface test classes. xunit runs the
/// classes in one collection sequentially, so bench state (power on/off,
/// history) is deterministic inside the collection.
/// </summary>
public sealed class SharedDaemonFixture : IAsyncLifetime
{
    public E2EEnvironment Environment { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        Environment = E2EEnvironment.Create();
        await Environment.StartDaemonAsync().ConfigureAwait(false);
    }

    public Task DisposeAsync()
    {
        Environment.Dispose();
        return Task.CompletedTask;
    }
}

[CollectionDefinition("shared-daemon")]
public sealed class SharedDaemonCollection : ICollectionFixture<SharedDaemonFixture>;
