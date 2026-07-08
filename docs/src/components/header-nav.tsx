"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const links = [
  { name: "Home", href: "/" },
  { name: "Docs", href: "/introduction" },
  { name: "Components", href: "/components" },
];

function isCurrent(href: string, pathname: string): boolean {
  if (href === "/") return pathname === "/";
  if (href === "/components") return pathname === "/components" || pathname.startsWith("/components/");
  // Docs owns every other docs page.
  return pathname !== "/" && !pathname.startsWith("/components");
}

export function HeaderNav() {
  const pathname = usePathname();

  return (
    <nav aria-label="Site" className="hidden md:flex items-center gap-4">
      {links.map(({ name, href }) => {
        const current = isCurrent(href, pathname);
        return (
          <Link
            key={href}
            href={href}
            aria-current={current ? "page" : undefined}
            className={`label-14 transition-colors ${
              current ? "text-gray-1000" : "text-gray-900 hover:text-gray-1000"
            }`}
          >
            {name}
          </Link>
        );
      })}
    </nav>
  );
}
