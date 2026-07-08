import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { mdxToCleanMarkdown } from "@/lib/mdx-to-markdown";

/**
 * Serve every docs page as clean markdown: /md/<page path> returns the
 * page's .mdx source with imports and JSX components stripped or
 * replaced (see mdx-to-markdown.ts). Rendered statically at build time
 * for exactly the set of page.mdx files; the "Copy Page" button fetches
 * from here, and agents can fetch it directly.
 */

export const dynamic = "force-static";
export const dynamicParams = false;

const appDir = () => path.join(process.cwd(), "src", "app");

export async function generateStaticParams(): Promise<{ slug: string[] }[]> {
  const params: { slug: string[] }[] = [];
  async function walk(dir: string, slug: string[]): Promise<void> {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isDirectory()) {
        await walk(path.join(dir, entry.name), [...slug, entry.name]);
      } else if (entry.name === "page.mdx" && slug.length > 0) {
        params.push({ slug });
      }
    }
  }
  await walk(appDir(), []);
  return params;
}

export async function GET(_request: Request, context: { params: Promise<{ slug: string[] }> }) {
  const { slug } = await context.params;
  const filePath = path.join(appDir(), ...slug, "page.mdx");
  // Static params come from the filesystem walk above, but never follow
  // a path that escapes src/app.
  if (!filePath.startsWith(appDir() + path.sep)) {
    return new Response("Not found", { status: 404 });
  }
  try {
    const source = await readFile(filePath, "utf8");
    return new Response(mdxToCleanMarkdown(source) + "\n", {
      headers: { "Content-Type": "text/markdown; charset=utf-8" },
    });
  } catch {
    return new Response("Not found", { status: 404 });
  }
}
