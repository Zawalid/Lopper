import type { APIRoute } from 'astro';
import { site, links } from '../data/site';
import { guides, guidePath } from '../data/guides';

const entry = (path: string, lastmod: string) =>
  `  <url>\n    <loc>${new URL(path, site.url).toString()}</loc>\n    <lastmod>${lastmod}</lastmod>\n  </url>`;

/** Every public page. The pages are known at build time, so this stays a plain list with no integration to maintain. */
export const GET: APIRoute = () => {
  const urls = [
    entry('/', site.updated),
    entry(links.guides, guides.map((g) => g.updated).sort().at(-1) ?? site.updated),
    ...guides.map((g) => entry(guidePath(g.slug), g.updated)),
  ];
  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join('\n')}\n</urlset>\n`;
  return new Response(xml, { headers: { 'Content-Type': 'application/xml; charset=utf-8' } });
};
