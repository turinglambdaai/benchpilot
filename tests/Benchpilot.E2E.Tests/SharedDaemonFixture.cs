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
public sealed class SharedDaemonFixture : IDisposable
{
    public E2EEnvironment Environment { get; }

    public SharedDaemonFixture()
    {
        Environment = E2EEnvironment.Create();
        Environment.StartDaemon();
    }

    public void Dispose() => Environment.Dispose();
}

[CollectionDefinition("shared-daemon")]
public sealed class SharedDaemonCollection : ICollectionFixture<SharedDaemonFixture>;
