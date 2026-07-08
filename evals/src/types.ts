/** Per-case configuration, loaded from `cases/<name>/eval.json`. */
export interface EvalCase {
  /** Case name; must match the directory name. */
  name: string;
  /** Short human description of what the case exercises. */
  description: string;
  /** The task prompt handed to the agent-under-test. Describes app requirements, never the solution. */
  prompt: string;
  /** Scaffold frontend passed to `native init --frontend <frontend>`. */
  frontend: "native";
  /** Wall-clock budget for the agent run, in milliseconds. */
  timeoutMs: number;
  /** `--max-turns` for the claude invocation. */
  maxTurns: number;
  /** Deterministic graders, run in order after the agent finishes. */
  checks: CheckSpec[];
}

/**
 * Where a case ran and got graded. `macos-local` is the default local run;
 * `linux-sandbox` is a per-case Vercel Sandbox microVM (Linux, headless X).
 */
export type Lane = "macos-local" | "linux-sandbox";

/** Fields every check type accepts. */
interface CheckCommon {
  /**
   * Lanes this check grades on; omitted means every lane. Annotate a check
   * here when the surface it greps exists on only one OS, so on the other
   * lane it reports "skipped (lane)" instead of failing the case — the
   * summary then distinguishes "fails" from "not applicable on this lane".
   */
  lanes?: Lane[];
}

export type CheckSpec =
  | BuildTestCheck
  | MarkupCheckCheck
  | FileGrepCheck
  | SnapshotGrepCheck
  | LlmJudgeCheck;

/** Run `native test <args>` in the workspace (zero-config app test suite). */
export interface BuildTestCheck extends CheckCommon {
  type: "build_test";
  /** Extra zig build flags passed through, e.g. ["-Dplatform=null"]. */
  args?: string[];
}

/** Run `native markup check` on every `src/**\/*.native` in the workspace. */
export interface MarkupCheckCheck extends CheckCommon {
  type: "markup_check";
}

/** Grep workspace files for a pattern. */
export interface FileGrepCheck extends CheckCommon {
  type: "file_grep";
  /** Glob-ish file selector relative to the workspace: exact path or "src/*.native". */
  files: string;
  /** JavaScript regular expression source (no flags; matched with "m"). */
  pattern: string;
  /** true = pattern must appear in at least one selected file; false = must appear in none. */
  expect: boolean;
  description: string;
}

/**
 * Build the workspace app with `-Dautomation=true`, launch it (directly on
 * the macos-local lane, under the sandbox's Xvfb display on linux-sandbox),
 * wait for the automation server, then grep the widget snapshot. Skipped
 * (reported as "skipped", not passed) when --skip-live is set or the lane
 * has no way to launch the app.
 */
export interface SnapshotGrepCheck extends CheckCommon {
  type: "snapshot_grep";
  /** Each JavaScript regexp source must match somewhere in snapshot.txt. */
  patterns: string[];
  description: string;
}

/**
 * Grade quality dimensions the deterministic checks can't see (idiomatic
 * Model/Msg design, template factoring, test meaningfulness) with a judge
 * model called directly through the AI Gateway. Advisory by default: the
 * score is recorded and printed but never fails the case. Skipped in
 * --dry-run (no model calls).
 */
export interface LlmJudgeCheck extends CheckCommon {
  type: "llm_judge";
  /** Case-specific criteria, each scored 0-10 by the judge. */
  criteria: string[];
  /** Workspace files to show the judge (default: src/*.native, src/main.zig, src/tests.zig). */
  files?: string[];
  /** Overall score at or above this counts as pass. Default 6. */
  minScore?: number;
  /** When false, an overall score below minScore fails the case. Default true. */
  advisory?: boolean;
  description: string;
}

