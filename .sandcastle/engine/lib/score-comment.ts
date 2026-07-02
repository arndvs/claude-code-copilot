import type { PrComment, ScoredComment, Signal, Tier } from "./types.js";

const BASE_SCORE = 50;

const MECHANICAL_PATTERNS = [
  /\brename\b/i,
  /\badd\s+(a\s+)?(?:null\s+)?guard\b/i,
  /\badd\s+(a\s+)?type\b/i,
  /\bfix\s+typo\b/i,
  /\bmissing\s+`?await\b/i,
  /\badd\s+missing\b/i,
  /\bchange\s+`?\w+`?\s+to\s+`?\w+`?\b/i,
];

const VAGUE_PATTERNS = [
  /\bconsider\b/i,
  /\bmight\s+want\s+to\b/i,
  /\bcould\b/i,
  /\bperhaps\b/i,
  /\bin\s+some\s+cases\b/i,
];

// Forced-confirm keywords — floor the tier at "confirm" even when the arithmetic
// yields "auto", because these signal a behavior/contract change that needs explicit
// human approval. These patterns are stable policy: when you change them, update the matching
// pin in the source repo's score-comment tests and the review-pr-copilot skill's Forced-Confirm
// list so the prose and code stay aligned.
export const FORCED_CONFIRM_PATTERNS = [
  /\brefactor\b/i,
  /\balign\b/i,
  /\bnormalize\b/i,
  /\bstandardize\b/i,
  /\bsemantics?\b/i,
  /\bbehaviou?rs?\b/i,
  /\bcontract\b/i,
  /\bsignature\b/i,
  /\breturn[\s-]type\b/i,
  /\bparameter[\s-]type\b/i,
  /\berror model\b/i,
];

const API_CHANGE_PATTERNS = [
  /\bexport\b/i,
  /\bpublic\s+api\b/i,
  /\btype\s+signature\b/i,
  /\binterface\b.*\bchange\b/i,
];

const ERROR_HANDLING_PATTERNS = [
  /\bcatch\b/i,
  /\berror\s+handl/i,
  /\brethrow\b/i,
  /\btry\b.*\bcatch\b/i,
  /\bswallow/i,
];

const SHARED_PATH_PATTERNS = [
  /\blib\b/,
  /\butils?\b/,
  /\bhelpers?\b/,
  /\bhooks?\b/,
  /\bshared\b/,
  /\bcommon\b/,
  /\bschemas?\b/,
];

const TEST_PATH_PATTERNS = [
  /\.test\.\w+$/,
  /\.spec\.\w+$/,
  /__tests__\//,
  /\bfixtures?\b/,
];

function matchesAny(text: string, patterns: RegExp[]): boolean {
  return patterns.some((p) => p.test(text));
}

function collectSignals(comment: PrComment): Signal[] {
  const signals: Signal[] = [];
  const { body, path, line } = comment;

  // +20 specific — cites exact line and exact change
  if (path && line != null) {
    signals.push({ label: "specific", delta: 20 });
  }

  // +25 mechanical fix
  if (matchesAny(body, MECHANICAL_PATTERNS)) {
    signals.push({ label: "mechanical", delta: 25 });
  }

  // +15 small scope — ≤1 file and ≤10 lines
  if (comment.filesAffected != null && comment.linesAffected != null && comment.filesAffected <= 1 && comment.linesAffected <= 10) {
    signals.push({ label: "small-scope", delta: 15 });
  }

  // +10 no public API / exported type signature change
  if (!matchesAny(body, API_CHANGE_PATTERNS)) {
    signals.push({ label: "no-api-change", delta: 10 });
  }

  // +15 concrete suggestion — comment contains code block or quoted replacement
  if (/```[\s\S]*```/.test(body) || /`[^`]+`\s*(?:→|->|to)\s*`[^`]+`/.test(body)) {
    signals.push({ label: "concrete-suggestion", delta: 15 });
  }

  // NOTE: the review-pr-copilot skill also lists a +15 "touched code has test coverage"
  // signal. It is intentionally absent here — CI scores from comment metadata only and has
  // no coverage data at scoring time, so that signal is local-only (human run). Keep this
  // asymmetry documented in the review-pr-copilot skill.

  // -25 vague language
  if (matchesAny(body, VAGUE_PATTERNS)) {
    signals.push({ label: "vague", delta: -25 });
  }

  // -20 shared util / hook / schema
  if (path && matchesAny(path, SHARED_PATH_PATTERNS)) {
    signals.push({ label: "shared-util", delta: -20 });
  }

  // -15 cross-file or cross-module change
  if (comment.crossFile) {
    signals.push({ label: "cross-file", delta: -15 });
  }

  // -20 modifies test assertions or fixtures
  if (path && matchesAny(path, TEST_PATH_PATTERNS)) {
    signals.push({ label: "test-modification", delta: -20 });
  }

  // -15 changes error-handling semantics
  if (matchesAny(body, ERROR_HANDLING_PATTERNS)) {
    signals.push({ label: "error-handling", delta: -15 });
  }

  // -10 file changed since the comment was posted (stale context)
  if (comment.isStale) {
    signals.push({ label: "stale", delta: -10 });
  }

  return signals;
}

function assignTier(score: number): Tier {
  if (score >= 75) return "auto";
  if (score >= 40) return "confirm";
  return "hitl";
}

export function scoreComment(comment: PrComment): ScoredComment {
  const signals = collectSignals(comment);

  const rawScore = signals.reduce((acc, s) => acc + s.delta, BASE_SCORE);
  const clampedScore = Math.max(0, Math.min(100, rawScore));

  let tier = assignTier(clampedScore);

  // Forced-confirm keywords: cap at confirm even if arithmetic yields auto
  if (tier === "auto" && matchesAny(comment.body, FORCED_CONFIRM_PATTERNS)) {
    tier = "confirm";
  }

  return { comment, score: clampedScore, tier, signals };
}
