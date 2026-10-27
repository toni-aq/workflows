#!/usr/bin/env python3
"""Summarize what a Claude Code run's output tokens were spent on, from its session transcript.

Usage: out_breakdown.py [transcript.jsonl]   (default: newest *.jsonl under ~/.claude/projects)
Prints one compact JSON object. Never raises: on any problem prints {"error": "..."}.

Fields: messages (distinct assistant messages), output_tokens (sum of per-message usage), thinking_tokens (sum of
output_tokens_details.thinking_tokens when the CLI reports it, else null), text_chars (visible assistant text),
tool_input_chars by group (edit = Edit/Write/MultiEdit/NotebookEdit payloads, bash, other), tool_calls by tool name,
largest_message_tokens, and the five largest tool inputs (tool, chars).
"""
import glob, json, os, sys

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else None
    if not path:
        files = glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
        if not files:
            return {"error": "no transcript found"}
        path = max(files, key=os.path.getmtime)
    last_usage, text_chars, calls, groups, biggest = {}, 0, {}, {"edit": 0, "bash": 0, "other": 0}, []
    seen_blocks = set()
    with open(path) as fh:
        for line in fh:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") != "assistant":
                continue
            msg = o.get("message") or {}
            mid = msg.get("id") or o.get("uuid")
            if isinstance(msg.get("usage"), dict):
                last_usage[mid] = msg["usage"]          # one assistant message can be written as several lines; keep the last
            content = msg.get("content")
            for b in content if isinstance(content, list) else []:
                key = (mid, b.get("id") or b.get("type"), len(json.dumps(b, default=str)))
                if key in seen_blocks:
                    continue
                seen_blocks.add(key)
                if b.get("type") == "text":
                    text_chars += len(b.get("text", ""))
                elif b.get("type") == "tool_use":
                    name = b.get("name", "?")
                    n = len(json.dumps(b.get("input", {}), default=str))
                    calls[name] = calls.get(name, 0) + 1
                    g = "edit" if name in ("Edit", "Write", "MultiEdit", "NotebookEdit") else "bash" if name == "Bash" else "other"
                    groups[g] += n
                    biggest.append((n, name))
    out_tokens = sum(int(u.get("output_tokens") or 0) for u in last_usage.values())
    think = [u.get("output_tokens_details", {}).get("thinking_tokens") for u in last_usage.values() if isinstance(u.get("output_tokens_details"), dict)]
    biggest.sort(reverse=True)
    return {"messages": len(last_usage), "output_tokens": out_tokens,
            "thinking_tokens": sum(int(t or 0) for t in think) if think else None,
            "text_chars": text_chars, "tool_input_chars": groups, "tool_calls": calls,
            "largest_message_tokens": max((int(u.get("output_tokens") or 0) for u in last_usage.values()), default=0),
            "largest_tool_inputs": [{"tool": t, "chars": n} for n, t in biggest[:5]]}

if __name__ == "__main__":
    try:
        print(json.dumps(main(), separators=(",", ":")))
    except Exception as e:
        print(json.dumps({"error": type(e).__name__}))
