import path from "node:path";
import { fileURLToPath } from "node:url";
import { run, claudeCode } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { loadConfig } from "../lib/config.js";
import { resolvePrompt, configPromptArgs } from "../lib/resolve-prompt.js";
import { resolveDefaultTemplatesDir } from "../lib/default-template-paths.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultTemplatesDir = resolveDefaultTemplatesDir({ workflowDir: __dirname });

export interface ImplementPrdResult {
  commitCount: number;
}

export async function runImplementPrd(opts: {
  prdNumber: string;
  prdTitle: string;
  subIssueNumber: string;
  subIssueTitle: string;
  branch: string;
  repoDir: string;
  model?: string;
  templatesDir?: string;
}): Promise<ImplementPrdResult> {
  const config = await loadConfig({ cwd: opts.repoDir });
  const model = opts.model ?? config.model;
  const templatesDir = opts.templatesDir ?? defaultTemplatesDir;

  console.log(`[implement-prd] PRD #${opts.prdNumber} — ${opts.prdTitle}`);
  console.log(`[implement-prd] Sub-issue #${opts.subIssueNumber} — ${opts.subIssueTitle}`);
  console.log(`[implement-prd] Branch: ${opts.branch}`);

  const promptFile = await resolvePrompt({ name: "implement-prd", config, repoDir: opts.repoDir, templatesDir });

  const result = await run({
    name: `implement-prd-#${opts.prdNumber}-sub-#${opts.subIssueNumber}`,
    agent: claudeCode(model),
    sandbox: noSandbox(),
    cwd: opts.repoDir,
    promptFile,
    promptArgs: {
      ...configPromptArgs(config),
      PRD_NUMBER: opts.prdNumber,
      PRD_TITLE: opts.prdTitle,
      SUB_ISSUE_NUMBER: opts.subIssueNumber,
      SUB_ISSUE_TITLE: opts.subIssueTitle,
      BRANCH: opts.branch,
    },
    logging: { type: "stdout" },
  });

  // Zero commits is a valid outcome — the sub-issue's work may already have
  // been completed by a previous iteration.
  console.log(`[implement-prd] Finished sub-issue #${opts.subIssueNumber}. Commits this run: ${result.commits.length}`);

  return { commitCount: result.commits.length };
}
