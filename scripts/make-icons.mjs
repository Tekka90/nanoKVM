#!/usr/bin/env node
// Regenerates every AppIcon PNG from NanoKVM/Icon/AppIcon.svg.
// Needs `sharp`:  npm i --prefix /tmp/icons sharp  &&  NODE_PATH=/tmp/icons/node_modules node scripts/make-icons.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";

const require = createRequire(import.meta.url);
const sharp = require("sharp");
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(path.join(root, "NanoKVM/Icon/AppIcon.svg"), "utf8");
const out = path.join(root, "NanoKVM/NanoKVM/Assets.xcassets/AppIcon.appiconset");

const art = source.replace(/<svg[^>]*>/, "").replace(/<\/svg>\s*$/, "");
const CENTER = { x: 533, y: 497 }; // visual center of the artwork inside the 1024 canvas

const place = (scale) =>
  `<g transform="translate(512 512) scale(${scale}) translate(${-CENTER.x} ${-CENTER.y})">${art}</g>`;

const wrap = (body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">${body}</svg>`;

const paperRect = (attrs, fill) => `<rect ${attrs} fill="${fill}" filter="url(#paper)"/>`;

// iOS: full-bleed square, the system applies the mask.
const ios = (bg) => wrap(`${art.match(/<defs>.*?<\/defs>/s)[0]}${paperRect('width="1024" height="1024"', bg)}${place(0.93).replace(/<defs>.*?<\/defs>/s, "")}`);

// macOS: rounded square with margin and a soft shadow.
const mac = wrap(`${art.match(/<defs>.*?<\/defs>/s)[0]}
  <filter id="icon-shadow" x="-10%" y="-10%" width="120%" height="125%">
    <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.3"/>
  </filter>
  <g filter="url(#icon-shadow)">${paperRect('x="100" y="100" width="824" height="824" rx="185"', "#e8cb96")}</g>
  ${place(0.76).replace(/<defs>.*?<\/defs>/s, "")}`);

const render = (svg) => sharp(Buffer.from(svg), { density: 72 }).png();

const light = await render(ios("#e8cb96")).toBuffer();
await sharp(light).toFile(path.join(out, "ios.png"));
await render(ios("#0c151d")).toFile(path.join(out, "ios-dark.png"));
await sharp(await render(ios("#000000")).toBuffer())
  .greyscale().linear(1.25, 18).png().toFile(path.join(out, "ios-tinted.png"));

const macMaster = await render(mac).toBuffer();
for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
  await sharp(macMaster).resize(size, size, { kernel: "lanczos3" }).png().toFile(path.join(out, `mac-${size}.png`));
}
console.log("icons written to", out);
