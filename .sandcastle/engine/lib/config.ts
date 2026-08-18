import { z } from "zod";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const unsupportedSandboxMessage =
  'Only sandbox "none" is currently supported. Docker and worktree sandbox modes are not wired into the TypeScript engine yet.';

/**
 * Paths that are producer-owned / vendored and must never be proposed for
 * changes by per-repo agents. These live in ctrlshft-public (the producer) and
 * are re-vendored into every consumer, so proposing edits to them from a
 * consumer repo would create divergent, sole-source drift.
 *
 * Defaults are always merged with any project-specific additions so a consumer
 * cannot accidentally include the vendored engine in its agent scope.
 */
export const DEFAULT_EXCLUDED_PATHS = [
  ".sandcastle",
  ".github/actions/sandcastle-setup",
  ".github/actions/sandcastle-teardown",
  ".github/workflows/agent-*",
  ".github/workflows/check-*",
  ".github/workflows/labels-*",
  ".github/workflows/require-*",
  ".github/workflows/sandcastle-*",
  ".github/copilot-setup-steps.yml",
  ".refactor",
];

const SandcastleConfigSchema = z.object({
  model: z.string().default("claude-opus-4-6"),
  baseBranch: z.string().default("main"),
  sandbox: z.literal("none", {
    errorMap: () => ({ message: unsupportedSandboxMessage }),
  }).default("none"),
  promptDir: z.string().default(".sandcastle/prompts"),
  codingStandards: z.string().default(".sandcastle/CODING_STANDARDS.md"),
  testingPrinciples: z.string().default(".sandcastle/testing-principles.md"),
  contextDoc: z.string().default("CONTEXT.md"),
  adrDir: z.string().default("docs/adr"),
  packageManager: z.enum(["npm", "pnpm", "yarn", "bun"]).default("pnpm"),
  /**
   * Project-specific paths to exclude from agent proposals, in addition to the
   * always-on vendored defaults. Glob patterns are supported.
   */
  excludedPaths: z.array(z.string()).default([]),
  /**
   * Nightly agent workflows to disable in this repo (e.g. "architecture-review",
   * "repo-hygiene", "keep-tests-tight"). A repo owner can turn off an agent pass
   * entirely without editing the vendored workflow file — the workflow's first
   * step exits early when its name appears here.
   */
  disabledWorkflows: z.array(z.string()).default([]),
});

export type SandcastleConfig = z.infer<typeof SandcastleConfigSchema>;

/** The full set of paths agents must not propose changes to (defaults + project). */
export function resolveExcludedPaths(config: Pick<SandcastleConfig, "excludedPaths">): string[] {
  const project = config.excludedPaths ?? [];
  return [...new Set([...DEFAULT_EXCLUDED_PATHS, ...project])];
}

export async function loadConfig(opts: { cwd: string }): Promise<SandcastleConfig> {
  const configPath = join(opts.cwd, "sandcastle.config.json");

  let raw: Record<string, unknown> = {};
  try {
    const content = await readFile(configPath, "utf8");
    raw = JSON.parse(content) as Record<string, unknown>;
  } catch (err: unknown) {
    if (err instanceof Error && "code" in err && (err as NodeJS.ErrnoException).code === "ENOENT") {
      // Missing config file — use all defaults
    } else {
      throw err;
    }
  }

  // Environment variable overrides take precedence
  const envModel = process.env["SANDCASTLE_MODEL"] ?? process.env["ANTHROPIC_MODEL"];
  const envBranch = process.env["SANDCASTLE_BASE_BRANCH"];
  const envSandbox = process.env["SANDCASTLE_SANDBOX"];
  const envPm = process.env["SANDCASTLE_PACKAGE_MANAGER"];

  if (envModel) raw["model"] = envModel;
  if (envBranch) raw["baseBranch"] = envBranch;
  if (envSandbox) raw["sandbox"] = envSandbox;
  if (envPm) raw["packageManager"] = envPm;

  return SandcastleConfigSchema.parse(raw);
}
