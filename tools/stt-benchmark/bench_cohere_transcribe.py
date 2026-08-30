#!/usr/bin/env python3
"""Cohere Transcribe WER benchmark over the same n=30 gold set as the other
engines. Mirrors the Apple leg: one pass per clip, raw transcripts written to
results/cohere_transcribe_raw.json ({id: text}, the apple_raw.json shape) and
scored rows to results/cohere_transcribe.json. WER and length buckets are the
ones from bench_stt.py, so the numbers are directly comparable.

Runs locally on this Mac (MPS, CPU fallback) via the engine-scoped venv — see
requirements-cohere-transcribe.txt. The timing it prints is Mac-side only and
says nothing about iPhone throughput: the app's iPhone stack cannot run this
model at all (see README).

  ./.venv-transcribe/bin/python bench_cohere_transcribe.py --limit 1   # smoke test: prints hyp vs ref
  ./.venv-transcribe/bin/python bench_cohere_transcribe.py             # full run, writes results/
"""
import argparse, json, platform, statistics, subprocess, sys, time
from pathlib import Path

from bench_stt import wer, bucket
from engines import CohereTranscribeEngine

HERE = Path(__file__).parent
DATA = HERE / "data"
RESULTS = HERE / "results"
BUCKETS = ["short (<=10 turns)", "medium (11-24)", "long (25+)"]


def audio_seconds(wav: str) -> float:
    import soundfile as sf
    info = sf.info(wav)
    return info.frames / info.samplerate


def chip() -> str:
    try:
        return subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                              capture_output=True, text=True).stdout.strip() or platform.machine()
    except Exception:
        return platform.machine()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="auto", choices=["auto", "mps", "cpu"])
    ap.add_argument("--limit", type=int, default=0, help="only the first N clips (smoke test; results not written)")
    ap.add_argument("--ids", default="", help="comma-separated clip ids to run (smoke test; results not written)")
    ap.add_argument("--show-text", action="store_true",
                    help="print each hypothesis next to its reference (default when --limit/--ids is used)")
    ap.add_argument("--no-warmup", action="store_true",
                    help="skip the untimed warm-up pass on the first clip")
    args = ap.parse_args()

    dataset = json.loads((DATA / "dataset.json").read_text())
    smoke = bool(args.limit or args.ids)
    if args.ids:
        keep = set(args.ids.split(","))
        dataset = [c for c in dataset if c["id"] in keep]
    if args.limit:
        dataset = dataset[:args.limit]
    if not dataset:
        print("No clips selected.")
        return 1
    show = args.show_text or smoke

    eng = CohereTranscribeEngine(device=args.device)
    if not eng.available:
        print("torch/transformers not importable — run this with the engine venv "
              "(see requirements-cohere-transcribe.txt).")
        return 1

    t0 = time.time()
    eng.load()
    print(f"Loaded {eng.repo} (rev {eng.commit}) on {eng.device}/{eng.dtype} in {time.time() - t0:.0f}s")

    first_wav = str(DATA / "audio" / f"{dataset[0]['id']}.wav")
    if not args.no_warmup:
        t0 = time.time()
        eng.transcribe(first_wav)
        print(f"Warm-up pass on {dataset[0]['id']}: {time.time() - t0:.1f}s (untimed below)")

    rows, raw = [], {}
    print(f"\n=== {eng.name} ===")
    for i, conv in enumerate(dataset, 1):
        wav = str(DATA / "audio" / f"{conv['id']}.wav")
        secs = audio_seconds(wav)
        ti = time.time()
        try:
            hyp = eng.transcribe(wav)
        except Exception as ex:
            print(f"  [{i:>3}/{len(dataset)}] {conv['id']} FAILED: {ex}")
            continue
        dt = time.time() - ti
        score = wer(conv["flat"], hyp)
        print(f"  [{i:>3}/{len(dataset)}] {conv['id']}: WER={score * 100:5.1f}%  "
              f"({dt:5.1f}s for {secs:4.0f}s audio = {secs / dt:4.1f}x realtime, {eng.device})")
        if show:
            print(f"      REF: {conv['flat'].strip()}")
            print(f"      HYP: {hyp}")
        rows.append({"id": conv["id"], "wer": score, "n_turns": conv["n_turns"],
                     "bucket": bucket(conv["n_turns"]), "seconds": round(dt, 2),
                     "audio_seconds": round(secs, 2), "device": eng.device})
        raw[conv["id"]] = hyp

    if not rows:
        print("No clips transcribed.")
        return 1

    print_summary(rows, eng, smoke)

    if smoke:
        print("\n(smoke test — results not written)")
        return 0
    RESULTS.mkdir(exist_ok=True)
    meta = {"engine": eng.name, "repo": eng.repo, "revision": eng.commit,
            "device": eng.device, "dtype": eng.dtype, "chip": chip(),
            "macos": platform.mac_ver()[0], "python": platform.python_version(),
            "measured": time.strftime("%Y-%m-%d")}
    try:
        import torch, transformers
        meta.update(torch=torch.__version__, transformers=transformers.__version__)
    except Exception:
        pass
    (RESULTS / "cohere_transcribe.json").write_text(json.dumps({"meta": meta, "rows": rows}, indent=2))
    (RESULTS / "cohere_transcribe_raw.json").write_text(json.dumps(raw, indent=2, sort_keys=True))
    print("Results written to results/cohere_transcribe.json and results/cohere_transcribe_raw.json")
    return 0


def print_summary(rows, eng, smoke):
    wers = [r["wer"] for r in rows]
    overall = sum(wers) / len(wers)
    print("\n===== COHERE TRANSCRIBE WER (lower is better) =====")
    print(f"  overall: {overall * 100:.1f}%  (n={len(rows)})")
    for b in BUCKETS:
        br = [r["wer"] for r in rows if r["bucket"] == b]
        if br:
            print(f"  {b:<22} {sum(br) / len(br) * 100:.1f}%")
    if len(wers) > 1:
        print(f"  median {statistics.median(wers) * 100:.1f}% · stdev {statistics.stdev(wers) * 100:.1f}% · "
              f"range {min(wers) * 100:.1f}–{max(wers) * 100:.1f}%")
    print("  per clip: " + ", ".join(f"{r['wer'] * 100:.1f}" for r in rows))

    audio = sum(r["audio_seconds"] for r in rows)
    wall = sum(r["seconds"] for r in rows)
    per = [r["seconds"] for r in rows]
    print(f"\n  Throughput — Mac-side ({chip()}, {eng.device}/{eng.dtype}), NOT iPhone:")
    print(f"  {audio / 60:.1f} min of audio in {wall:.0f}s ≈ {audio / wall:.1f}x realtime; "
          f"per clip median {statistics.median(per):.1f}s (range {min(per):.1f}–{max(per):.1f}s)")
    if smoke:
        print("  (n is too small for the bucket numbers to mean anything)")


if __name__ == "__main__":
    sys.exit(main())
