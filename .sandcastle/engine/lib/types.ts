/**
 * Types for the Copilot review comment scoring system.
 *
 * Comments are scored 0-100 and assigned to tiers that determine
 * whether fixes are applied automatically, deferred, or escalated.
 */

export type Tier = "auto" | "confirm" | "hitl";

export interface PrComment {
  /** File path the comment references */
  path: string | null;
  /** Line number the comment references */
  line: number | null;
  /** Comment body text */
  body: string;
  /** Whether the comment references code across multiple files */
  crossFile?: boolean;
  /** Number of files touched by the suggested change */
  filesAffected?: number;
  /** Number of lines touched by the suggested change */
  linesAffected?: number;
  /** Whether the referenced file has changed since the comment was posted */
  isStale?: boolean;
}

export interface Signal {
  /** Human-readable description of the signal */
  label: string;
  /** Score delta applied by this signal */
  delta: number;
}

export interface ScoredComment {
  /** Original comment */
  comment: PrComment;
  /** Final clamped score (0-100) */
  score: number;
  /** Assigned tier based on score */
  tier: Tier;
  /** Signals that contributed to the score */
  signals: Signal[];
}
