/**
 * Sandcastle label pipeline — typed transition table.
 *
 * Canonical typed transition table for the label state machine described in
 * instructions/sandcastle-pipeline.instructions.md. Every agent-*.yml
 * workflow's label operations must conform to this table.
 */

// ── Label definitions ────────────────────────────────────────────────────────

/** Object types a label can be applied to. */
export type ObjectType = "issue" | "pr";

export interface LabelDef {
  /** Which object types this label may legally appear on. */
  appliesTo: readonly ObjectType[];
  /** GitHub label colour without the leading "#". */
  color: string;
  /** Human-readable GitHub label description. */
  description: string;
  /** If true, this label does not participate in transition legality. */
  stateMarker?: boolean;
}

/**
 * Canonical label catalogue.
 * Keys are the exact GitHub label strings.
 */
export const LABELS: Record<string, LabelDef> = {
  Sandcastle: {
    appliesTo: ["issue"],
    color: "7057ff",
    description: "Entry point — triggers agent review pipeline",
  },
  "agent:review": {
    appliesTo: ["issue", "pr"],
    color: "0075ca",
    description: "Agent is reviewing the issue or PR",
  },
  "agent:implement": {
    appliesTo: ["issue"],
    color: "e4e669",
    description: "Agent is implementing the issue",
  },
  "agent:pr-open": {
    appliesTo: ["issue"],
    color: "1d76db",
    description: "Agent has opened a PR for review",
  },
  "agent:fix": {
    appliesTo: ["pr"],
    color: "d93f0b",
    description: "Agent should fix PR review feedback",
  },
  "agent:merge": {
    appliesTo: ["pr"],
    color: "0e8a16",
    description: "Agent should merge the PR",
  },
  "agent:update-branch": {
    appliesTo: ["pr"],
    color: "5319e7",
    description: "Agent should update branch against base ref",
  },
  "agent:implement-prd": {
    appliesTo: ["issue"],
    color: "d4c5f9",
    description: "Agent should implement next sub-issue of a PRD",
  },
  "agent:queued": {
    appliesTo: ["issue"],
    color: "c5def5",
    description: "Agent waiting for blocking issues to close before implementing",
  },
  "agent:in-progress": {
    appliesTo: ["issue", "pr"],
    color: "fbca04",
    description: "Agent is actively working on this issue",
    stateMarker: true,
  },
  "agent:blocked": {
    appliesTo: ["issue", "pr"],
    color: "b60205",
    description: "Agent is blocked and needs human input",
    stateMarker: true,
  },
  "source:architecture-review": {
    appliesTo: ["issue"],
    color: "5319e7",
    description: "PRDs proposed by the automated architecture-review workflow",
    stateMarker: true,
  },
  "source:keep-tests-tight": {
    appliesTo: ["pr"],
    color: "1d76db",
    description: "Test-trim PRs opened by the automated keep-tests-tight workflow",
    stateMarker: true,
  },
  shft: {
    appliesTo: ["issue"],
    color: "7057ff",
    description: "Issues created by the Sandcastle engine (e.g. HITL review deferrals)",
    stateMarker: true,
  },
  hitl: {
    appliesTo: ["issue"],
    color: "d4c5f9",
    description: "Human-in-the-loop — requires human review or decision",
    stateMarker: true,
  },
  "repo-hygiene": {
    appliesTo: ["issue"],
    color: "7057ff",
    description: "Backlog issues proposed by the nightly repo-hygiene workflow",
    stateMarker: true,
  },
  "phase-0": {
    appliesTo: ["issue"],
    color: "c5def5",
    description: "Repo-hygiene phase 0 — safety net",
    stateMarker: true,
  },
  "phase-1": {
    appliesTo: ["issue"],
    color: "c5def5",
    description: "Repo-hygiene phase 1 — structure/layout",
    stateMarker: true,
  },
  "phase-2": {
    appliesTo: ["issue"],
    color: "c5def5",
    description: "Repo-hygiene phase 2 — DRY extraction",
    stateMarker: true,
  },
  "phase-3": {
    appliesTo: ["issue"],
    color: "c5def5",
    description: "Repo-hygiene phase 3 — styling/typing",
    stateMarker: true,
  },
  "phase-4": {
    appliesTo: ["issue"],
    color: "c5def5",
    description: "Repo-hygiene phase 4 — content/data",
    stateMarker: true,
  },
  "phase-5": {
    appliesTo: ["issue"],
    color: "c5def5",
    description: "Repo-hygiene phase 5 — ratchet",
    stateMarker: true,
  },
};

