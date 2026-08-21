/**
 * 역할: 대용량 generated outputs와 사용자 홈 절대 경로가 Git 추적에 다시 들어오는 것을 차단한다.
 * 경계: Git index와 텍스트 파일을 읽기만 하며 로컬 ignored 증거 파일은 삭제하지 않는다.
 */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = path.resolve(import.meta.dirname, "..", "..");
const git = (...args) => {
  const result = spawnSync("git", ["-c", `safe.directory=${root.replaceAll("\\", "/")}`, ...args], { cwd: root, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim().split(/\r?\n/).filter(Boolean);
};
let assertions = 0;
const check = (actual, expected, message) => { assert.deepEqual(actual, expected, message); assertions += 1; };

const tracked = git("ls-files");
const trackedOutputs = tracked.filter((file) => file.startsWith("outputs/"));
check(trackedOutputs, [
  "outputs/0101_automation/0101.dataset.json",
  "outputs/0101_automation/scenario-approval.json",
], "only the minimal Dataset and manual approval evidence may remain tracked under outputs");

for (const file of trackedOutputs) {
  const stat = await fs.stat(path.join(root, file));
  assert.ok(stat.size < 256 * 1024, `${file} is too large for a tracked output fixture`);
  assertions += 1;
}

const textExtensions = new Set([".cs", ".ps1", ".mjs", ".js", ".json", ".md", ".yml", ".yaml", ".txt", ".cmd"]);
const localPathPattern = /[A-Za-z]:[\\/]Users[\\/][^\\/\s"']+|[\\/]Users[\\/][^\\/\s"']+/i;
const violations = [];
for (const file of tracked) {
  if (file === "tests/reporting/repository-hygiene.tests.mjs") continue;
  if (!textExtensions.has(path.extname(file)) && path.basename(file) !== ".gitignore") continue;
  const text = await fs.readFile(path.join(root, file), "utf8");
  if (localPathPattern.test(text)) violations.push(file);
}
check(violations, [], "tracked text must not contain user-home absolute paths");

const importer = await fs.readFile(path.join(root, "targets", "1q-hts", "0101", "tools", "import-testcases.mjs"), "utf8");
assert.match(importer, /sourceWorkbook:\s*path\.basename\(workbookPath\)/, "import summary must retain only the workbook basename");
assert.doesNotMatch(importer, /sourceWorkbook:\s*workbookPath\b/, "import summary must not emit an absolute workbook path");
assertions += 2;

console.log(`REPOSITORY_HYGIENE_TESTS=PASS assertions=${assertions} trackedOutputs=${trackedOutputs.length}`);
