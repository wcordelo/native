import { readFileSync } from "node:fs";
import { relative } from "node:path";
import { GATEWAY_BASE_URL } from "./agent.ts";
import { resolveFiles } from "./util.ts";

export const DEFAULT_JUDGE_MODEL = "anthropic/claude-opus-4.8";

/** Files shown to the judge when a case doesn't override them. */
const DEFAULT_JUDGE_FILES = ["src/*.native", "src/main.zig", "src/tests.zig"];
const MAX_FILE_BYTES = 24 * 1024;
const MAX_TOTAL_BYTES = 96 * 1024;

export interface JudgeScore {
  criterion: string;
  score: number;
  note: string;
}

export interface JudgeVerdict {
  overall: number;
  scores: JudgeScore[];
  summary: string;
}

const SYSTEM_PROMPT = `You are a strict senior code reviewer grading a Native SDK app written by another AI agent. Native SDK apps follow The Elm Architecture in Zig: a Model struct, a Msg tagged union, an update function, and a declarative Native markup view that only binds model data and dispatches messages.

Score each listed criterion from 0 to 10 (10 = exemplary, 7 = solid with minor nits, 5 = acceptable but flawed, 3 = poor, 0 = absent or broken). Judge only what the code shows; do not reward verbosity or comments. Be calibrated: reserve 9-10 for work you could not meaningfully improve. The overall score is your holistic judgment, not necessarily the mean.

Submit your verdict with the submit_verdict tool.`;

/** Forcing the verdict through a tool call guarantees well-formed JSON. */
const VERDICT_TOOL = {
  name: "submit_verdict",
  description: "Submit the final review verdict.",
  input_schema: {
    type: "object",
    required: ["scores", "overall", "summary"],
    properties: {
      scores: {
        type: "array",
        description: "One entry per criterion, in the order given.",
        items: {
          type: "object",
          required: ["criterion", "score", "note"],
          properties: {
            criterion: { type: "string", description: "The criterion text, verbatim." },
            score: { type: "number", minimum: 0, maximum: 10 },
            note: { type: "string", description: "One sentence of evidence." },
          },
        },
      },
      overall: { type: "number", minimum: 0, maximum: 10 },
      summary: {
        type: "string",
        description: "Two sentences: strongest aspect, weakest aspect.",
      },
    },
  },
} as const;

/**
 * Ask the judge model (via the AI Gateway's Anthropic-compatible
 * /v1/messages endpoint — same surface Claude Code itself uses) to grade the
 * workspace against the case's criteria.
 */
export async function judgeWorkspace(options: {
  gatewayKey: string;
  model: string;
  taskPrompt: string;
  criteria: string[];
  workspacePath: string;
  fileSelectors?: string[] | undefined;
}): Promise<JudgeVerdict> {
  const files = collectFiles(options.workspacePath, options.fileSelectors ?? DEFAULT_JUDGE_FILES);
  if (files.length === 0) {
    throw new Error("no workspace files matched the judge's file selectors");
  }
  const userPrompt = [
    "## Task the agent was given",
    options.taskPrompt,
    "",
    "## Criteria to score",
    ...options.criteria.map((criterion, index) => `${index + 1}. ${criterion}`),
    "",
    "## The agent's code",
    ...files.map((file) => `### ${file.path}\n\`\`\`\n${file.content}\n\`\`\``),
  ].join("\n");

  const response = await fetch(`${GATEWAY_BASE_URL}/v1/messages`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${options.gatewayKey}`,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: options.model,
      max_tokens: 1500,
      temperature: 0,
      system: SYSTEM_PROMPT,
      tools: [VERDICT_TOOL],
      tool_choice: { type: "tool", name: "submit_verdict" },
      messages: [{ role: "user", content: userPrompt }],
    }),
  });
  if (!response.ok) {
    const body = (await response.text()).slice(0, 400);
    throw new Error(`judge request failed: HTTP ${response.status} ${body}`);
  }
  const payload = (await response.json()) as {
    content?: Array<{ type: string; name?: string; input?: unknown }>;
  };
  const verdict = payload.content?.find(
    (block) => block.type === "tool_use" && block.name === "submit_verdict",
  )?.input;
  if (!verdict) throw new Error("judge response contained no submit_verdict tool call");
  return parseVerdict(verdict, options.criteria);
}

function collectFiles(
  workspacePath: string,
  selectors: string[],
): Array<{ path: string; content: string }> {
  const seen = new Set<string>();
  const files: Array<{ path: string; content: string }> = [];
  let total = 0;
  for (const selector of selectors) {
    for (const absolute of resolveFiles(workspacePath, selector)) {
      if (seen.has(absolute)) continue;
      seen.add(absolute);
      let content = readFileSync(absolute, "utf8");
      if (content.length > MAX_FILE_BYTES) {
        content = `${content.slice(0, MAX_FILE_BYTES)}\n... [truncated at ${MAX_FILE_BYTES} bytes]`;
      }
      if (total + content.length > MAX_TOTAL_BYTES) break;
      total += content.length;
      files.push({ path: relative(workspacePath, absolute), content });
    }
  }
  return files;
}

function parseVerdict(input: unknown, criteria: string[]): JudgeVerdict {
  const parsed = input as {
    scores?: Array<{ criterion?: string; score?: number; note?: string }>;
    overall?: number;
    summary?: string;
  };
  if (!Array.isArray(parsed.scores) || typeof parsed.overall !== "number") {
    throw new Error("judge verdict missing scores/overall");
  }
  const scores: JudgeScore[] = parsed.scores.map((entry, index) => ({
    criterion: entry.criterion ?? criteria[index] ?? `criterion ${index + 1}`,
    score: clamp(entry.score),
    note: entry.note ?? "",
  }));
  return {
    overall: clamp(parsed.overall),
    scores,
    summary: parsed.summary ?? "",
  };
}

function clamp(value: unknown): number {
  const numeric = typeof value === "number" && Number.isFinite(value) ? value : 0;
  return Math.min(10, Math.max(0, Math.round(numeric * 10) / 10));
}
