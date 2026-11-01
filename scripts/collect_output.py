#!/usr/bin/env python3
"""Isolated runner path, step 3 (still in the model job, no secrets): pack what the model produced into one tar.

Packs, from the cloned repo, every added or modified regular file whose path matches --allow, plus the model's
results.json. Everything else the model changed is listed in dropped.txt and left behind. The finish job validates the
tar again and writes the files into a fresh clone, so this script is a convenience, not a trust boundary.

Usage: collect_output.py --repo DIR --out-dir DIR --allow REGEX --dest DIR
Writes DEST/model-output.tar and DEST/dropped.txt. Never raises: on a problem it writes an empty tar and says why.
"""
import argparse, io, json, os, re, subprocess, sys, tarfile

MAX_FILES, MAX_FILE_BYTES, MAX_RESULTS_BYTES = 200, 2_000_000, 1_000_000


def changed_files(repo):
    r = subprocess.run(["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "status", "--porcelain=v1", "-z",
                        "--untracked-files=all"], cwd=repo, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError("git status failed: " + r.stderr.strip()[:200])
    out, entries = [], r.stdout.split("\0")
    i = 0
    while i < len(entries):
        e = entries[i]
        i += 1
        if len(e) < 4:
            continue
        code, path = e[:2], e[3:]
        if "R" in code or "C" in code:   # the next entry is the original path
            i += 1
        out.append((code, path))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--allow", required=True)
    ap.add_argument("--dest", required=True)
    a = ap.parse_args()
    allow = re.compile(a.allow)
    os.makedirs(a.dest, exist_ok=True)
    kept, dropped, notes = [], [], []
    try:
        for code, path in changed_files(a.repo):
            full = os.path.join(a.repo, path)
            if "D" in code:
                dropped.append(f"{path} (deleted; deletions are not applied)")
            elif not allow.search(path) or ".." in path.split("/") or path.startswith("/") or "/.git/" in "/" + path:
                dropped.append(f"{path} (outside the allowed paths)")
            elif os.path.islink(full) or not os.path.isfile(full):
                dropped.append(f"{path} (not a regular file)")
            elif os.path.getsize(full) > MAX_FILE_BYTES:
                dropped.append(f"{path} (over {MAX_FILE_BYTES} bytes)")
            elif len(kept) >= MAX_FILES:
                dropped.append(f"{path} (more than {MAX_FILES} files)")
            else:
                kept.append(path)
    except Exception as e:
        notes.append(f"could not list changes: {type(e).__name__}: {e}")
    results = os.path.join(a.out_dir, "results.json")
    results_ok = False
    if os.path.isfile(results) and not os.path.islink(results):
        try:
            if os.path.getsize(results) > MAX_RESULTS_BYTES:
                raise ValueError("over the size limit")
            json.load(open(results))
            results_ok = True
        except Exception as e:
            notes.append(f"results.json not packed: {e}")
    else:
        notes.append("results.json not found")
    tar_path = os.path.join(a.dest, "model-output.tar")
    with tarfile.open(tar_path, "w") as t:
        for path in kept:
            t.add(os.path.join(a.repo, path), arcname="files/" + path, recursive=False)
        if results_ok:
            t.add(results, arcname="results.json", recursive=False)
    with open(os.path.join(a.dest, "dropped.txt"), "w") as f:
        f.write("\n".join(dropped + notes) + ("\n" if dropped or notes else ""))
    print(f"packed {len(kept)} file(s)" + (", results.json" if results_ok else ", no results.json")
          + (f"; left behind: {len(dropped)}" if dropped else "") + ("; " + "; ".join(notes) if notes else ""))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:   # bookkeeping must never fail the job
        print(f"collect failed: {type(e).__name__}: {e}")
        sys.exit(0)
