// Role: process entrypoint that delegates the public CLI protocol to CliApplication.
// Inputs/outputs: forwards the original argv unchanged and returns the application exit code.
// Boundary: contains no command routing, domain policy, JSON handling, or HTS/FlaUI execution.
return HtsQa.Cli.CliApplication.Run(args);
