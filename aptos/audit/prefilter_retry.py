#!/usr/bin/env python3
"""Retry failed models with staggered requests to avoid 429s."""
import json, os, sys, time
import urllib.request, urllib.error
from pathlib import Path

API_KEY = os.environ["OPENROUTER_API_KEY"]
ROOT = Path("/home/rera/one/aptos")
AUDIT_DOC = ROOT / "audit/AUDIT_R1_SUBMISSION.md"
SOURCE = ROOT / "sources/ONE.move"
OUT_DIR = ROOT / "audit"

# Retry failed + add a few alternatives
MODELS = [
    ("qwen-coder",   "qwen/qwen3-coder:free"),
    ("gemma-31",     "google/gemma-4-31b-it:free"),
    ("hermes-405",   "nousresearch/hermes-3-llama-3.1-405b:free"),
    ("glm-air",      "z-ai/glm-4.5-air:free"),
    ("minimax",      "minimax/minimax-m2.5:free"),
    # Alternatives if retry fails
    ("qwen-next",    "qwen/qwen3-next-80b-a3b-instruct:free"),
    ("ling",         "inclusionai/ling-2.6-flash:free"),
    ("llama-70",     "meta-llama/llama-3.3-70b-instruct:free"),
]

PROMPT_HEADER = """You are an independent security auditor. Review the Move stablecoin contract below.

Your audit is a PRE-FILTER pass — identify bugs, logic errors, oracle edge cases, and capability management issues BEFORE the formal multi-LLM audit round. Be adversarial, skeptical, terse.

OUTPUT FORMAT (strict):
- One structured finding per bug, with: Severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), Location (file:line or function), Issue, Impact, Recommendation, Confidence.
- End with one-line verdict: GREEN / NEEDS-FIX / NOT-READY.
- If no findings, say so explicitly. Do not pad.

====== AUDIT REQUEST DOC ======
"""

def load_prompt():
    return PROMPT_HEADER + AUDIT_DOC.read_text() + "\n\n====== SOURCE ======\n```move\n" + SOURCE.read_text() + "\n```\n"

def call_one(slug: str, model: str, prompt: str, attempt: int = 1) -> tuple[int, str]:
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 8192,
        "temperature": 0.2,
    }).encode()
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=body,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/darbitex/ONE",
            "X-Title": "ONE Aptos prefilter audit",
        },
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=240) as resp:
            data = json.loads(resp.read())
        content = data.get("choices",[{}])[0].get("message",{}).get("content","(empty)")
        usage = data.get("usage",{})
        return 0, content + f"\n\n---\ntokens: in={usage.get('prompt_tokens','?')} out={usage.get('completion_tokens','?')} dt={time.time()-t0:.1f}s"
    except urllib.error.HTTPError as e:
        return e.code, f"[HTTP {e.code}] {e.read().decode(errors='replace')[:400]}"
    except Exception as e:
        return -1, f"ERROR: {e}"

def main():
    prompt = load_prompt()
    print(f"prompt size: {len(prompt)} chars")
    print(f"retrying {len(MODELS)} models staggered (15s gap)...")
    print()

    for i, (slug, model) in enumerate(MODELS):
        # Skip if we already have a good result for this slug
        dest = OUT_DIR / f"prefilter_{slug}.md"
        if dest.exists():
            existing = dest.read_text()
            if not existing.startswith("# " + slug) or "[HTTP " in existing[:500] or "ERROR:" in existing[:500]:
                pass  # retry
            else:
                print(f"  [skip] {slug} already OK")
                continue

        if i > 0:
            time.sleep(15)  # stagger
        code, out = call_one(slug, model, prompt)
        status = "OK" if code == 0 else f"FAIL({code})"
        is_empty = code == 0 and "(empty)" in out[:20]
        if is_empty:
            status = "EMPTY"
        print(f"  [{status:<10}] {slug} ({model})")
        dest.write_text(f"# {slug}  — {model}\n\n{out}\n")

if __name__ == "__main__":
    main()
