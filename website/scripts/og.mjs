// Renders scripts/og.html to public/og.png (1200x630) with the system Chrome. Run: node scripts/og.mjs
import { chromium } from 'playwright-core';
import { fileURLToPath } from 'node:url';

const here = (path) => fileURLToPath(new URL(path, import.meta.url));
const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await page.goto('file://' + here('./og.html'));
await page.evaluate(() => document.fonts.ready);
await page.waitForTimeout(300);
await page.screenshot({ path: here('../public/og.png') });
await browser.close();
console.log('wrote public/og.png');
