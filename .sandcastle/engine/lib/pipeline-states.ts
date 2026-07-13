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
  /** If true, this label does not participate in transition legality. */
  stateMarker?: boolean;
}

/**
 * Canonical label catalogue.
 * Keys are the exact GitHub label strings.
 */
export const LABELS: Record<string, LabelDef> = {
  Sandcastle: { appliesTo: ["issue"] },
  "agent:review": { appliesTo: ["issue", "pr"] },
  "agent:implement": { appliesTo: ["issue"] },
  "agent:pr-open": { appliesTo: ["issue"] },
  "agent:fix": { appliesTo: ["pr"] },
  "agent:merge": { appliesTo: ["pr"] },
  "agent:update-branch": { appliesTo: ["pr"] },
  "agent:implement-prd": { appliesTo: ["issue"] },
  "agent:queued": { appliesTo: ["issue"] },
  "agent:in-progress": { appliesTo: ["issue", "pr"], stateMarker: true },
  "agent:blocked": { appliesTo: ["issue", "pr"], stateMarker: true },
  "source:architecture-review": {
    appliesTo: ["issue"],
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
  // PRD loop — can re-apply itself or produce a review on a PR
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
      if (!LABELS[label]) continue;
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
