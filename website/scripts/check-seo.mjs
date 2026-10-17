// Checks the basics of every page of the built site: one h1, sensible title and description, a correct canonical, valid
// structured data, alt text, working internal links, a share image that loads, robots.txt and the sitemap.
//   npm run build && npx astro preview --port 4321 &   then   node scripts/check-seo.mjs [http://localhost:4321]
import { chromium } from 'playwright-core';

const base = (process.argv[2] ?? 'http://localhost:4321').replace(/\/$/, '');
const problems = [];
const note = (page, message) => problems.push(`${page}: ${message}`);

const sitemap = await (await fetch(`${base}/sitemap.xml`)).text();
const robots = await (await fetch(`${base}/robots.txt`)).text();
if (!/Sitemap:\s*https:\/\/lopper\.zawalid\.com\/sitemap\.xml/.test(robots)) note('robots.txt', 'does not point at the sitemap');
const pages = [...sitemap.matchAll(/<loc>https:\/\/lopper\.zawalid\.com(\/[^<]*)<\/loc>/g)].map((m) => m[1]);
if (pages.length < 3) note('sitemap.xml', `lists only ${pages.length} pages`);

const browser = await chromium.launch({ channel: 'chrome' });
const seenLinks = new Set();
for (const path of pages) {
  const page = await browser.newPage();
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text().slice(0, 120)); });
  page.on('pageerror', (e) => errors.push(String(e).slice(0, 120)));
  const response = await page.goto(base + path, { waitUntil: 'networkidle' });
  if (response?.status() !== 200) note(path, `status ${response?.status()}`);
  const info = await page.evaluate(() => ({
    title: document.title,
    description: document.querySelector('meta[name="description"]')?.content ?? '',
    canonical: document.querySelector('link[rel="canonical"]')?.href ?? '',
    h1: [...document.querySelectorAll('h1')].map((h) => h.textContent.trim()),
    og: document.querySelector('meta[property="og:image"]')?.content ?? '',
    robots: document.querySelector('meta[name="robots"]')?.content ?? '',
    noAlt: [...document.querySelectorAll('img:not([alt])')].length,
    jsonld: [...document.querySelectorAll('script[type="application/ld+json"]')].map((s) => s.textContent),
    links: [...document.querySelectorAll('a[href]')].map((a) => a.getAttribute('href')).filter((h) => h.startsWith('/') && !h.startsWith('//')),
  }));
  if (info.title.length < 15 || info.title.length > 60) note(path, `title is ${info.title.length} characters: "${info.title}"`);
  if (info.description.length < 80 || info.description.length > 165) note(path, `description is ${info.description.length} characters`);
  if (info.canonical !== 'https://lopper.zawalid.com' + path) note(path, `canonical is ${info.canonical}`);
  if (info.h1.length !== 1) note(path, `has ${info.h1.length} h1 elements`);
  if (!/index/.test(info.robots)) note(path, `robots meta is "${info.robots}"`);
  if (info.noAlt) note(path, `${info.noAlt} images without an alt attribute`);
  for (const text of info.jsonld) { try { JSON.parse(text); } catch { note(path, 'structured data does not parse'); } }
  if (!info.jsonld.length) note(path, 'no structured data');
  const image = await fetch(info.og.replace('https://lopper.zawalid.com', base));
  if (!image.ok) note(path, `share image ${info.og} answers ${image.status}`);
  for (const link of info.links) seenLinks.add(link.split('#')[0] || '/');
  if (errors.length) note(path, `console errors: ${errors.join(' | ')}`);
  console.log(`${path}  title(${info.title.length}) description(${info.description.length}) h1="${info.h1[0]}"`);
  await page.close();
}
for (const link of seenLinks) {
  const response = await fetch(base + link, { redirect: 'follow' });
  if (!response.ok) note(link, `internal link answers ${response.status}`);
}
const missing = await fetch(`${base}/this-page-does-not-exist/`);
if (missing.status !== 404) note('404', `an unknown address answers ${missing.status}`);
await browser.close();

if (problems.length) {
  console.log(`\n${problems.length} problem(s):`);
  for (const p of problems) console.log(' - ' + p);
  process.exit(1);
}
console.log(`\nOK: ${pages.length} pages and ${seenLinks.size} internal links checked.`);
