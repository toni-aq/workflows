#!/usr/bin/env python3
"""Isolated runner path, finish job: write the model's output into a FRESH clone, treating the tar as untrusted data.

The tar comes from a job that ran a model over text anyone can post in Slack or Jira. Only plain files are accepted:
no links, devices or directories, no absolute or '..' paths, nothing outside --allow, nothing under .git, size and count
limits. Any violation stops everything and nothing is written (exit 3). Paths are resolved against the clone and
must stay inside it.

Usage: apply_output.py --tar FILE --repo DIR --allow REGEX --out-dir DIR
Writes files/<path> members to REPO/<path> and the results.json member to OUT_DIR/results.json.
Exit 0 ok (including an empty tar), 3 on a violation.
"""
import argparse, json, os, re, sys, tarfile

MAX_FILES, MAX_FILE_BYTES, MAX_RESULTS_BYTES = 200, 2_000_000, 1_000_000


def violation(msg):
    print(f"VIOLATION: {msg}. Nothing was applied.")
    sys.exit(3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tar", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--allow", required=True)
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    allow = re.compile(a.allow)
    repo_real = os.path.realpath(a.repo)
    with tarfile.open(a.tar, "r:") as t:
        members = t.getmembers()
        files, results = [], None
        for m in members:
            if not m.isreg():
                violation(f"{m.name!r} is not a regular file")
            name = m.name
            if name == "results.json":
                if m.size > MAX_RESULTS_BYTES:
                    violation("results.json is too large")
                results = m
                continue
            if not name.startswith("files/"):
                violation(f"unexpected member {name!r}")
            rel = name[len("files/"):]
            parts = rel.split("/")
            if not rel or rel.startswith("/") or any(p in ("", ".", "..") for p in parts) or ".git" in parts:
                violation(f"unsafe path {rel!r}")
            if not allow.search(rel):
                violation(f"{rel!r} is outside the allowed paths")
            if m.size > MAX_FILE_BYTES:
                violation(f"{rel!r} is too large")
            files.append((m, rel))
        if len(files) > MAX_FILES:
            violation("too many files")
        planned = []
        for m, rel in files:
            dest = os.path.realpath(os.path.join(a.repo, rel))
            if os.path.commonpath([repo_real, dest]) != repo_real:
                violation(f"{rel!r} resolves outside the clone")
            planned.append((m, dest, rel))
        data = None
        if results is not None:
            data = t.extractfile(results).read()
            try:
                json.loads(data)
            except Exception:
                violation("results.json is not valid JSON")
        for m, dest, rel in planned:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with t.extractfile(m) as src, open(dest, "wb") as out:
                out.write(src.read())
        if data is not None:
            os.makedirs(a.out_dir, exist_ok=True)
            with open(os.path.join(a.out_dir, "results.json"), "wb") as out:
                out.write(data)
    print(f"applied {len(files)} file(s)" + (", results.json" if results is not None else ", no results.json"))
    for m, rel in files:
        print(f"  {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