// ── Mutual exclusions ────────────────────────────────────────────────────────

/**
 * Sets of labels that must never coexist on the same object.
 * If a transition would leave both members present, it is invalid.
 */
export const MUTUAL_EXCLUSIONS: ReadonlyArray<readonly [string, string]> = [
  ["agent:in-progress", "agent:blocked"],
  ["agent:fix", "agent:merge"],
  ["agent:implement", "agent:queued"],
];

// ── Legal transitions ────────────────────────────────────────────────────────

/**
 * Declared legal transitions: "from label" → set of "to labels" that
 * may be added in the same operation (or shortly after) when "from" is
 * the trigger.  A transition not in this map is illegal.
 *
 * State markers (agent:in-progress, agent:blocked) are universally
 * allowed and are NOT listed here — see `isStateMarker()`.
 */
export const TRANSITIONS: ReadonlyMap<string, ReadonlySet<string>> = new Map([
  // Issue happy path
  ["Sandcastle", new Set(["agent:review"])],
  ["agent:review", new Set(["agent:implement"])],
  [
    "agent:implement",
    new Set(["agent:pr-open", "agent:implement-prd"]),
  ],
  // Queued → implement (promoted when blockers clear)
  ["agent:queued", new Set(["agent:implement"])],
  // PRD loop — can re-apply itself while sub-issues remain, and when the PRD is
  // complete it marks the PR ready for review (agent:review on the PR) or
  // produces a follow-up implement.
  [
    "agent:implement-prd",
    new Set(["agent:implement-prd", "agent:review", "agent:implement"]),
  ],
  // PR verdict paths
  ["agent:fix", new Set([])], // fix just pushes commits; no label added
  ["agent:merge", new Set([])], // merge closes the PR; no label added
  ["agent:update-branch", new Set([])], // branch updated; no label added
]);

// ── Helpers ──────────────────────────────────────────────────────────────────

function isStateMarker(label: string): boolean {
  return LABELS[label]?.stateMarker === true;
}

// ── Validation ───────────────────────────────────────────────────────────────

export interface TransitionProposal {
  add?: string[];
  remove?: string[];
}

export interface ValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
}

/**
 * Validate a proposed label mutation against the pipeline contract.
 *
 * @param current  - labels currently on the object
 * @param proposed - labels to add/remove
 * @param objectType - "issue" or "pr"
 * @param triggerLabel - the label that triggered the workflow (optional, for transition legality)
 */
export function validateTransition(
  current: string[],
  proposed: TransitionProposal,
  objectType: ObjectType,
  triggerLabel?: string,
): ValidationResult {
  const errors: string[] = [];
  const warnings: string[] = [];

  const adding = proposed.add ?? [];
  const removing = proposed.remove ?? [];

  // 1. Object-type check — is each added label allowed on this object type?
  for (const label of adding) {
    const def = LABELS[label];
    if (!def) {
      warnings.push(`Unknown label "${label}" — not in the pipeline catalogue.`);
      continue;
    }
    if (!def.appliesTo.includes(objectType)) {
      errors.push(
        `Label "${label}" cannot be applied to ${objectType} (allowed: ${def.appliesTo.join(", ")}).`,
      );
    }
  }

  // 2. Mutual-exclusion check — would the result contain conflicting labels?
  const resultSet = new Set(current);
  for (const r of removing) resultSet.delete(r);
  for (const a of adding) resultSet.add(a);

  for (const [a, b] of MUTUAL_EXCLUSIONS) {
    if (resultSet.has(a) && resultSet.has(b)) {
      errors.push(
        `Mutual exclusion violated: "${a}" and "${b}" cannot coexist.`,
      );
    }
  }

  // 3. Transition legality — if we know the trigger, check that each
  //    non-state-marker label being added is a declared successor.
  if (triggerLabel) {
    const allowed = TRANSITIONS.get(triggerLabel);
    for (const label of adding) {
      if (isStateMarker(label)) continue;
      if (!allowed?.has(label)) {
        errors.push(
          `Transition "${triggerLabel}" → "${label}" is not declared in the pipeline state machine.`,
        );
      }
    }
  }

  return { valid: errors.length === 0, errors, warnings };
}
