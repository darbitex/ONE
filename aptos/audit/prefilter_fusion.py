#!/usr/bin/env python3
"""Pre-filter audit fusion: send audit doc + source to N OpenRouter models in parallel.
Collect individual responses to audit/prefilter_<slug>.md for review.
"""
import json, os, sys, time
import urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

API_KEY = os.environ.get("OPENROUTER_API_KEY")
if not API_KEY:
    print("OPENROUTER_API_KEY env required"); sys.exit(1)

ROOT = Path("/home/rera/one/aptos")
AUDIT_DOC = ROOT / "audit/AUDIT_R1_SUBMISSION.md"
SOURCE = ROOT / "sources/ONE.move"
OUT_DIR = ROOT / "audit"

MODELS = [
    ("qwen-coder",   "qwen/qwen3-coder:free"),
    ("nemotron-120", "nvidia/nemotron-3-super-120b-a12b:free"),
    ("hy3",          "tencent/hy3-preview:free"),
    ("glm-air",      "z-ai/glm-4.5-air:free"),
    ("gemma-31",     "google/gemma-4-31b-it:free"),
    ("minimax",      "minimax/minimax-m2.5:free"),
    ("gpt-oss",      "openai/gpt-oss-120b:free"),
    ("hermes-405",   "nousresearch/hermes-3-llama-3.1-405b:free"),
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
    audit = AUDIT_DOC.read_text()
    src = SOURCE.read_text()
    return PROMPT_HEADER + audit + "\n\n====== SOURCE ======\n```move\n" + src + "\n```\n"

def call_model(slug: str, model: str, prompt: str) -> tuple[str, str, int, str]:
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
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read())
        content = data.get("choices",[{}])[0].get("message",{}).get("content","(empty)")
        usage = data.get("usage",{})
        summary = f"tokens: in={usage.get('prompt_tokens','?')} out={usage.get('completion_tokens','?')} dt={time.time()-t0:.1f}s"
        return slug, model, 0, content + "\n\n---\n" + summary
    except urllib.error.HTTPError as e:
        return slug, model, e.code, f"[HTTP {e.code}] {e.read().decode(errors='replace')[:500]}"
    except Exception as e:
        return slug, model, -1, f"ERROR: {e}"

def main():
    prompt = load_prompt()
    print(f"prompt size: {len(prompt)} chars (~{len(prompt)//4} tokens est)")
    print(f"querying {len(MODELS)} models in parallel...")
    print()

    results = {}
    with ThreadPoolExecutor(max_workers=len(MODELS)) as ex:
        futs = {ex.submit(call_model, s, m, prompt): (s, m) for (s, m) in MODELS}
        for f in as_completed(futs):
            slug, model, code, out = f.result()
            status = "OK" if code == 0 else f"FAIL({code})"
            print(f"  [{status}] {slug:<14} ({model})")
            results[slug] = (model, code, out)

    # Save each to file
    for slug, (model, code, out) in results.items():
        dest = OUT_DIR / f"prefilter_{slug}.md"
        dest.write_text(f"# {slug}  — {model}\n\n{out}\n")
        print(f"  saved → {dest}")

    # Summary line
    ok = sum(1 for (_,c,_) in results.values() if c == 0)
    print(f"\nsummary: {ok}/{len(MODELS)} OK")

if __name__ == "__main__":
    main()
