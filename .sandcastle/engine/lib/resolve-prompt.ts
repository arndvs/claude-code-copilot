import { readFileSync } from "node:fs";
import { access } from "node:fs/promises";
import { join, isAbsolute } from "node:path";
import { resolveExcludedPaths, type SandcastleConfig } from "./config.js";

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
    TESTING_PRINCIPLES: config.testingPrinciples,
    ADR_DIR: config.adrDir,
    BASE_BRANCH: config.baseBranch,
    OUT_OF_SCOPE_PATHS: resolveExcludedPaths(config).join(", "),
  };
}

export function extractPromptPlaceholders(content: string): Set<string> {
  return new Set([...content.matchAll(/\{\{\s*([^{}]+?)\s*\}\}/g)].map((match) => match[1]!.trim().toUpperCase()));
}

export function filterPromptArgs(promptFile: string, promptArgs: Record<string, string>): Record<string, string> {
  const placeholders = extractPromptPlaceholders(readFileSync(promptFile, "utf8"));

  return Object.fromEntries(
    Object.entries(promptArgs).filter(([name]) => placeholders.has(name.toUpperCase())),
  );
}
