using System.Text;

namespace Benchpilot.RuntimeHost;

/// <summary>
/// Minimal file logger used when the daemon is started detached (autostart):
/// no console is attached for long, so durable logs must live on disk.
/// Deliberately dependency-free; volumes here are small (lifecycle events).
/// </summary>
internal sealed class SimpleFileLoggerProvider : ILoggerProvider
{
    private readonly string _path;

    public SimpleFileLoggerProvider(string path)
    {
        _path = path;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    }

    public ILogger CreateLogger(string categoryName) => new SimpleFileLogger(_path, categoryName);

    public void Dispose()
    {
    }

    private sealed class SimpleFileLogger(string path, string category) : ILogger
    {
        private static readonly object WriteLock = new();

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel))
                return;

            var builder = new StringBuilder(256);
            builder.Append(DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"));
            builder.Append(' ').Append(logLevel).Append(' ').Append(category).Append(": ");
            builder.AppendLine(formatter(state, exception));
            if (exception is not null)
                builder.AppendLine(exception.ToString());

            lock (WriteLock)
            {
                try
                {
                    File.AppendAllText(path, builder.ToString());
                }
                catch (IOException)
                {
                    // Logging must never take the bench runtime down.
                }
            }
        }
    }
}
