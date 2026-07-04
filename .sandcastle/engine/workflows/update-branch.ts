import path from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import { Output, claudeCode } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { runWithExtraction } from "../lib/run-with-extraction.js";
import { UpdateBranchOutput } from "../schemas/update-branch-output.js";
import { loadConfig } from "../lib/config.js";
import { resolvePrompt, configPromptArgs } from "../lib/resolve-prompt.js";
import { fail, sh, shFile, shFileInherit } from "../lib/shell-helpers.js";
import { resolveDefaultExtractionsDir, resolveDefaultTemplatesDir } from "../lib/default-template-paths.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultTemplatesDir = resolveDefaultTemplatesDir({ workflowDir: __dirname });
const defaultExtractionsDir = resolveDefaultExtractionsDir({ workflowDir: __dirname });

export interface UpdateBranchResult {
  comment: string;
  shouldPush: boolean;
}

export async function runUpdateBranch(opts: {
  prNumber: string;
  branch: string;
  baseRef: string;
  repoDir: string;
  model?: string;
  templatesDir?: string;
  extractionsDir?: string;
}): Promise<UpdateBranchResult> {
  const config = await loadConfig({ cwd: opts.repoDir });
  const { prNumber, branch, baseRef, repoDir } = opts;
  const model = opts.model ?? config.model;
  const templatesDir = opts.templatesDir ?? defaultTemplatesDir;
  const extractionsDir = opts.extractionsDir ?? defaultExtractionsDir;

  console.log(`[update-branch] PR #${prNumber}, branch ${branch}, base ${baseRef}`);

  shFileInherit("git", ["fetch", "origin", baseRef], repoDir);

  const preMergeSha = shFile("git", ["rev-parse", "HEAD"], repoDir).trim();
  const baseSha = shFile("git", ["rev-parse", `origin/${baseRef}`], repoDir).trim();
  const mergeBase = shFile("git", ["merge-base", "HEAD", `origin/${baseRef}`], repoDir).trim();

  if (mergeBase === baseSha) {
    const comment = `\`agent:update-branch\`: branch is already up to date with \`origin/${baseRef}\`. No merge needed.`;
    console.log("[update-branch] Already up to date — nothing to do.");
    return { comment, shouldPush: false };
  }

  const mergeResult = tryMerge(baseRef, repoDir);

  if (mergeResult.status === "clean") {
    const comment = `\`agent:update-branch\`: merged \`origin/${baseRef}\` (\`${baseSha.slice(0, 7)}\`) into \`${branch}\` cleanly — no conflicts.`;
    console.log("[update-branch] Clean merge — caller should push.");
    return { comment, shouldPush: true };
  }

  console.log(`[update-branch] Merge produced conflicts in ${mergeResult.conflicts.length} file(s) — invoking agent.`);

  const promptFile = await resolvePrompt({ name: "update-branch", config, repoDir, templatesDir });
  const extractionPrompt = readFileSync(
    path.join(extractionsDir, "update-branch.md"),
    "utf8",
  );

  const result = await runWithExtraction({
    name: `update-branch-pr-${prNumber}`,
    agent: claudeCode(model),
    sandbox: noSandbox(),
    cwd: repoDir,
    promptFile,
    promptArgs: {
      ...configPromptArgs(config),
      PR_NUMBER: prNumber,
      BRANCH: branch,
      BASE_REF: baseRef,
    },
    output: Output.object({ tag: "output", schema: UpdateBranchOutput }),
    extractionPrompt,
    logging: { type: "stdout" },
  });

  const postSha = shFile("git", ["rev-parse", "HEAD"], repoDir).trim();
  if (postSha === preMergeSha) {
    fail("Agent produced no commits — branch still at pre-merge HEAD.");
  }

  const unresolved = sh("git diff --name-only --diff-filter=U", repoDir).trim();
  if (unresolved) {
    fail(`Agent left unresolved conflicts in:\n${unresolved}`);
  }

  console.log(`[update-branch] Agent resolved conflicts. Caller should push ${postSha}.`);
  return { comment: result.output.comment, shouldPush: true };
}

function tryMerge(
  baseRef: string,
  cwd: string,
): { status: "clean" } | { status: "conflict"; conflicts: string[] } {
  try {
    shFileInherit("git", ["merge", `origin/${baseRef}`, "--no-edit"], cwd);
    return { status: "clean" };
  } catch {
    const conflicts = sh("git diff --name-only --diff-filter=U", cwd)
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean);
    if (conflicts.length === 0) {
      fail("git merge failed but no conflicts reported — aborting.");
    }
    return { status: "conflict", conflicts };
  }
}
