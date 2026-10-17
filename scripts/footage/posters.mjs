// Turns the first frame of each clip (PNG) into the WebP stills the site shows before a video loads.
//   node scripts/footage/posters.mjs <png dir> <media dir>
import { createRequire } from 'node:module';
import { readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const [pngDir, mediaDir] = process.argv.slice(2).map((p) => resolve(p));
// sharp lives in the website's node_modules, wherever this script is run from.
const sharp = createRequire(fileURLToPath(new URL('../../website/package.json', import.meta.url)))('sharp');
for (const file of readdirSync(pngDir).filter((f) => f.endsWith('.png'))) {
  const name = file.replace('.png', '');
  for (const width of [2560, 1920]) {
    await sharp(`${pngDir}/${file}`).resize(width).webp({ quality: 90, smartSubsample: true, effort: 6 })
      .toFile(`${mediaDir}/${name}-${width}.webp`);
  }
}
