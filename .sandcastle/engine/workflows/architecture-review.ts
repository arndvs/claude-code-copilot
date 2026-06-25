import path from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import { claudeCode, Output } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { runWithExtraction } from "../lib/run-with-extraction.js";
import { ArchitectureReviewOutput } from "../schemas/architecture-review-output.js";
import { loadConfig } from "../lib/config.js";
import { resolvePrompt, configPromptArgs } from "../lib/resolve-prompt.js";
import { resolveDefaultExtractionsDir, resolveDefaultTemplatesDir } from "../lib/default-template-paths.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultTemplatesDir = resolveDefaultTemplatesDir({ workflowDir: __dirname });
const defaultExtractionsDir = resolveDefaultExtractionsDir({ workflowDir: __dirname });

export type ArchitectureReviewResult = ArchitectureReviewOutput;

export async function runArchitectureReview(opts: {
  repoDir: string;
  model?: string;
  templatesDir?: string;
  extractionsDir?: string;
}): Promise<ArchitectureReviewResult> {
  const config = await loadConfig({ cwd: opts.repoDir });
  const model = opts.model ?? config.model;
  const templatesDir = opts.templatesDir ?? defaultTemplatesDir;
  const extractionsDir = opts.extractionsDir ?? defaultExtractionsDir;

  const promptFile = await resolvePrompt({ name: "architecture-review", config, repoDir: opts.repoDir, templatesDir });
  const extractionPrompt = readFileSync(path.join(extractionsDir, "architecture-review.md"), "utf8");

  const result = await runWithExtraction({
    name: `architecture-review-${new Date().toISOString().slice(0, 10)}`,
    agent: claudeCode(model),
    sandbox: noSandbox(),
    cwd: opts.repoDir,
    promptFile,
    promptArgs: configPromptArgs(config),
    output: Output.object({ tag: "output", schema: ArchitectureReviewOutput }),
    extractionPrompt,
    logging: { type: "stdout" },
  });

  if (result.output.status === "proposed") {
    console.log(`[architecture-review] Proposed PRD: ${result.output.title}`);
    console.log(`[architecture-review] Candidates considered: ${result.output.candidatesConsidered.length}`);
  } else {
    console.log(`[architecture-review] Skipped: ${result.output.reason}`);
  }

  return result.output;
}
