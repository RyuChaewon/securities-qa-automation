// Role: owns immutable repository-root and path-normalization context shared by CLI handlers.
// Inputs/outputs: resolves caller paths against the discovered repository root without changing files.
// Boundary: contains no command routing, business validation, or UI execution policy.
namespace HtsQa.Cli;

internal sealed class CliCommandContext
{
    private CliCommandContext(string repositoryRoot) => RepositoryRoot = repositoryRoot;

    internal string RepositoryRoot { get; }

    internal static CliCommandContext Create() => new(FindRoot());

    internal string Full(string path) => Path.IsPathRooted(path)
        ? Path.GetFullPath(path)
        : Path.GetFullPath(Path.Combine(RepositoryRoot, path));

    private static string FindRoot()
    {
        var dir = new DirectoryInfo(Environment.CurrentDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "HtsQaPoc.sln"))) return dir.FullName;
            dir = dir.Parent;
        }
        return Environment.CurrentDirectory;
    }
}
