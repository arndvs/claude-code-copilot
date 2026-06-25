import path from "node:path";
import { fileURLToPath } from "node:url";
import { claudeCode, Output } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { runWithRetry } from "../lib/run-with-retry.js";
import { WritePrOutput } from "../schemas/write-pr-output.js";
import { loadConfig } from "../lib/config.js";
import { resolvePrompt, configPromptArgs } from "../lib/resolve-prompt.js";
import { resolveDefaultTemplatesDir } from "../lib/default-template-paths.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultTemplatesDir = resolveDefaultTemplatesDir({ workflowDir: __dirname });

export interface WritePrResult {
  prTitle: string;
  prDescription: string;
}

/**
 * Write a PR title + description for an issue branch or a PRD umbrella PR.
 *
 * Issue mode  (`issueNumber` + `branch`):
 *   reads the issue + branch diff, writes a summary PR.
 *
 * PRD mode  (`prdNumber` + `prdTitle`):
 *   reads the PRD + sub-issues, writes a PR covering the whole PRD.
 *
 * Both modes return `{ prTitle, prDescription }`.
 */
export async function runWritePr(opts: {
  /** Issue number — issue mode. */
  issueNumber?: string;
  /** Issue title — issue mode. */
  issueTitle?: string;
  /** Branch that carries the implementation — issue mode. */
  branch?: string;
  /** PRD number — PRD mode. */
  prdNumber?: string;
  /** PRD title — PRD mode. */
  prdTitle?: string;
  repoDir: string;
  model?: string;
  templatesDir?: string;
}): Promise<WritePrResult> {
  const config = await loadConfig({ cwd: opts.repoDir });
  const model = opts.model ?? config.model;
  const templatesDir = opts.templatesDir ?? defaultTemplatesDir;

  const isPrd = Boolean(opts.prdNumber);

  if (isPrd) {
    if (!opts.prdNumber || !opts.prdTitle) {
      throw new Error("PRD mode requires --prd-number and --prd-title");
    }
  } else {
    if (!opts.issueNumber || !opts.issueTitle || !opts.branch) {
      throw new Error("Issue mode requires --issue, --issue-title, and --branch");
    }
  }

  const promptName = isPrd ? "write-prd-pr" : "write-pr";
  const promptFile = await resolvePrompt({ name: promptName, config, repoDir: opts.repoDir, templatesDir });

  const promptArgs: Record<string, string> = {
    ...configPromptArgs(config),
    ...(isPrd
      ? { PRD_NUMBER: opts.prdNumber!, PRD_TITLE: opts.prdTitle! }
      : { ISSUE_NUMBER: opts.issueNumber!, ISSUE_TITLE: opts.issueTitle!, BRANCH: opts.branch!, BASE_BRANCH: config.baseBranch }),
  };

  const runName = isPrd
    ? `write-prd-pr-#${opts.prdNumber}`
    : `write-pr-#${opts.issueNumber}`;

  console.log(`[${promptName}] Drafting PR metadata...`);

  const result = await runWithRetry({
    name: runName,
    agent: claudeCode(model),
    sandbox: noSandbox(),
    cwd: opts.repoDir,
    promptFile,
    promptArgs,
    output: Output.object({ tag: "output", schema: WritePrOutput }),
    logging: { type: "stdout" },
  });

  console.log(`[${promptName}] Title: ${result.output.prTitle}`);

  return {
    prTitle: result.output.prTitle,
    prDescription: result.output.prDescription,
  };
}
