import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { resolveFiles } from "./util.ts";
import type { MarkupShare } from "./types.ts";

/**
 * Markup-share telemetry: how much of the finished workspace's view is
 * authored as `.native` markup vs Zig builder calls. Pure measurement — it is
 * recorded in result.json and the summary but never passes or fails a case.
 *
 * Heuristic, stated in full:
 *
 * - Markup view bytes: the total size of every `src/*.native` file (also one
 *   subdirectory level deep, matching the graders' file selector). A `.native`
 *   file is view code in its entirety, so its byte size is used as-is.
 *
 * - Builder view lines: in every non-test `src/*.zig`, each call of the form
 *   `ui.<method>(...)` — `ui` is the conventional parameter name for the
 *   canvas widget builder — counts as node construction unless <method> is a
 *   known non-constructing helper (see NON_NODE_BUILDER_METHODS). The measured
 *   region is the whole call expression: from the call's line through the line
 *   holding its matching close paren, found by a scanner that skips string
 *   literals, character literals, `//` comments, and `\\` multiline-string
 *   lines. Nested calls (a `ui.column` wrapping `ui.text` children) fall in
 *   overlapping ranges that are unioned, so no line is counted twice. Files
 *   named `tests.zig`/`test.zig` or ending in `_test(s).zig` are excluded:
 *   the scaffold's tests build widget trees with the same builder to assert
 *   on them, and that harness code is not shipped view.
 *
 * - Share: nativeBytes / (nativeBytes + builderViewBytes), where
 *   builderViewBytes is the actual byte size of the unioned builder lines
 *   (newlines included). Comparing source bytes to source bytes avoids an
 *   arbitrary bytes-per-line constant; both sides measure the same thing —
 *   text the author wrote to express the view. 1.0 = all-markup view,
 *   0.0 = all-builder, null = no view code found on either side.
 */
export function computeMarkupShare(workspacePath: string): MarkupShare {
  let nativeFiles = 0;
  let nativeBytes = 0;
  for (const path of resolveFiles(workspacePath, "src/*.native")) {
    nativeFiles += 1;
    nativeBytes += Buffer.byteLength(readFileSync(path, "utf8"), "utf8");
  }

  let builderViewLines = 0;
  let builderViewBytes = 0;
  for (const path of resolveFiles(workspacePath, "src/*.zig")) {
    if (isTestFile(basename(path))) continue;
    const counts = countBuilderViewLines(readFileSync(path, "utf8"));
    builderViewLines += counts.lines;
    builderViewBytes += counts.bytes;
  }

  const totalViewBytes = nativeBytes + builderViewBytes;
  return {
    nativeFiles,
    nativeBytes,
    builderViewLines,
    builderViewBytes,
    share: totalViewBytes > 0 ? nativeBytes / totalViewBytes : null,
  };
}

/** One-line rendering for per-case output. */
export function formatMarkupShare(metric: MarkupShare): string {
  const share = metric.share === null ? "n/a" : metric.share.toFixed(2);
  return (
    `share ${share} — ${metric.nativeFiles} .native file${metric.nativeFiles === 1 ? "" : "s"}, ` +
    `${metric.nativeBytes} B markup vs ${metric.builderViewLines} builder view line${metric.builderViewLines === 1 ? "" : "s"}, ` +
    `${metric.builderViewBytes} B`
  );
}

/**
 * Builder (canvas Ui) methods a view calls that do not construct widget
 * nodes: tree finalization, message-adapter helpers, text formatting, and
 * virtual-list window math. Everything else on `ui.` is treated as node
 * construction, so widget constructors added later count by default.
 */
const NON_NODE_BUILDER_METHODS = new Set([
  "init",
  "finalize",
  "finalizeWithTokens",
  "fmt",
  "inputMsg",
  "linkMsg",
  "scrollMsg",
  "valueMsg",
  "stepState",
  "virtualWindow",
  "virtualWindows",
]);

function isTestFile(name: string): boolean {
  return (
    name === "tests.zig" ||
    name === "test.zig" ||
    name.endsWith("_test.zig") ||
    name.endsWith("_tests.zig")
  );
}

const BUILDER_CALL = /\bui\.([A-Za-z_][A-Za-z0-9_]*)\(/g;

/** Count the unioned lines (and their bytes) covered by builder node-constructing calls. */
function countBuilderViewLines(source: string): { lines: number; bytes: number } {
  // Byte offset of each line start, for mapping call-site indices to lines.
  const lineStarts = [0];
  for (let index = 0; index < source.length; index += 1) {
    if (source[index] === "\n") lineStarts.push(index + 1);
  }
  const lineOf = (offset: number): number => {
    let low = 0;
    let high = lineStarts.length - 1;
    while (low < high) {
      const mid = (low + high + 1) >> 1;
      if (lineStarts[mid]! <= offset) low = mid;
      else high = mid - 1;
    }
    return low;
  };

  const covered = new Set<number>();
  BUILDER_CALL.lastIndex = 0;
  for (let match = BUILDER_CALL.exec(source); match !== null; match = BUILDER_CALL.exec(source)) {
    if (NON_NODE_BUILDER_METHODS.has(match[1]!)) continue;
    const openParen = match.index + match[0].length - 1;
    // Unbalanced call (truncated file): fall back to just the call line.
    const closeParen = findMatchingParen(source, openParen) ?? openParen;
    const first = lineOf(match.index);
    const last = lineOf(closeParen);
    for (let line = first; line <= last; line += 1) covered.add(line);
  }

  const sourceLines = source.split("\n");
  let bytes = 0;
  for (const line of covered) {
    // +1 for the newline each counted line carries in the file.
    bytes += Buffer.byteLength(sourceLines[line] ?? "", "utf8") + 1;
  }
  return { lines: covered.size, bytes };
}

/**
 * Index of the paren matching `source[openParen]`, skipping parens inside
 * string literals, character literals, `//` comments, and `\\` multiline
 * string lines. Returns undefined when the file ends first.
 */
function findMatchingParen(source: string, openParen: number): number | undefined {
  let depth = 0;
  let index = openParen;
  while (index < source.length) {
    const char = source[index]!;
    if (char === '"' || char === "'") {
      index = skipQuoted(source, index, char);
      continue;
    }
    if (char === "/" && source[index + 1] === "/") {
      index = skipToLineEnd(source, index);
      continue;
    }
    if (char === "\\" && source[index + 1] === "\\") {
      index = skipToLineEnd(source, index);
      continue;
    }
    if (char === "(") depth += 1;
    else if (char === ")") {
      depth -= 1;
      if (depth === 0) return index;
    }
    index += 1;
  }
  return undefined;
}

/** Index just past the closing quote, honoring backslash escapes. */
function skipQuoted(source: string, start: number, quote: string): number {
  let index = start + 1;
  while (index < source.length) {
    if (source[index] === "\\") index += 2;
    else if (source[index] === quote) return index + 1;
    else if (source[index] === "\n") return index; // unterminated: stop at line end
    else index += 1;
  }
  return index;
}

function skipToLineEnd(source: string, start: number): number {
  const newline = source.indexOf("\n", start);
  return newline === -1 ? source.length : newline;
}
