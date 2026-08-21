/**
 * 역할: report directory 안의 XLSX, preview, inspection log와 상대 증거 파일 경로를 관리한다.
 * 경계: report directory 밖의 읽기·쓰기를 허용하지 않고 JSON canonical source에는 쓰지 않는다.
 */
import fs from "node:fs/promises";
import path from "node:path";

export function createRuleReportOutputManager(reportDirArg, outputFileArg) {
  const reportDir = path.resolve(reportDirArg);
  const outputName = path.basename(String(outputFileArg || "테스트결과.xlsx"));
  if (!outputName.toLowerCase().endsWith(".xlsx")) throw new Error("결과 workbook 출력은 .xlsx 파일이어야 합니다.");

  const insideReportDir = (candidate) => {
    const relative = path.relative(reportDir, candidate);
    return relative && !relative.startsWith("..") && !path.isAbsolute(relative);
  };

  return {
    reportDir,
    outputPath: path.join(reportDir, outputName),
    async readEvidence(relativePath) {
      const value = String(relativePath ?? "").trim();
      if (!value) return null;
      const candidate = path.resolve(reportDir, value);
      if (!insideReportDir(candidate)) return null;
      const extension = path.extname(candidate).toLowerCase();
      const mimeType = extension === ".png" ? "image/png" : ([".jpg", ".jpeg"].includes(extension) ? "image/jpeg" : "");
      if (!mimeType) return null;
      try { return { bytes: await fs.readFile(candidate), mimeType }; }
      catch (error) { if (error?.code === "ENOENT") return null; throw error; }
    },
    async writePreview(sheetName, preview) {
      const safeName = String(sheetName).replace(/[\\/:*?"<>|]/g, "_");
      await fs.writeFile(path.join(reportDir, `미리보기-${safeName}.png`), new Uint8Array(await preview.arrayBuffer()));
    },
    async saveXlsx(output) {
      const outputPath = path.join(reportDir, outputName);
      await output.save(outputPath);
      return outputPath;
    },
    async finalizeInspection(outputPath) {
      try { await fs.rename(`${outputPath}.inspect.ndjson`, path.join(reportDir, "통합문서검사.ndjson")); }
      catch (error) { if (error?.code !== "ENOENT") throw error; }
    },
  };
}
