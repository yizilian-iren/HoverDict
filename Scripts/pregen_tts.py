#!/usr/bin/env python3
"""
Pre-generate anime-voice clips for HoverDict.

The app (TTSPlayer.swift) only ever reads .wav files from the cache dir; it never
talks to a TTS model. This script is what fills that cache. Run it whenever the
GPT-SoVITS API server is up — it is the ONLY time the model needs to be running:

    1. Start GPT-SoVITS:  python api_v2.py   (defaults to 127.0.0.1:9880)
    2. Edit the CONFIG block below (point REF_AUDIO at your moe reference clip)
    3. python3 Scripts/pregen_tts.py

It does two things each run:
    * generates clips for the top-N most common English words (downloaded once), and
    * drains _wanted.txt — the words you actually hovered that had no clip yet.

Already-generated words are skipped, so it is safe to stop and re-run (resumable).
"""

import json
import os
import sys
import urllib.parse
import urllib.request

# ── CONFIG ──────────────────────────────────────────────────────────────────
# Point these at YOUR running GPT-SoVITS server and reference voice.
SERVER      = "http://127.0.0.1:9880"      # GPT-SoVITS api_v2.py address
REF_AUDIO   = "/absolute/path/to/ref.wav"  # 5–10s clean clip of the voice you want
PROMPT_TEXT = "参考音频里说的那句话原文"        # the exact words spoken in ref.wav
PROMPT_LANG = "ja"                          # language of ref.wav (日配=ja, 中=zh, 英=en)
TEXT_LANG   = "en"                          # language of the words we synthesize

TOP_N       = 10000                         # how many common words to pre-generate
# ────────────────────────────────────────────────────────────────────────────

# Cache dir + wanted list — MUST match TTSPlayer.swift.
CACHE_DIR = os.path.expanduser(
    "~/Library/Application Support/HoverDict/tts"
)
WANTED_FILE = os.path.join(CACHE_DIR, "_wanted.txt")

# A well-known top-10000 English frequency list (no profanity), cached next to script.
WORDLIST_URL = (
    "https://raw.githubusercontent.com/first20hours/"
    "google-10000-english/master/google-10000-english-no-swears.txt"
)
WORDLIST_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "wordlist_top10000.txt")


def normalize(word: str) -> str:
    """Cache filename stem. MUST stay in sync with TTSPlayer.key(for:)."""
    return word.strip().lower().replace("/", "_").replace(":", "_")


def load_wordlist() -> list[str]:
    if not os.path.exists(WORDLIST_FILE):
        print(f"↓ downloading word list → {WORDLIST_FILE}")
        urllib.request.urlretrieve(WORDLIST_URL, WORDLIST_FILE)
    with open(WORDLIST_FILE, encoding="utf-8") as f:
        words = [ln.strip() for ln in f if ln.strip()]
    return words[:TOP_N]


def load_wanted() -> list[str]:
    if not os.path.exists(WANTED_FILE):
        return []
    with open(WANTED_FILE, encoding="utf-8") as f:
        return [ln.strip() for ln in f if ln.strip()]


def synth(word: str) -> bytes:
    """Request one clip from GPT-SoVITS; returns wav bytes or raises."""
    payload = json.dumps({
        "text": word,
        "text_lang": TEXT_LANG,
        "ref_audio_path": REF_AUDIO,
        "prompt_text": PROMPT_TEXT,
        "prompt_lang": PROMPT_LANG,
        "media_type": "wav",
        "streaming_mode": False,
        "text_split_method": "cut0",   # single word — don't split
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{SERVER}/tts", data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        ctype = resp.headers.get("Content-Type", "")
        data = resp.read()
        if "audio" not in ctype:
            raise RuntimeError(f"server returned {ctype}: {data[:200]!r}")
        return data


def main() -> int:
    if not os.path.exists(REF_AUDIO):
        print(f"✗ REF_AUDIO not found: {REF_AUDIO}\n"
              f"  Edit the CONFIG block in this script first.", file=sys.stderr)
        return 1
    os.makedirs(CACHE_DIR, exist_ok=True)

    # Build the work set: wanted words first (you've actually seen them), then the
    # common-word list. Dedup by normalized key, preserving order.
    seen, work = set(), []
    for w in load_wanted() + load_wordlist():
        k = normalize(w)
        if k and k not in seen:
            seen.add(k)
            work.append((w, k))

    total = len(work)
    done = skipped = failed = 0
    failures = []
    print(f"≈ {total} words queued → {CACHE_DIR}")

    for i, (word, key) in enumerate(work, 1):
        out = os.path.join(CACHE_DIR, key + ".wav")
        if os.path.exists(out):
            skipped += 1
            continue
        try:
            wav = synth(word)
            with open(out, "wb") as f:
                f.write(wav)
            done += 1
        except Exception as e:  # noqa: BLE001 — keep going, report at end
            failed += 1
            failures.append(key)
            print(f"  ✗ [{i}/{total}] {word}: {e}", file=sys.stderr)
        if i % 50 == 0 or i == total:
            print(f"  … {i}/{total}  (new={done} skip={skipped} fail={failed})")

    # Rewrite _wanted.txt to keep only words that STILL have no clip (i.e. failed),
    # so the file shrinks to just the unresolved backlog.
    remaining = [k for k in load_wanted() if not os.path.exists(
        os.path.join(CACHE_DIR, normalize(k) + ".wav"))]
    if remaining:
        with open(WANTED_FILE, "w", encoding="utf-8") as f:
            f.write("\n".join(sorted(set(remaining))) + "\n")
    elif os.path.exists(WANTED_FILE):
        os.remove(WANTED_FILE)

    print(f"\n✓ done — generated {done}, skipped {skipped}, failed {failed}")
    if failures:
        print(f"  failed words remain in _wanted.txt; re-run to retry.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
