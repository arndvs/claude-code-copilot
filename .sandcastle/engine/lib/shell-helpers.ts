import { execFileSync, execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

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

export function sh(cmd: string, cwd?: string): string {
  return execSync(cmd, { encoding: "utf8", cwd, stdio: ["ignore", "pipe", "pipe"] });
}

export function shFile(command: string, args: string[], cwd?: string): string {
  return execFileSync(command, args, { encoding: "utf8", cwd, stdio: ["ignore", "pipe", "pipe"] });
}

export function safeSh(cmd: string, cwd?: string): string {
  try {
    return sh(cmd, cwd);
  } catch {
    return "";
  }
}
