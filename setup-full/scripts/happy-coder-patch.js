#!/usr/bin/env node
//
// happy-coder cc-mirror patch
// ============================
// Patches happy-coder's claude_version_utils.cjs so it discovers
// the mclaude cc-mirror launcher before looking for vanilla Claude Code.
//
// Usage:
//   node happy-coder-patch.js [path-to-claude_version_utils.cjs]
//
// If no path is given, it looks in the default npm-global location.

const fs = require('fs');
const path = require('path');
const os = require('os');

const defaultPath = path.join(
  os.homedir(), '.npm-global', 'lib', 'node_modules',
  'happy-coder', 'scripts', 'claude_version_utils.cjs'
);

const filePath = process.argv[2] || defaultPath;

if (!fs.existsSync(filePath)) {
  console.error(`File not found: ${filePath}`);
  console.error('Is happy-coder installed? Run: npm install -g happy-coder');
  process.exit(1);
}

let content = fs.readFileSync(filePath, 'utf8');

if (content.includes('findCcMirrorCliPath')) {
  console.log('claude_version_utils.cjs already patched - no changes needed.');
} else {
  // 1. Add the findCcMirrorCliPath function before findGlobalClaudeCliPath
  const ccMirrorFunction = `
/**
 * Find path to cc-mirror variant (mclaude)
 * @returns {string|null} Path to mclaude or null if not found
 */
function findCcMirrorCliPath() {
    const homeDir = os.homedir();
    const mclaudePath = path.join(homeDir, '.local', 'bin', 'mclaude');
    if (fs.existsSync(mclaudePath)) {
        return mclaudePath;
    }
    return null;
}

`;

  const insertPoint = content.indexOf('function findGlobalClaudeCliPath()');
  if (insertPoint === -1) {
    console.error('Could not find findGlobalClaudeCliPath function - happy-coder version may be incompatible.');
    process.exit(1);
  }

  content = content.slice(0, insertPoint) + ccMirrorFunction + content.slice(insertPoint);

  // 2. Make findGlobalClaudeCliPath check cc-mirror first
  const oldFunctionStart = 'function findGlobalClaudeCliPath() {';
  const newFunctionStart = `function findGlobalClaudeCliPath() {
    // Check for cc-mirror variant first (WSL setup preference)
    const ccMirrorPath = findCcMirrorCliPath();
    if (ccMirrorPath) return { path: ccMirrorPath, source: 'cc-mirror (mclaude)' };
`;
  content = content.replace(oldFunctionStart, newFunctionStart);

  // 3. Export the new function
  const exportsMatch = content.match(/module\.exports\s*=\s*\{([^}]+)\}/);
  if (exportsMatch && !exportsMatch[1].includes('findCcMirrorCliPath')) {
    const oldExports = exportsMatch[0];
    const newExports = oldExports.replace(
      /findNativeInstallerCliPath,/,
      'findNativeInstallerCliPath,\n    findCcMirrorCliPath,'
    );
    content = content.replace(oldExports, newExports);
  }

  fs.writeFileSync(filePath, content);
  console.log('claude_version_utils.cjs patch applied successfully.');
}

// ============================
// Patch happy.mjs to set CLAUDE_CONFIG_DIR for cc-mirror
// ============================

const happyMjsPath = path.join(path.dirname(filePath), '..', 'bin', 'happy.mjs');

if (!fs.existsSync(happyMjsPath)) {
  console.error(`happy.mjs not found at: ${happyMjsPath}`);
  console.error('Skipping CLAUDE_CONFIG_DIR patch.');
} else {
  let happyContent = fs.readFileSync(happyMjsPath, 'utf8');

  if (happyContent.includes('cc-mirror')) {
    console.log('happy.mjs already patched - no changes needed.');
  } else {
    const importAnchor = "import { join, dirname } from 'path';";
    if (!happyContent.includes(importAnchor)) {
      console.error('Could not find import anchor in happy.mjs - version may be incompatible.');
      process.exit(1);
    }

    const patch = `import { join, dirname } from 'path';
import { homedir } from 'os';
import { existsSync } from 'fs';

// cc-mirror: Set CLAUDE_CONFIG_DIR so happy-coder finds mclaude session files
if (!process.env.CLAUDE_CONFIG_DIR) {
  const ccMirrorConfig = join(homedir(), '.cc-mirror', 'mclaude', 'config');
  if (existsSync(ccMirrorConfig)) {
    process.env.CLAUDE_CONFIG_DIR = ccMirrorConfig;
  }
}`;

    happyContent = happyContent.replace(importAnchor, patch);
    fs.writeFileSync(happyMjsPath, happyContent);
    console.log('happy.mjs CLAUDE_CONFIG_DIR patch applied successfully.');
  }
}
