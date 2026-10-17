export interface Guide {
  slug: string;
  title: string;
  /** The <title>, under 60 characters. */
  metaTitle: string;
  description: string;
  published: string;
  updated: string;
}

/** Every guide, newest first. The sitemap, the index and the home page links read from here. */
export const guides: Guide[] = [
  {
    slug: 'clean-up-claude-code-worktrees',
    title: 'how to clean up Claude Code worktrees safely',
    metaTitle: 'How to clean up Claude Code worktrees safely',
    description:
      'Where Claude Code keeps its worktrees, what it removes itself, and how to clean up the rest with git without losing work. With real output.',
    published: '2026-10-17',
    updated: '2026-10-17',
  },
  {
    slug: 'cannot-delete-branch-used-by-worktree',
    title: 'git says it cannot delete a branch used by a worktree',
    metaTitle: 'Git: cannot delete branch used by worktree (how to fix it)',
    description:
      'What "cannot delete branch used by worktree" means, how to check nothing is lost, and the safe order to remove it. With real git output.',
    published: '2026-10-17',
    updated: '2026-10-17',
  },
];

export const guidePath = (slug: string) => `/guides/${slug}/`;
