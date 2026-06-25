import { access } from "node:fs/promises";
import { join, isAbsolute } from "node:path";
import type { SandcastleConfig } from "./config.js";

interface ResolvePromptOpts {
  name: string;
  config: SandcastleConfig;
  repoDir: string;
  templatesDir: string;
}

async function fileExists(filePath: string): Promise<boolean> {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

/**
 * Resolves a prompt file path: checks override directory first, falls back to templates.
 * Returns the absolute path to the prompt file.
 *
 * Config-derived variables (CONTEXT_DOC, CODING_STANDARDS, etc.) are returned separately
 * via `configPromptArgs` — merge them into `promptArgs` when calling `run()`.
 */
export async function resolvePrompt(opts: ResolvePromptOpts): Promise<string> {
  const { name, config, repoDir, templatesDir } = opts;
  const filename = `${name}.md`;

  const overrideDir = isAbsolute(config.promptDir) ? config.promptDir : join(repoDir, config.promptDir);
  const overridePath = join(overrideDir, filename);

  if (await fileExists(overridePath)) {
    return overridePath;
  }

  const templatePath = join(templatesDir, filename);

  if (await fileExists(templatePath)) {
    return templatePath;
  }

  throw new Error(`Prompt not found: ${filename} — checked override (${overridePath}) and template (${templatePath})`);
}

/**
 * Returns config-derived prompt args to merge into `promptArgs` when calling `run()`.
 * These map config values to template variables that prompts can use.
 */
export function configPromptArgs(config: SandcastleConfig): Record<string, string> {
  return {
    CONTEXT_DOC: config.contextDoc,
    CODING_STANDARDS: config.codingStandards,
    ADR_DIR: config.adrDir,
    MODEL: config.model,
    BASE_BRANCH: config.baseBranch,
  };
}
