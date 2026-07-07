#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const root = process.argv[2] ? path.resolve(process.argv[2]) : process.cwd();
const htmlPath = path.join(root, "MediaLIB 系统页面.html");
const swiftPath = path.join(root, "Sources/MediaLib/Views/VividIconLibrary.swift");
const reportDir = path.join(root, "Build/TitleIconDebug");
const reportPath = path.join(reportDir, "title-icon-report.json");

function read(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (error) {
    console.error(`missing: ${path.relative(root, file)} (${error.message})`);
    process.exit(2);
  }
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

const html = read(htmlPath);
const swift = read(swiftPath);
const referenceCases = new Set([...html.matchAll(/case '([^']+)'/g)].map((match) => match[1]));

const swiftCases = new Set();
for (const match of swift.matchAll(/case\s+([^:\n]+):/g)) {
  for (const name of match[1].matchAll(/"([^"]+)"/g)) {
    swiftCases.add(name[1]);
  }
}

const mappings = [
  { scope: "video", token: "tv.library", titleIcon: "tv", evidence: ["tv.library", 'return "tv"'] },
  { scope: "video", token: "sparkles.tv", titleIcon: "anime", evidence: ["sparkles.tv", 'return "anime"'] },
  { scope: "video", token: "film", titleIcon: "movie", evidence: ['key == "film"', 'return "movie"'] },
  { scope: "video", token: "books.vertical", titleIcon: "docu", evidence: ["books.vertical", 'return "docu"'] },
  { scope: "video", token: "music.mic", titleIcon: "variety", evidence: ["music.mic", 'return "variety"'] },
  { scope: "video", token: "recording.library", titleIcon: "video_gal", evidence: ["recording.library", 'return "video_gal"'] },
  { scope: "video", token: "video", titleIcon: "video_other", evidence: ['key == "video"', 'return "video_other"'] },
  { scope: "music", token: "music.note", titleIcon: "song_note", evidence: ['key == "music.note"', 'return "song_note"'] },
  { scope: "music", token: "music.album", titleIcon: "disc", evidence: ["music.album", 'return "disc"'] },
  { scope: "music", token: "person.2", titleIcon: "artists", evidence: ["person.2", 'return "artists"'] },
  { scope: "music", token: "music.note.list", titleIcon: "playlist", evidence: ["music.note.list", 'return "playlist"'] },
  { scope: "music", token: "music.recent", titleIcon: "clock", evidence: ["music.recent", 'return "clock"'] },
  { scope: "photo", token: "photo.on.rectangle", titleIcon: "photo_all", evidence: ["photo.on.rectangle", 'return "photo_all"'] },
  { scope: "photo", token: "photo", titleIcon: "photo", evidence: ['key == "photo"', 'return "photo"'] },
  { scope: "system", token: "externaldrive", titleIcon: "sources", evidence: ["externaldrive", 'return "sources"'] },
  { scope: "system", token: "dashboard", titleIcon: "dashboard", evidence: ["dashboard", 'return "dashboard"'] },
  { scope: "system", token: "gear", titleIcon: "gear", evidence: ["gear", 'return "gear"'] },
  { scope: "system", token: "lock", titleIcon: "vault", custom: true, evidence: ["lock", 'return "vault"'] }
];

const rows = mappings.map((item) => {
  const htmlCase = item.custom ? true : referenceCases.has(item.titleIcon);
  const swiftCase = swiftCases.has(item.titleIcon);
  const mapperEvidence = item.evidence.every((needle) => swift.includes(needle));
  return {
    scope: item.scope,
    token: item.token,
    titleIcon: item.titleIcon,
    source: item.custom ? "swift-custom" : "html",
    htmlCase,
    swiftCase,
    mapperEvidence,
    ok: htmlCase && swiftCase && mapperEvidence
  };
});

const legacyPageFallback = /VividSemanticPageGlyph|VividSemanticPageIconKind/.test(
  swift.slice(swift.indexOf("struct VividPageIcon"), swift.indexOf("private enum VividTitleIconNameMapper"))
);

const report = {
  generatedAt: new Date().toISOString(),
  referenceCaseCount: referenceCases.size,
  checkedCount: rows.length,
  legacyPageFallback,
  rows
};

fs.mkdirSync(reportDir, { recursive: true });
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

const status = rows.every((row) => row.ok) && !legacyPageFallback;
console.log(`Title icon debug report: ${path.relative(root, reportPath)}`);
console.log(`Reference cases found: ${referenceCases.size}`);
console.log("");
for (const row of rows) {
  const mark = row.ok ? "OK " : "BAD";
  console.log(`${mark} ${row.scope.padEnd(6)} ${row.token.padEnd(20)} -> ${row.titleIcon.padEnd(12)} html=${row.htmlCase} swift=${row.swiftCase} mapper=${row.mapperEvidence}`);
}
if (legacyPageFallback) {
  console.log("BAD VividPageIcon still references legacy semantic page glyphs in the page-header path.");
}

process.exit(status ? 0 : 1);
