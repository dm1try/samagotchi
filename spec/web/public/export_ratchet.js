import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

function codeOnly(source) {
  const chars = [...source];
  let state = "code";
  let quote = null;
  for (let i = 0; i < chars.length; i += 1) {
    const char = chars[i];
    const next = chars[i + 1];
    if (state === "line-comment") {
      if (char === "\n") state = "code";
      else chars[i] = " ";
    } else if (state === "block-comment") {
      if (char === "*" && next === "/") {
        chars[i] = " ";
        chars[i + 1] = " ";
        i += 1;
        state = "code";
      } else if (char !== "\n") {
        chars[i] = " ";
      }
    } else if (state === "string") {
      if (char === "\\") {
        chars[i] = " ";
        if (next !== undefined) {
          if (next !== "\n") chars[i + 1] = " ";
          i += 1;
        }
      } else if (char === quote) {
        chars[i] = " ";
        state = "code";
      } else if (char !== "\n") {
        chars[i] = " ";
      }
    } else if (char === "/" && next === "/") {
      chars[i] = " ";
      chars[i + 1] = " ";
      i += 1;
      state = "line-comment";
    } else if (char === "/" && next === "*") {
      chars[i] = " ";
      chars[i + 1] = " ";
      i += 1;
      state = "block-comment";
    } else if (char === "'" || char === "\"" || char === "`") {
      quote = char;
      chars[i] = " ";
      state = "string";
    }
  }
  return chars.join("");
}

function identifier(text) {
  return /^[A-Za-z_$][\w$]*$/.test(text);
}

export function parseExports(source, file = "(module)") {
  const code = codeOnly(source);
  const names = new Set();
  for (const match of code.matchAll(/\bexport\b/g)) {
    const tail = code.slice(match.index + match[0].length);
    const trimmed = tail.trimStart();
    if (trimmed.startsWith("*")) {
      throw new Error(`${file}: export * is not supported by the export ratchet`);
    }
    if (trimmed.startsWith("{")) {
      const end = trimmed.indexOf("}");
      if (end < 0) throw new Error(`${file}: unterminated export list`);
      const list = trimmed.slice(1, end).trim();
      if (!list) continue;
      for (const entry of list.split(",")) {
        const parts = entry.trim().split(/\s+as\s+/);
        const exported = parts.at(-1);
        if (parts.length > 2 || parts.some((part) => !identifier(part)) || !identifier(exported)) {
          throw new Error(`${file}: unsupported export list entry ${entry.trim()}`);
        }
        names.add(exported);
      }
      continue;
    }
    const declaration = trimmed.match(/^(?:(async)\s+)?(function|class|const|let|default)\b/);
    if (!declaration) throw new Error(`${file}: unsupported export syntax`);
    const [, async, kind] = declaration;
    if (kind === "default" || kind === "let") {
      throw new Error(`${file}: export ${kind} is not supported by the export ratchet`);
    }
    if (async && kind !== "function") {
      throw new Error(`${file}: unsupported export async ${kind}`);
    }
    const name = trimmed.slice(declaration[0].length).match(/^\s*([A-Za-z_$][\w$]*)/);
    if (!name) throw new Error(`${file}: unsupported export ${kind} declaration`);
    names.add(name[1]);
  }
  return [...names].sort();
}

export function newExports(sources, baseline, allowed = []) {
  for (const entry of allowed) {
    if (!entry.file || !entry.name || !entry.reason || entry.reason.includes("\n")) {
      throw new Error("Every allowed export needs a file, name, and one-line reason");
    }
  }
  const allowlisted = new Set(allowed.map(({ file, name }) => `${file}\0${name}`));
  return Object.entries(sources).flatMap(([file, source]) => {
    if (!Object.hasOwn(baseline, file)) return [];
    return parseExports(source, file)
      .filter((name) => !baseline[file].includes(name) && !allowlisted.has(`${file}\0${name}`))
      .map((name) => ({ file, name }));
  });
}

export function formatViolations(violations) {
  return violations.map(({ file, name }) =>
    `${file}: new export ${name}; put it in a new module (see docs/internals/web-frontend.md, "New exports go in new modules").`
  ).join("\n");
}

async function javascriptFiles(directory, relative = "") {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const child = path.join(directory, entry.name);
    const childRelative = path.posix.join(relative, entry.name);
    if (entry.isDirectory()) {
      if (childRelative !== "vendor") files.push(...await javascriptFiles(child, childRelative));
    } else if (entry.isFile() && entry.name.endsWith(".js")) {
      files.push([childRelative, child]);
    }
  }
  return files;
}

export async function moduleSources(publicRoot) {
  const files = await javascriptFiles(publicRoot);
  return Object.fromEntries(await Promise.all(files.map(async ([file, absolute]) => [file, await readFile(absolute, "utf8")])));
}

export async function writeExportsBaseline(root) {
  const publicRoot = path.join(root, "lib/samagotchi/web/public");
  const baselinePath = path.join(root, "spec/web/public/exports_baseline.json");
  const sources = await moduleSources(publicRoot);
  const baseline = Object.fromEntries(Object.keys(sources).sort().map((file) => [file, parseExports(sources[file], file)]));
  await writeFile(baselinePath, `${JSON.stringify(baseline, null, 2)}\n`);
}
