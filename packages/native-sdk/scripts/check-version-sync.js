#!/usr/bin/env node

// Verify every version stamped by sync-version.js matches
// packages/native-sdk/package.json: the CLI source, the per-platform
// binary packages, and the optionalDependencies pins. CI runs this before
// publish so a half-bumped release cannot ship.

import { readdirSync, readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const repoRoot = join(projectRoot, '..', '..');

const packageJson = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf-8'));
const expectedVersion = packageJson.version;

let errors = 0;

const mainZigPath = join(repoRoot, 'tools', 'native-sdk', 'main.zig');
const mainZig = readFileSync(mainZigPath, 'utf-8');

const versionMatch = mainZig.match(/^const version = "([^"]*)";/m);

if (!versionMatch) {
  console.error('Could not find `const version = "...";` in tools/native-sdk/main.zig');
  process.exit(1);
}

if (versionMatch[1] !== expectedVersion) {
  console.error(`Version mismatch: package.json=${expectedVersion}, tools/native-sdk/main.zig=${versionMatch[1]}`);
  errors++;
}

const npmDir = join(projectRoot, 'npm');
for (const entry of readdirSync(npmDir, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;
  const platformJson = JSON.parse(readFileSync(join(npmDir, entry.name, 'package.json'), 'utf-8'));
  if (platformJson.version !== expectedVersion) {
    console.error(`Version mismatch: package.json=${expectedVersion}, npm/${entry.name}/package.json=${platformJson.version}`);
    errors++;
  }
  const expectedName = `@native-sdk/cli-${entry.name}`;
  if (platformJson.name !== expectedName) {
    console.error(`Name mismatch: npm/${entry.name}/package.json is ${platformJson.name}, expected ${expectedName}`);
    errors++;
  }
  if (!(expectedName in (packageJson.optionalDependencies ?? {}))) {
    console.error(`Missing optionalDependencies pin for ${expectedName} in package.json`);
    errors++;
  }
}

for (const [name, pin] of Object.entries(packageJson.optionalDependencies ?? {})) {
  if (pin !== expectedVersion) {
    console.error(`Version mismatch: optionalDependencies["${name}"]=${pin}, expected ${expectedVersion}`);
    errors++;
  }
}

if (errors > 0) {
  console.error(`\nRun "npm run version:sync" in packages/native-sdk to fix.`);
  process.exit(1);
}

console.log(`Versions in sync: ${expectedVersion}`);
