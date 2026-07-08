"use client";

import { Fragment, useRef, useState } from "react";
import { npmCli } from "@/lib/site";

// The hero install block: a two-tab audience toggle above one pill-shaped
// command line. Humans install the CLI; agents add the skill.
const tabs = [
  { id: "humans", label: "For humans", command: `npm install -g ${npmCli}` },
  { id: "agents", label: "For agents", command: "npx skills add vercel-labs/native" },
] as const;

type TabId = (typeof tabs)[number]["id"];

export function InstallToggle() {
  const [active, setActive] = useState<TabId>("humans");
  const [copied, setCopied] = useState(false);
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([]);

  const activeTab = tabs.find((tab) => tab.id === active) ?? tabs[0];

  function select(index: number) {
    setActive(tabs[index].id);
    setCopied(false);
    tabRefs.current[index]?.focus();
  }

  function onKeyDown(event: React.KeyboardEvent, index: number) {
    if (event.key === "ArrowRight" || event.key === "ArrowDown") {
      event.preventDefault();
      select((index + 1) % tabs.length);
    } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
      event.preventDefault();
      select((index - 1 + tabs.length) % tabs.length);
    }
  }

  async function copy() {
    try {
      await navigator.clipboard.writeText(activeTab.command);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard unavailable (permissions, insecure context): do nothing.
    }
  }

  return (
    <div>
      <div
        role="tablist"
        aria-label="Install command"
        className="flex items-center justify-center gap-3"
      >
        {tabs.map((tab, index) => (
          <Fragment key={tab.id}>
            {index > 0 && <span aria-hidden className="h-3.5 w-px bg-gray-alpha-400" />}
            <button
              ref={(el) => {
                tabRefs.current[index] = el;
              }}
              role="tab"
              id={`install-tab-${tab.id}`}
              aria-selected={active === tab.id}
              aria-controls="install-command"
              onClick={() => {
                setActive(tab.id);
                setCopied(false);
              }}
              onKeyDown={(event) => onKeyDown(event, index)}
              className={`label-14 transition-colors ${
                active === tab.id ? "text-gray-1000" : "text-gray-700 hover:text-gray-1000"
              }`}
            >
              {tab.label}
            </button>
          </Fragment>
        ))}
      </div>
      <div
        role="tabpanel"
        id="install-command"
        aria-labelledby={`install-tab-${active}`}
        className="mt-3 flex items-center justify-between gap-3 rounded-full border border-gray-alpha-400 bg-background-100/70 py-2 pl-5 pr-2 backdrop-blur-sm"
      >
        <pre className="overflow-x-auto font-mono text-[13px] leading-6 text-gray-1000">
          <span className="select-none text-gray-700">$ </span>
          {activeTab.command}
        </pre>
        <button
          onClick={copy}
          aria-label={copied ? "Copied" : "Copy Command"}
          className="shrink-0 rounded-full p-2 text-gray-900 transition-colors hover:bg-gray-alpha-100 hover:text-gray-1000"
        >
          {copied ? (
            <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
              <path d="M2.5 8.5l3.5 3.5 7.5-8" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          ) : (
            <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
              <rect x="5.5" y="5.5" width="8" height="8" rx="1.5" />
              <path d="M10.5 5.5v-2a1.5 1.5 0 00-1.5-1.5H4a1.5 1.5 0 00-1.5 1.5V9A1.5 1.5 0 004 10.5h2" />
            </svg>
          )}
        </button>
      </div>
    </div>
  );
}
