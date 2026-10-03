#!/usr/bin/env node
// Generates catalog.json from <id>/SKILL.md and validates each against
// schema/skill.schema.json. Exits non-zero on any validation error.
import { readdirSync, readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const skillsDir = root;
const nonSkillDirs = new Set(["schema", "scripts"]);
const schema = JSON.parse(readFileSync(join(root, "schema", "skill.schema.json"), "utf8"));

let ok = true;
const fail = (msg) => { console.error(`✗ ${msg}`); ok = false; };

// Splits a SKILL.md into frontmatter fields and body (matches the app's parser).
function parseFrontmatter(text) {
  const lines = text.split("\n");
  if (lines[0]?.trim() !== "---") return { fields: {}, body: text };
  const fields = {};
  let i = 1;
  for (; i < lines.length && lines[i].trim() !== "---"; i++) {
    const c = lines[i].indexOf(":");
    if (c === -1) continue;
    const key = lines[i].slice(0, c).trim();
    let val = lines[i].slice(c + 1).trim();
    if (val.length >= 2 && val.startsWith('"') && val.endsWith('"')) val = val.slice(1, -1);
    if (key) fields[key] = val;
  }
  return { fields, body: lines.slice(i + 1).join("\n").trim() };
}

function validate(id, fields) {
  for (const key of schema.required ?? []) {
    if (!fields[key] || String(fields[key]).trim() === "") fail(`${id}: frontmatter missing "${key}"`);
  }
  for (const [key, spec] of Object.entries(schema.properties ?? {})) {
    const v = fields[key];
    if (v == null) continue;
    if (spec.type === "string" && typeof v !== "string") fail(`${id}: "${key}" must be a string`);
    if (spec.maxLength && String(v).length > spec.maxLength) fail(`${id}: "${key}" exceeds ${spec.maxLength} chars`);
  }
}

const ids = existsSync(skillsDir)
  ? readdirSync(skillsDir).filter((d) => !nonSkillDirs.has(d) && statSync(join(skillsDir, d)).isDirectory()).sort()
  : [];

const entries = [];
for (const id of ids) {
  const md = join(skillsDir, id, "SKILL.md");
  if (!existsSync(md)) { fail(`${id}: missing SKILL.md`); continue; }
  const text = readFileSync(md, "utf8");
  const { fields } = parseFrontmatter(text);
  validate(id, fields);
  if (!fields.name || !fields.description) continue;
  const sha = createHash("sha256").update(text).digest("hex").slice(0, 12);
  entries.push({ id, name: fields.name, description: fields.description, sha, path: `${id}/SKILL.md` });
}

writeFileSync(join(root, "catalog.json"), JSON.stringify(entries, null, 2) + "\n");
console.log(`Wrote catalog.json (${entries.length} skill${entries.length === 1 ? "" : "s"}).`);
if (!ok) process.exit(1);
