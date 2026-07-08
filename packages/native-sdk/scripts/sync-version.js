#!/usr/bin/env node

// One version number rules them all: packages/native-sdk/package.json is
// the source of truth, and this script stamps it into the CLI source
// (tools/native-sdk/main.zig), every per-platform binary package under
// npm/, and the main package's own optionalDependencies pins. The pins
// are exact so a given @native-sdk/cli always installs the binary built
// from the same commit.

import { readdirSync, readFileSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const repoRoot = join(projectRoot, '..', '..');

const packageJsonPath = join(projectRoot, 'package.json');
const packageJson = JSON.parse(readFileSync(packageJsonPath, 'utf-8'));
const version = packageJson.version;

console.log(`Syncing version ${version}...`);

// tools/native-sdk/main.zig
const mainZigPath = join(repoRoot, 'tools', 'native-sdk', 'main.zig');
let mainZig = readFileSync(mainZigPath, 'utf-8');

const versionPattern = /^const version = "[^"]*";/m;
const match = mainZig.match(versionPattern);

if (!match) {
  console.error('  Could not find `const version = "...";` in tools/native-sdk/main.zig');
  process.exit(1);
}

const newVersionLine = `const version = "${version}";`;

if (match[0] !== newVersionLine) {
  mainZig = mainZig.replace(versionPattern, newVersionLine);
  writeFileSync(mainZigPath, mainZig);
  console.log(`  Updated tools/native-sdk/main.zig: ${match[0]} -> ${newVersionLine}`);
} else {
  console.log(`  tools/native-sdk/main.zig already up to date`);
}

// npm/<platform>/package.json
const npmDir = join(projectRoot, 'npm');
for (const entry of readdirSync(npmDir, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;
  const platformJsonPath = join(npmDir, entry.name, 'package.json');
  const platformJson = JSON.parse(readFileSync(platformJsonPath, 'utf-8'));
  if (platformJson.version !== version) {
    platformJson.version = version;
    writeFileSync(platformJsonPath, JSON.stringify(platformJson, null, 2) + '\n');
    console.log(`  Updated npm/${entry.name}/package.json to ${version}`);
  } else {
    console.log(`  npm/${entry.name}/package.json already up to date`);
  }
}

// The main package's optionalDependencies pins.
let pinsChanged = false;
for (const name of Object.keys(packageJson.optionalDependencies ?? {})) {
  if (packageJson.optionalDependencies[name] !== version) {
    packageJson.optionalDependencies[name] = version;
    pinsChanged = true;
  }
}
if (pinsChanged) {
  writeFileSync(packageJsonPath, JSON.stringify(packageJson, null, 2) + '\n');
  console.log('  Updated optionalDependencies pins in package.json');
} else {
  console.log('  optionalDependencies pins already up to date');
}

console.log('Version sync complete.');
