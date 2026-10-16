#!/usr/bin/env python3
"""Builds a large synthetic folder of git repositories for measuring Lopper at scale.

    scripts/stress/build.py <output-folder> [--repos 200] [--branches 40] [--big 2] [--big-branches 5000]
                            [--worktrees 10] [--modules 3] [--module-files 60000]

Everything is created with real git (fast-import, so thousands of branches take seconds). The output is throwaway:
nothing here reads or writes your own repositories. Run `scripts/stress/measure.sh <output-folder>` afterwards.
The script refuses a non-empty output folder and never deletes anything.
"""
import argparse, os, subprocess, sys, time

def git(args, cwd, input=None):
    subprocess.run(["git"] + args, cwd=cwd, input=input, check=True, capture_output=True, text=True)

def fast_import(repo, branches, commits_per_branch, merged_ratio):
    """A main with 20 commits, then `branches` topic branches; every `merged_ratio`-th is merged into main."""
    lines = []
    mark = 0
    def commit(ref, message, parent_mark=None, merge_mark=None, ts=1_700_000_000):
        nonlocal mark
        mark += 1
        lines.append(f"commit {ref}\nmark :{mark}\ncommitter Stress <stress@lopper.invalid> {ts + mark} +0000\ndata {len(message)}\n{message}")
        if parent_mark: lines.append(f"from :{parent_mark}")
        if merge_mark: lines.append(f"merge :{merge_mark}")
        body = f"file {mark}\n"
        lines.append(f"M 100644 inline f{mark % 50}.txt\ndata {len(body)}\n{body}")
        return mark
    last = None
    for i in range(20):
        last = commit("refs/heads/main", f"main {i}", last)
    for b in range(branches):
        parent = last
        tip = None
        for c in range(commits_per_branch):
            tip = commit(f"refs/heads/topic/feature-{b}", f"b{b} c{c}", parent)
            parent = tip
        if b % merged_ratio == 0:
            last = commit("refs/heads/main", f"merge feature-{b}", last, merge_mark=tip)
    lines.append("")
    git(["fast-import", "--quiet"], repo, input="\n".join(lines) + "\n")

def make_repo(path, branches, commits, worktrees=0):
    os.makedirs(path, exist_ok=True)
    git(["init", "-q", "-b", "main"], path)
    git(["config", "user.email", "stress@lopper.invalid"], path)
    git(["config", "user.name", "Stress"], path)
    fast_import(path, branches, commits, merged_ratio=3)
    git(["reset", "-q", "--hard", "main"], path)
    for w in range(worktrees):
        git(["worktree", "add", "-q", f"{path}-wt{w}", f"topic/feature-{w * 3 + 1}"], path)

def make_modules(repo, files):
    with open(os.path.join(repo, ".gitignore"), "w") as f: f.write("node_modules\n")
    base = os.path.join(repo, "node_modules")
    per_dir = 200
    for d in range(files // per_dir):
        folder = os.path.join(base, f"pkg{d}", "lib")
        os.makedirs(folder, exist_ok=True)
        for i in range(per_dir):
            with open(os.path.join(folder, f"m{i}.js"), "w") as f: f.write("x" * 64)
    with open(os.path.join(repo, "package-lock.json"), "w") as f: f.write("{}")
    git(["add", ".gitignore", "package-lock.json"], repo)
    git(["commit", "-q", "-m", "lockfile"], repo)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("--repos", type=int, default=200)
    p.add_argument("--branches", type=int, default=40)
    p.add_argument("--big", type=int, default=2)
    p.add_argument("--big-branches", type=int, default=5000)
    p.add_argument("--worktrees", type=int, default=10)
    p.add_argument("--modules", type=int, default=3)
    p.add_argument("--module-files", type=int, default=60000)
    a = p.parse_args()
    if os.path.exists(a.out) and os.listdir(a.out):
        sys.exit(f"{a.out} is not empty; remove it yourself first (this script never deletes anything)")
    start = time.time()
    for r in range(a.repos):
        w = 5 if r < a.worktrees else 0
        make_repo(os.path.join(a.out, f"group{r % 10}", f"repo{r:03d}"), a.branches, 2, w)
    for r in range(a.big):
        make_repo(os.path.join(a.out, "big", f"huge{r}"), a.big_branches, 1)
    for m in range(a.modules):
        make_modules(os.path.join(a.out, f"group{m}", f"repo{m:03d}"), a.module_files)
    print(f"built {a.repos + a.big} repositories in {time.time() - start:.0f}s at {a.out}")

main()
