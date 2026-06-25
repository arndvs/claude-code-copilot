import { existsSync } from "node:fs";
import path from "node:path";

export function resolveDefaultTemplatesDir(opts: { workflowDir: string }): string {
  return resolveDefaultSandcastleDir({
    workflowDir: opts.workflowDir,
    relativeParts: ["templates", "prompts"],
    description: "prompt templates",
  });
}

export function resolveDefaultExtractionsDir(opts: { workflowDir: string }): string {
  return resolveDefaultSandcastleDir({
    workflowDir: opts.workflowDir,
    relativeParts: ["templates", "extractions"],
    description: "extraction templates",
  });
}

function resolveDefaultSandcastleDir(opts: { workflowDir: string; relativeParts: string[]; description: string }): string {
  const candidates = [
    path.resolve(opts.workflowDir, "..", "..", ...opts.relativeParts),
    path.resolve(opts.workflowDir, "..", "..", "..", ...opts.relativeParts),
  ];
  const existingPath = candidates.find((candidate) => existsSync(candidate));

  if (!existingPath) {
    throw new Error(
      `[sandcastle] Unable to locate ${opts.description}. Checked:\n- ${candidates.join("\n- ")}`,
    );
  }

  return existingPath;
}