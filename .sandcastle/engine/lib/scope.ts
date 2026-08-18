/**
 * Out-of-scope proposal detection — the engine-level backstop for vendored /
 * producer-owned paths.
 *
 * Prompts tell the agent which paths are out of scope ({{OUT_OF_SCOPE_PATHS}}),
 * but models can ignore instructions. This helper re-checks the agent's own
 * proposal text (title, body, candidates) against the resolved exclusion list
 * and forces a "skipped" status when it references an excluded path, so the
 * workflow never creates an issue that would diverge from the producer's
 * single source of truth.
 */
import { resolveExcludedPaths, type SandcastleConfig } from "./config.js";

/**
 * Glob-aware path matcher. Supports `*` (single segment) and `**` (multi
 * segment) suffixes/segments — enough for the vendored-path defaults.
 * Tolerant of a missing leading dot (agents often write `sandcastle/...`
 * when they mean `.sandcastle/...`).
 */
export function isPathExcluded(path: string, excludedPaths: string[]): boolean {
  const normalized = path.replace(/\\/g, "/");
  // Variants with/without a single leading dot
  const variants = normalized.startsWith("./")
    ? [normalized, normalized.slice(2)]
    : [normalized, normalized.startsWith(".") ? normalized : `.${normalized}`];

  return excludedPaths.some((pattern) => {
    const p = pattern.replace(/\\/g, "/").replace(/\/+$/, "");

    // Try the dot-variants against the pattern
    for (const candidate of variants) {
      if (candidate === p || candidate.startsWith(`${p}/`)) return true;

      // Single-segment or multi-segment glob
      if (p.includes("*")) {
        const regex = new RegExp(
          `^${p
            .split("/")
            .map((seg) => seg.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*\*/g, ".*").replace(/\*/g, "[^/]*"))
            .join("/")}(?:/.*)?$`,
        );
        if (regex.test(candidate)) return true;
      }
    }
    return false;
  });
}

/**
 * Extract candidate file paths from free-form proposal text. Looks for literal
 * paths (dir/file, extensions) and tick-quoted references that agents commonly
 * cite when describing a change. Matches both `.sandcastle/...` and `src/...`.
 */
export function extractPathsFromText(text: string): string[] {
  // Matches:
  //   - `engine/lib/dispatch.ts` (tick-quoted)
  //   - .sandcastle/workflows/repo-hygiene.ts (dot-dir first segment)
  //   - src/app/page.tsx (bare)
  const matches = text.match(
    /(?:`)?((?:\.{1,2}\/)?(?:(?:\.[\w-]+)|[\w@~[\]-]+)(?:\/[\w@~[\]().-]+)+)(?:`)?/g,
  ) ?? [];
  return matches.map((m) => m.replace(/^`|`$/g, "")).filter((p) => p.length > 1);
}

/**
 * Returns true when any proposal text references an excluded path.
 * Cheap, opinionated heuristic: a proposal that names a vendored path in its
 * title/body/candidates is presumed to want to change it.
 */
export function isProposalOutOfScope(proposal: { title: string; body: string; candidatesConsidered: string[] }, config: SandcastleConfig): boolean {
  const excluded = resolveExcludedPaths(config);
  const haystack = [proposal.title, proposal.body, ...proposal.candidatesConsidered]
    .join("\n")
    // Normalize backticks/quotes/punctuation so paths read naturally.
    .replace(/[`"'()[\]]/g, " ");

  for (const path of extractPathsFromText(haystack)) {
    if (isPathExcluded(path, excluded)) return true;
  }

  return false;
}