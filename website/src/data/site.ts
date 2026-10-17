import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * The released version, read from the app's own project file so the site never disagrees with the app. The build runs
 * from the website folder, so that is tried first: the path relative to this file only works when the file is read from
 * source, not from the bundled output, which is where the old lookup silently fell back to 0.1.0.
 */
function readVersion(): string {
  const candidates = [
    resolve(process.cwd(), '../App/project.yml'),
    resolve(process.cwd(), 'App/project.yml'),
    fileURLToPath(new URL('../../../App/project.yml', import.meta.url)),
  ];
  for (const file of candidates) {
    try {
      const match = readFileSync(file, 'utf8').match(/MARKETING_VERSION:\s*(\S+)/);
      if (match?.[1]) return match[1];
    } catch {
      // try the next place
    }
  }
  throw new Error('Could not read MARKETING_VERSION from App/project.yml: the site would show the wrong version.');
}

export const version = readVersion();

const repo = 'https://github.com/Zawalid/Lopper';

export const links = {
  repo,
  releases: `${repo}/releases`,
  download: `${repo}/releases/latest/download/Lopper.dmg`,
  changelog: `${repo}/blob/main/CHANGELOG.md`,
  license: `${repo}/blob/main/LICENSE`,
  issues: `${repo}/issues`,
  install: `${repo}/blob/main/docs/install.md`,
  safety: `${repo}/blob/main/docs/safety.md`,
  cli: `${repo}/blob/main/docs/cli.md`,
  author: 'https://zawalid.com',
  github: 'https://github.com/Zawalid',
  x: 'https://x.com/Zawaalid',
};

export const site = {
  name: 'Lopper',
  url: 'https://lopper.zawalid.com',
  title: 'Lopper: keep your repositories light',
  description:
    'A native Mac app that finds the branches, worktrees and generated folders you no longer need, shows the git evidence that each is safe to remove, and lets you undo anything for 30 days.',
};
