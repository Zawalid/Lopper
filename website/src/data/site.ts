import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/** The released version, read from the app's own project file so the site never disagrees with the app. */
function readVersion(): string {
  try {
    const file = fileURLToPath(new URL('../../../App/project.yml', import.meta.url));
    const match = readFileSync(file, 'utf8').match(/MARKETING_VERSION:\s*(\S+)/);
    return match?.[1] ?? '0.1.0';
  } catch {
    return '0.1.0';
  }
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
