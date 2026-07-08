#!/usr/bin/env tsx
/**
 * Sandcastle dispatcher — single entry point for all workflow runners.
 * Workflow YAMLs call: ./.sandcastle/engine/node_modules/.bin/tsx .sandcastle/run.ts <workflow-name> [flags]
 * Supported flags are parsed centrally in engine/lib/parse-cli-args.ts.
 */

import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseCli } from "./engine/lib/parse-cli-args.js";
import { resolveWorkflow, WORKFLOW_NAMES } from "./engine/lib/dispatch.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const templatesDir = path.resolve(__dirname, "templates", "prompts");

async function main(): Promise<void> {
  const args = parseCli(process.argv.slice(2));

  const runner = resolveWorkflow(args.workflow);

  if (!runner) {
    const available = WORKFLOW_NAMES.join(", ");
    console.error(`Unknown workflow: "${args.workflow}". Available: ${available}`);
    process.exitCode = 1;
    return;
  }

  try {
    const repoDir = args.repo ? path.resolve(args.repo) : path.resolve(__dirname, "..");
    await runner({ args, repoDir, templatesDir });
  } catch (error) {
    console.error(`[${args.workflow}] Failed:`, error);
    process.exitCode = 1;
  }
}

void main();
