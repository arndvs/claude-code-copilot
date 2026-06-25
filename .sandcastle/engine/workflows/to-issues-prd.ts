import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { Output, StructuredOutputError, claudeCode } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { PrdSlicesOutput } from "../schemas/prd-slices-output.js";
import { loadConfig } from "../lib/config.js";
import { resolvePrompt, configPromptArgs } from "../lib/resolve-prompt.js";
import { runWithRetry } from "../lib/run-with-retry.js";
import { resolveDefaultTemplatesDir } from "../lib/default-template-paths.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultTemplatesDir = resolveDefaultTemplatesDir({ workflowDir: __dirname });

export function resolveBlockedByNumbers(opts: { sliceTitle: string; blockedBy: string[]; createdIssues: Map<string, number> }): number[] {
  const blockedByNumbers: number[] = [];
  const missingTitles: string[] = [];

  for (const title of opts.blockedBy) {
    const issueNumber = opts.createdIssues.get(title);
    if (issueNumber == null) {
      missingTitles.push(title);
    } else {
      blockedByNumbers.push(issueNumber);
    }
  }

  if (missingTitles.length > 0) {
    const createdTitles = [...opts.createdIssues.keys()];
    const createdList = createdTitles.length > 0 ? createdTitles.join(", ") : "(none)";
    throw new Error(
      `[to-issues-prd] Slice "${opts.sliceTitle}" references blockedBy titles that have not been created yet: ${missingTitles.join(", ")}. Created titles: ${createdList}`,
    );
  }

  return blockedByNumbers;
}

export async function runToIssuesPrd(opts: { issueNumber: string; repoDir: string; model?: string; templatesDir?: string; dryRun: boolean }): Promise<void> {
  const config = await loadConfig({ cwd: opts.repoDir });
  const { issueNumber, repoDir, dryRun } = opts;
  const model = opts.model ?? config.model;
  const templatesDir = opts.templatesDir ?? defaultTemplatesDir;

  console.log(`[to-issues-prd] Reading PRD from issue #${issueNumber}...`);

  const prdJson = execFileSync("gh", ["issue", "view", issueNumber, "--json", "title,body"], {
    encoding: "utf8",
    cwd: repoDir,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const prd = JSON.parse(prdJson) as { title: string; body: string };

  console.log(`[to-issues-prd] PRD: ${prd.title}`);

  try {
    const promptFile = await resolvePrompt({ name: "to-issues-prd", config, repoDir, templatesDir });

    const result = await runWithRetry({
      agent: claudeCode(model),
      sandbox: noSandbox(),
      cwd: repoDir,
      promptFile,
      promptArgs: {
        ...configPromptArgs(config),
        ISSUE_NUMBER: issueNumber,
      },
      output: Output.object({ tag: "output", schema: PrdSlicesOutput }),
      logging: { type: "stdout" },
    });

    console.log(`\n[to-issues-prd] Generated ${result.output.slices.length} slices`);

    if (dryRun) {
      console.log(`[to-issues-prd] DRY RUN — printing slices without creating issues:\n`);
      for (const slice of result.output.slices) {
        console.log(`  [${slice.type}] ${slice.title}`);
        console.log(`    ${slice.whatToBuild}`);
        for (const ac of slice.acceptanceCriteria) {
          console.log(`    - [ ] ${ac}`);
        }
        if (slice.blockedBy.length > 0) {
          console.log(`    Blocked by: ${slice.blockedBy.join(", ")}`);
        }
        console.log();
      }
      return;
    }

    const createdIssues = new Map<string, number>();

    for (const slice of result.output.slices) {
      const blockedByNumbers = resolveBlockedByNumbers({
        sliceTitle: slice.title,
        blockedBy: slice.blockedBy,
        createdIssues,
      });

      const blockedByLine = blockedByNumbers.length > 0
        ? `**Blocked by:** ${blockedByNumbers.map((n) => `#${n}`).join(", ")}`
        : "";

      const body = [
        `# ${slice.title}`,
        "",
        `**Type:** ${slice.type}`,
        `**Parent PRD:** #${issueNumber}`,
        ...(blockedByLine ? [blockedByLine] : []),
        "",
        "## Description",
        "",
        slice.whatToBuild,
        "",
        "## Acceptance Criteria",
        "",
        ...slice.acceptanceCriteria.map((ac) => `- [ ] ${ac}`),
      ].join("\n");

      const createdJson = execFileSync(
        "gh",
        ["issue", "create", "--title", slice.title, "--body-file", "-"],
        {
          input: body,
          encoding: "utf8",
          cwd: repoDir,
          stdio: ["pipe", "pipe", "pipe"],
        },
      );

      const issueUrl = createdJson.trim();
      const numberMatch = issueUrl.match(/\/(\d+)$/);
      if (!numberMatch) {
        throw new Error(`Failed to parse issue number from: ${issueUrl}`);
      }
      const newNumber = parseInt(numberMatch[1]!, 10);
      createdIssues.set(slice.title, newNumber);

      console.log(`[to-issues-prd] Created #${newNumber}: ${slice.title}`);

      execFileSync("gh", ["issue", "edit", String(newNumber), "--add-parent", issueNumber], {
        cwd: repoDir,
        stdio: ["ignore", "pipe", "pipe"],
      });
    }

    console.log(`\n[to-issues-prd] Complete — created ${createdIssues.size} issues as sub-issues of #${issueNumber}`);
  } catch (error) {
    if (error instanceof StructuredOutputError) {
      console.error(`[to-issues-prd] Failed: malformed agent output`);
      console.error(`[to-issues-prd] Tag: <${error.tag}>`);
      console.error(`[to-issues-prd] Raw matched: ${error.rawMatched ?? "(no match found)"}`);
      if (error.cause) console.error(`[to-issues-prd] Cause:`, error.cause);
      process.exit(1);
    }
    throw error;
  }
}
