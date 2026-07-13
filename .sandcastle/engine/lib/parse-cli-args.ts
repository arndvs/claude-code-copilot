export interface CliArgs {
  workflow: string;
  issue?: string;
  issueTitle?: string;
  pr?: string;
  repo?: string;
  round?: string;
  maxRounds?: string;
  branch?: string;
  baseRef?: string;
  prdNumber?: string;
  prdTitle?: string;
  subIssueNumber?: string;
  subIssueTitle?: string;
  dryRun: boolean;
}

const flagsRequiringValues = new Map<string, keyof Omit<CliArgs, "workflow" | "dryRun">>([
  ["--issue", "issue"],
  ["--issue-title", "issueTitle"],
  ["--pr", "pr"],
  ["--repo", "repo"],
  ["--round", "round"],
  ["--max-rounds", "maxRounds"],
  ["--branch", "branch"],
  ["--base-ref", "baseRef"],
  ["--prd-number", "prdNumber"],
  ["--prd-title", "prdTitle"],
  ["--sub-issue-number", "subIssueNumber"],
  ["--sub-issue-title", "subIssueTitle"],
]);

export function parseCli(argv: string[]): CliArgs {
  if (argv.length === 0) {
    throw new Error("Missing workflow name. Usage: run.ts <workflow-name> [--issue N] [--issue-title TEXT] [--pr N] [--repo PATH] [--round N] [--max-rounds N] [--branch REF] [--base-ref REF] [--prd-number N] [--prd-title TEXT] [--sub-issue-number N] [--sub-issue-title TEXT] [--dry-run]");
  }

  const workflow = argv[0]!;
  let dryRun = false;
  const values: Partial<Omit<CliArgs, "workflow" | "dryRun">> = {};

  for (let i = 1; i < argv.length; i++) {
    const arg = argv[i]!;
    const valueKey = flagsRequiringValues.get(arg);

    if (valueKey) {
      const value = argv[i + 1];
      if (!value || value.startsWith("--")) {
        throw new Error(`Missing value for ${arg}`);
      }
      values[valueKey] = value;
      i++;
    } else if (arg === "--dry-run") {
      dryRun = true;
    } else if (arg.startsWith("--")) {
      throw new Error(`Unknown flag: ${arg}`);
    }
  }

  return { workflow, ...values, dryRun };
}
