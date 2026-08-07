import path from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import { claudeCode, Output } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { runWithExtraction } from "../lib/run-with-extraction.js";
import { KeepTestsTightOutput } from "../schemas/keep-tests-tight-output.js";
import { loadConfig } from "../lib/config.js";
import { resolvePrompt, configPromptArgs, filterPromptArgs } from "../lib/resolve-prompt.js";
import { resolveDefaultExtractionsDir, resolveDefaultTemplatesDir } from "../lib/default-template-paths.js";
import { shFile } from "../lib/shell-helpers.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultTemplatesDir = resolveDefaultTemplatesDir({ workflowDir: __dirname });
const defaultExtractionsDir = resolveDefaultExtractionsDir({ workflowDir: __dirname });

export type KeepTestsTightResult = KeepTestsTightOutput;

/**
 * Check whether the repo had any commits in the last 24 hours.
 * Returns true when there is real work to review, false when the gate should
 * short-circuit the run (no token spend).
 */
export function hasRecentCommits(repoDir: string, since = "24 hours"): boolean {
  const output = shFile("git", ["log", `--since=${since}`, "--oneline"], repoDir);
  return output.trim().length > 0;
}

export async function runKeepTestsTight(opts: {
  repoDir: string;
  branch: string;
  model?: string;
  templatesDir?: string;
  extractionsDir?: string;
}): Promise<KeepTestsTightResult> {
  const config = await loadConfig({ cwd: opts.repoDir });
  const model = opts.model ?? config.model;
  const templatesDir = opts.templatesDir ?? defaultTemplatesDir;
  const extractionsDir = opts.extractionsDir ?? defaultExtractionsDir;

  // 24h gate: skip the agent entirely when nothing changed in the last day.
  if (!hasRecentCommits(opts.repoDir)) {
    console.log("[keep-tests-tight] No commits in the last 24 hours — skipping agent.");
    return { status: "no-changes", reason: "no commits in last 24 hours" };
  }

  const promptFile = await resolvePrompt({ name: "keep-tests-tight", config, repoDir: opts.repoDir, templatesDir });
  const extractionPrompt = readFileSync(path.join(extractionsDir, "keep-tests-tight.md"), "utf8");

  const result = await runWithExtraction({
    name: `keep-tests-tight-${new Date().toISOString().slice(0, 10)}`,
    agent: claudeCode(model),
    sandbox: noSandbox(),
    cwd: opts.repoDir,
    promptFile,
    promptArgs: filterPromptArgs(promptFile, {
      ...configPromptArgs(config),
      BRANCH: opts.branch,
    }),
    output: Output.object({ tag: "output", schema: KeepTestsTightOutput }),
    extractionPrompt,
    logging: { type: "stdout" },
  });

  if (result.output.status === "changed") {
    console.log(`[keep-tests-tight] Changed: removed ${result.output.removed.length}, consolidated ${result.output.consolidated.length}, kept ${result.output.kept.length}`);
  } else {
    console.log(`[keep-tests-tight] No changes: ${result.output.reason}`);
  }

  return result.output;
}
