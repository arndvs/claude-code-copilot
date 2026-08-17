import path from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import { claudeCode, Output } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { runWithExtraction } from "../lib/run-with-extraction.js";
import { RepoHygieneOutput } from "../schemas/repo-hygiene-output.js";
import { loadConfig } from "../lib/config.js";
import { resolvePrompt, configPromptArgs, filterPromptArgs } from "../lib/resolve-prompt.js";
import { resolveDefaultExtractionsDir, resolveDefaultTemplatesDir } from "../lib/default-template-paths.js";
import { shFile } from "../lib/shell-helpers.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultTemplatesDir = resolveDefaultTemplatesDir({ workflowDir: __dirname });
const defaultExtractionsDir = resolveDefaultExtractionsDir({ workflowDir: __dirname });

export type RepoHygieneResult = RepoHygieneOutput;

/**
 * Check whether a repo-hygiene task is already open. The loop must never open
 * a second issue while one is pending — a backed-up queue means tasks are too
 * big, and the fix is smaller tasks, not more of them.
 */
export function hasOpenHygieneIssue(repoDir: string, label = "repo-hygiene"): boolean {
  const output = shFile(
    "gh",
    ["issue", "list", "--label", label, "--state", "open", "--json", "number", "--jq", "length"],
    repoDir
  );
  const count = Number(output.trim());
  return Number.isFinite(count) && count > 0;
}

export async function runRepoHygiene(opts: {
  repoDir: string;
  model?: string;
  templatesDir?: string;
  extractionsDir?: string;
  dryRun?: boolean;
}): Promise<RepoHygieneResult> {
  const config = await loadConfig({ cwd: opts.repoDir });
  const model = opts.model ?? config.model;
  const templatesDir = opts.templatesDir ?? defaultTemplatesDir;
  const extractionsDir = opts.extractionsDir ?? defaultExtractionsDir;

  // Open-issue guard: skip the agent entirely when a task is already pending.
  if (hasOpenHygieneIssue(opts.repoDir)) {
    console.log("[repo-hygiene] A repo-hygiene task is already open — skipping proposal.");
    return { status: "skipped", reason: "a repo-hygiene task is already open" };
  }

  const promptFile = await resolvePrompt({ name: "repo-hygiene", config, repoDir: opts.repoDir, templatesDir });
  const extractionPrompt = readFileSync(path.join(extractionsDir, "repo-hygiene.md"), "utf8");

  const result = await runWithExtraction({
    name: `repo-hygiene-${new Date().toISOString().slice(0, 10)}`,
    agent: claudeCode(model),
    sandbox: noSandbox(),
    cwd: opts.repoDir,
    promptFile,
    promptArgs: filterPromptArgs(promptFile, {
      ...configPromptArgs(config),
      DRY_RUN: opts.dryRun ? "true" : "false",
    }),
    output: Output.object({ tag: "output", schema: RepoHygieneOutput }),
    extractionPrompt,
    logging: { type: "stdout" },
  });

  if (result.output.status === "proposed") {
    console.log(`[repo-hygiene] Proposed P${result.output.phase} (${result.output.stack}): ${result.output.title}`);
    console.log(`[repo-hygiene] Candidates considered: ${result.output.candidatesConsidered.length}`);
  } else {
    console.log(`[repo-hygiene] Skipped: ${result.output.reason}`);
  }

  return result.output;
}
