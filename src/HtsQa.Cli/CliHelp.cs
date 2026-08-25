// Role: owns the stable public CLI help text and command usage list.
// Inputs/outputs: writes the existing help protocol to stdout and returns exit code zero.
// Boundary: contains no routing, argument parsing, business policy, or UI execution.
namespace HtsQa.Cli;

internal static class CliHelp
{
    internal static int Write()
    {
        Console.WriteLine("""
        HtsQa.Cli 명령:
          validate-rule-dataset --file PATH
          expand-rule-cases --file PATH [--out PATH]
          compile-test-pack --dataset PATH [--combination-policy Cartesian|Pairwise|PerControl] [--max-cases N] [--approval PATH] [--out PATH]
          create-test-pack-approval --test-pack PATH [--out PATH]
          validate-test-pack --file PATH [--dataset PATH]
          run-test-pack --file PATH --dry-run [--report-dir PATH]
          run-rule-dataset (지원 종료: compile-test-pack + run-test-pack 사용)
          extract-map-models --screen-dir PATH --screens ID1,ID2 [--installation-root PATH] [--file-pattern PATTERN] [--out PATH]
          generate-rule-scenarios --map PATH --dataset PATH [--control-plan PATH] [--reference-date yyyyMMdd] [--max-options N] [--out PATH]
          create-rule-scenario-approval --file PATH [--out PATH]
          validate-generated-scenarios --file PATH --dataset PATH [--out PATH]
          import-generated-scenarios --file PATH --dataset PATH [--out-dir PATH]
          create-scenario-approval --file PATH [--out PATH]
          compile-scenarios --file PATH --dataset PATH [--approval PATH] [--max-cases N] [--out PATH]
          plan-scenarios --file PATH --dataset PATH [--approval PATH] [--max-cases N] [--report-dir PATH]
          materialize-scenario-bindings --plan PATH --control-plan PATH --runtime-fingerprint HASH --out PATH
          create-control-repository-approval --review PATH [--out PATH]
          apply-control-repository-approval --review PATH --approval PATH [--out PATH]
          validate-control-repository --file PATH
          create-control-repository-review --capture PATH --screen ID --logical-name NAME --state-context CONTEXT --risk-class CLASS --allowed-actions A,B --anchor ID [--target-profile-id ID] [--business-role ROLE] [--transactional-role ROLE] [--map ID] [--source REF] [--evidence REF1,REF2] [--out PATH]
          resolve-control-repository --repository PATH --request PATH [--out PATH]
          create-calibration-session --captures PATH1,PATH2 --session-id ID --target-profile-id ID --repository-id ID --screen ID --state-context CONTEXT --reviewer NAME [--map ID] [--out PATH]
          validate-calibration-session --file PATH [--out PATH]
          create-execution-authorization-approval --request PATH [--out PATH]
          apply-execution-authorization-approval --request PATH --approval PATH [--out PATH]
          check-execution-authorization --request PATH --checked-at ISO8601 [--out PATH]
          create-calibration-review --session PATH --logical-name NAME --risk-class CLASS --allowed-actions A,B --forbidden-actions A,B --source REF --evidence REF1,REF2 [--business-role ROLE] [--transactional-role ROLE] [--anchor ID] [--out PATH]
          register-control-repository-entry --repository PATH --entry PATH --out PATH
          finalize-calibration-session --session PATH --repository PATH --logical-name NAME --out PATH
          validate-order-scenario --input PATH [--out PATH]
          compile-order-scenario --input PATH --out PATH [--compiled-at ISO8601]
          dry-run-order-scenario --plan PATH [--out PATH]
          build-physical-scenario-plan --plan PATH --bindings PATH --out PATH
          evaluate-results --test-pack PATH --observations PATH --output PATH
          analyze-run --run REPORT_DIR

        실제 HTS 실행과 녹화는 scripts/run-target-rule-suite-recorded.ps1을 사용합니다.
        """.Replace("\r\n", "\n").Replace("\n", Environment.NewLine));
        return 0;
    }
}