export interface CheckResult {
  type: CheckSpec["type"];
  description: string;
  status: "pass" | "fail" | "skipped";
  /** Trimmed evidence: failing command output tail, missing pattern, etc. */
  detail?: string;
  /** llm_judge only: the judge's overall 0-10 score. */
  score?: number;
  /** llm_judge only: a failing advisory check does not fail the case. */
  advisory?: boolean;
  durationMs: number;
}

export interface AgentRunResult {
  status: "completed" | "timeout" | "error" | "dry_run";
  model: string;
  numTurns?: number;
  totalCostUsd?: number;
  durationMs: number;
  sessionId?: string;
  /** Path to the captured stream-json transcript. */
  transcriptPath?: string;
  errorDetail?: string;
}

/**
 * View-authoring telemetry computed from the finished workspace: how much of
 * the UI is `.native` markup vs Zig builder calls. Never a pass/fail signal.
 * Heuristic documented in markup-share.ts.
 */
export interface MarkupShare {
  /** Count of src/*.native markup files (also one subdirectory level deep). */
  nativeFiles: number;
  /** Total bytes across those markup files; a markup file is view code in full. */
  nativeBytes: number;
  /** Unioned lines covered by builder node-constructing call expressions in non-test src/*.zig. */
  builderViewLines: number;
  /** Actual source bytes of those lines, newlines included. */
  builderViewBytes: number;
  /** nativeBytes / (nativeBytes + builderViewBytes); null when no view code was found. */
  share: number | null;
}

export interface CaseResult {
  case: string;
  /** 1-based trial number; only present when the run had --trials > 1. */
  trial?: number;
  /** Where the case ran and got graded. */
  lane: Lane;
  workspace: string;
  startedAt: string;
  dryRun: boolean;
  agent: AgentRunResult;
  /** Absent only when the run crashed before a workspace existed. */
  markupShare?: MarkupShare;
  checks: CheckResult[];
  passed: boolean;
}

/** Per-check aggregation across the trials of one case (--trials > 1). */
export interface CheckAggregate {
  type: CheckSpec["type"];
  description: string;
  pass: number;
  fail: number;
  skipped: number;
  /** llm_judge only: mean of the recorded overall scores. */
  meanScore?: number;
}

/**
 * Aggregated result for one case across N independent trials, written to
 * results/<stamp>/<case>/aggregate.json (per-trial result.json files live in
 * results/<stamp>/<case>/trial-<n>/). Only produced when --trials > 1.
 */
export interface CaseAggregate {
  case: string;
  trials: number;
  /** Trials where every non-advisory check passed and the agent completed. */
  passedTrials: number;
  checks: CheckAggregate[];
  /** Mean of all recorded llm_judge overall scores across trials. */
  meanJudgeScore?: number;
  /** Mean markup share across trials that measured one (see MarkupShare). */
  meanMarkupShare?: number;
  meanTurns?: number;
  totalCostUsd?: number;
  /** Sum of per-trial durations (agent + checks); trials may overlap in wall-clock. */
  totalDurationMs: number;
  results: CaseResult[];
}

export interface RunnerOptions {
  repoRoot: string;
  evalsRoot: string;
  caseNames: string[];
  model: string;
  judgeModel: string;
  dryRun: boolean;
  skipLive: boolean;
  skipPermissions: boolean;
  keepWorkspaces: boolean;
  /** Independent trials per case (own workspace, agent run, checks, judge). Default 1. */
  trials: number;
  /** Cases run concurrently up to this limit (default 2 local, all in sandbox mode). */
  concurrency: number | undefined;
  /** Run each case in its own Vercel Sandbox microVM instead of locally. */
  sandbox: boolean;
  sandboxVcpus: number;
  /**
   * Registry reference for the sandbox image (see evals/sandbox/). A bare
   * repository name resolves within the linked project; `latest` tag.
   */
  sandboxImage: string;
  /**
   * Grading lane. Local runs grade on macos-local; the sandbox path passes
   * --lane linux-sandbox to the harness invocation inside the microVM.
   */
  lane: Lane;
}
