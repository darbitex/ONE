#!/usr/bin/env python3
"""Run ONE v0.3.2 R1 audit submission against an LLM API endpoint."""
import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path

AUDIT_FILE = Path("/home/rera/one/supra/audit/AUDIT_R1_SUBMISSION.md")


UA = "Mozilla/5.0 (X11; Linux x86_64) audit-client/1.0"


def _gemini_model(prompt_text: str, model: str) -> str:
    key = os.environ["GEMINI_API_KEY"]
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
    body = {
        "contents": [{"parts": [{"text": prompt_text}]}],
        "generationConfig": {"maxOutputTokens": 16384, "temperature": 0.2},
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        data = json.loads(resp.read())
    parts = data["candidates"][0]["content"]["parts"]
    return "\n".join(p.get("text", "") for p in parts)


def call_gemini_pro(prompt_text: str) -> str:
    return _gemini_model(prompt_text, "gemini-2.5-pro")


def call_gemini_flash(prompt_text: str) -> str:
    return _gemini_model(prompt_text, "gemini-2.5-flash")


def call_cerebras(prompt_text: str) -> str:
    key = os.environ["CEREBRAS_API_KEY"]
    url = "https://api.cerebras.ai/v1/chat/completions"
    body = {
        "model": "qwen-3-235b-a22b-instruct-2507",
        "messages": [{"role": "user", "content": prompt_text}],
        "max_tokens": 16384,
        "temperature": 0.2,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}",
            "User-Agent": UA,
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        data = json.loads(resp.read())
    return data["choices"][0]["message"]["content"]


def call_groq(prompt_text: str) -> str:
    key = os.environ["GROQ_API_KEY"]
    url = "https://api.groq.com/openai/v1/chat/completions"
    body = {
        "model": "qwen/qwen3-32b",
        "messages": [{"role": "user", "content": prompt_text}],
        "max_tokens": 16384,
        "temperature": 0.2,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}",
            "User-Agent": UA,
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        data = json.loads(resp.read())
    return data["choices"][0]["message"]["content"]


PROVIDERS = {
    "gemini": call_gemini_pro,
    "gemini-pro": call_gemini_pro,
    "gemini-flash": call_gemini_flash,
    "cerebras": call_cerebras,
    "groq": call_groq,
}


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: run_api_audit.py <gemini|cerebras> <output_path>", file=sys.stderr)
        return 2
    provider, out = sys.argv[1], Path(sys.argv[2])
    if provider not in PROVIDERS:
        print(f"unknown provider {provider}", file=sys.stderr)
        return 2
    prompt = AUDIT_FILE.read_text()
    try:
        reply = PROVIDERS[provider](prompt)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        out.write_text(f"[HTTP {e.code}] {e.reason}\n\n{detail}")
        return 1
    out.write_text(reply)
    return 0


if __name__ == "__main__":
    sys.exit(main())
