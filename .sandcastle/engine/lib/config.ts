import { z } from "zod";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const unsupportedSandboxMessage =
  'Only sandbox "none" is currently supported. Docker and worktree sandbox modes are not wired into the TypeScript engine yet.';

const SandcastleConfigSchema = z.object({
  model: z.string().default("claude-opus-4-6"),
  baseBranch: z.string().default("main"),
  sandbox: z.literal("none", {
    errorMap: () => ({ message: unsupportedSandboxMessage }),
  }).default("none"),
  promptDir: z.string().default(".sandcastle/prompts"),
  codingStandards: z.string().default(".sandcastle/CODING_STANDARDS.md"),
  contextDoc: z.string().default("CONTEXT.md"),
  adrDir: z.string().default("docs/adr"),
  packageManager: z.enum(["npm", "pnpm", "yarn", "bun"]).default("pnpm"),
});

export type SandcastleConfig = z.infer<typeof SandcastleConfigSchema>;

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
