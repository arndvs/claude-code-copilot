import { execFileSync, execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

/** Default timeout for subprocess execution (2 minutes). */
const DEFAULT_TIMEOUT_MS = 120_000;

/** Default maxBuffer for subprocess output (10 MiB). */
const DEFAULT_MAX_BUFFER = 10 * 1024 * 1024;

export interface ShellOpts {
  cwd?: string;
  timeout?: number;
  maxBuffer?: number;
  input?: string;
}

export function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

export function fail(message: string): never {
  const outputDir = outputDirPath();
  writeFileSync(join(outputDir, "failure_reason.txt"), message);
  throw new Error(message);
}

export function outputDirPath(): string {
  return process.env.OUTPUT_DIR ?? tmpdir();
}

export function sh(cmd: string, cwdOrOpts?: string | ShellOpts): string {
  const opts = typeof cwdOrOpts === "string" ? { cwd: cwdOrOpts } : cwdOrOpts;
  const hasInput = opts?.input !== undefined;
  return execSync(cmd, {
    encoding: "utf8",
    cwd: opts?.cwd,
    timeout: opts?.timeout ?? DEFAULT_TIMEOUT_MS,
    maxBuffer: opts?.maxBuffer ?? DEFAULT_MAX_BUFFER,
    input: opts?.input,
    stdio: [hasInput ? "pipe" : "ignore", "pipe", "pipe"],
  });
}

export function shFile(command: string, args: string[], cwdOrOpts?: string | ShellOpts): string {
  const opts = typeof cwdOrOpts === "string" ? { cwd: cwdOrOpts } : cwdOrOpts;
  const hasInput = opts?.input !== undefined;
  return execFileSync(command, args, {
    encoding: "utf8",
    cwd: opts?.cwd,
    timeout: opts?.timeout ?? DEFAULT_TIMEOUT_MS,
    maxBuffer: opts?.maxBuffer ?? DEFAULT_MAX_BUFFER,
    input: opts?.input,
    stdio: [hasInput ? "pipe" : "ignore", "pipe", "pipe"],
  });
}

export function shFileInherit(command: string, args: string[], cwdOrOpts?: string | ShellOpts): void {
  const opts = typeof cwdOrOpts === "string" ? { cwd: cwdOrOpts } : cwdOrOpts;
  const hasInput = opts?.input !== undefined;
  execFileSync(command, args, {
    cwd: opts?.cwd,
    timeout: opts?.timeout ?? DEFAULT_TIMEOUT_MS,
    maxBuffer: opts?.maxBuffer ?? DEFAULT_MAX_BUFFER,
    input: opts?.input,
    stdio: hasInput ? ["pipe", "inherit", "inherit"] : "inherit",
  });
}

export function safeSh(cmd: string, cwdOrOpts?: string | ShellOpts): string {
  try {
    return sh(cmd, cwdOrOpts);
  } catch {
    return "";
  }
}
