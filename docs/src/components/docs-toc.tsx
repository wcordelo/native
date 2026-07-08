"use client";

import { useEffect, useState } from "react";
import { usePathname } from "next/navigation";

type TocHeading = { id: string; text: string; level: 2 | 3 };

/**
 * The "On this page" rail: h2/h3 headings read from the rendered article,
 * so the list and the anchor ids can never disagree — HeadingLink stamps
 * the ids, and this component only reads them back out of the DOM.
 */
export function DocsToc() {
  const pathname = usePathname();
  const [headings, setHeadings] = useState<TocHeading[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);

  useEffect(() => {
    const article = document.querySelector("article");
    if (!article) {
      setHeadings([]);
      return;
    }
    const found: TocHeading[] = [];
    for (const el of article.querySelectorAll<HTMLHeadingElement>("h2[id], h3[id]")) {
      found.push({
        id: el.id,
        text: el.textContent ?? "",
        level: el.tagName === "H3" ? 3 : 2,
      });
    }
    setHeadings(found);
    setActiveId(found[0]?.id ?? null);
  }, [pathname]);

  useEffect(() => {
    if (headings.length === 0) return;

    function onScroll() {
      // Matches the root scroll-padding-top (5rem) with a little slack, so
      // the heading an anchor jump lands on is the one that lights up.
      const cutoff = 88;
      let current = headings[0].id;
      for (const heading of headings) {
        const el = document.getElementById(heading.id);
        if (el && el.getBoundingClientRect().top <= cutoff) current = heading.id;
      }
      setActiveId(current);
    }

    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, [headings]);

  if (headings.length === 0) return null;

  return (
    <nav aria-label="On this page">
      <p className="mb-2 label-12 font-medium uppercase tracking-wider text-gray-900">
        On this page
      </p>
      <ul className="space-y-0.5">
        {headings.map((heading) => (
          <li key={heading.id}>
            <a
              href={`#${heading.id}`}
              className={`block py-1 text-sm transition-colors ${
                heading.level === 3 ? "pl-3" : ""
              } ${
                activeId === heading.id
                  ? "font-medium text-gray-1000"
                  : "text-gray-900 hover:text-gray-1000"
              }`}
            >
              {heading.text}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  );
}
