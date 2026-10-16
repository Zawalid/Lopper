// Renders scripts/dmg/background.html at 1x and 2x and combines them into scripts/dmg/background.tiff, the multi-resolution
// image Finder uses as the installer window background. Commit the tiff.
// usage: node scripts/dmg/render-background.mjs
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(path.join(root, "website/package.json"));
const { chromium } = require("playwright-core");

const out = path.join(root, "build/dmg");
mkdirSync(out, { recursive: true });
const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
for (const [scale, name] of [[1, "background.png"], [2, "background@2x.png"]]) {
  const page = await browser.newPage({ viewport: { width: 660, height: 420 }, deviceScaleFactor: scale });
  await page.goto(pathToFileURL(path.join(root, "scripts/dmg/background.html")).href);
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: path.join(out, name), clip: { x: 0, y: 0, width: 660, height: 420 } });
  await page.close();
}
await browser.close();
execFileSync("sips", ["-s", "dpiWidth", "144", "-s", "dpiHeight", "144", path.join(out, "background@2x.png")], { stdio: "ignore" });
execFileSync("tiffutil", ["-cathidpicheck", path.join(out, "background.png"), path.join(out, "background@2x.png"),
  "-out", path.join(root, "scripts/dmg/background.tiff")]);
console.log("wrote scripts/dmg/background.tiff");
