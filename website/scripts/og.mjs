// Renders scripts/og.html and scripts/og-guide.html to public/og.png and public/og-guide.png (1200x630) with the system Chrome.
// Run: node scripts/og.mjs
import { chromium } from 'playwright-core';
import { fileURLToPath } from 'node:url';

const here = (path) => fileURLToPath(new URL(path, import.meta.url));
const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
for (const [source, target] of [['./og.html', '../public/og.png'], ['./og-guide.html', '../public/og-guide.png']]) {
  await page.goto('file://' + here(source));
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(300);
  await page.screenshot({ path: here(target) });
  console.log('wrote', target);
}
await browser.close();
