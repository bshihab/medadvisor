"""How much of the grading error is caused by WRONG SPEAKER LABELS?

Grading has been measured three times on the transcripts the app actually
produced -- speaker mislabels included. Across three recordings:

    Qwen 2.5-7B   38/48 criteria correct
    Qwen 3.5-4B   44/48

Separately, speaker-label accuracy on the same recordings came out 85.0% for the
7B and 98.3% for the 4B, and the 7B's mistakes were criterion-bearing doctor
lines handed to the patient -- "Is there anything else you wanted to raise
today?" (the what_else criterion), "What feels right to you?" (shared_plan).

So: is the grading error a JUDGMENT problem or a TRANSCRIPT problem?

This grades the same three consultations twice per model:

  AS-RECORDED  the transcript the app produced, mislabels and all
  PERFECT      the same words, every line attributed to the speaker who really
               said it (hand-aligned ground truth)

PERFECT is a ceiling, not a shippable configuration -- nothing can label speakers
flawlessly. Its value is diagnostic: the gap between the two columns is exactly
what better attribution could buy, and no more. If grading barely moves, the
errors are judgment and no transcription work will fix them.

Note the app's grading prompt already tries to defend against this
(Analysis.swift:76 tells the model to judge on content "anywhere in the
transcript -- NOT on the possibly-wrong speaker label"), so a small gap would
mean that instruction is doing its job.
"""
from pathlib import Path

import modal

BENCH = Path.home() / "bilal-dev/medadvisor-ane/tools/llm-benchmark"
RUBRIC = Path.home() / "bilal-dev/medadvisor-ane/rubrics/outpatient-clinic.json"
R = "/work"

app = modal.App("medadvisor-perfect-attr")

image = (
    modal.Image.from_registry("nvidia/cuda:12.8.1-devel-ubuntu24.04",
                              add_python="3.11")
    .apt_install("git", "build-essential", "cmake", "curl", "libcurl4-openssl-dev")
    .pip_install("requests", "huggingface_hub", "hf_transfer")
    .run_commands(
        "git clone --depth 1 https://github.com/ggml-org/llama.cpp /llama.cpp",
        "cmake -S /llama.cpp -B /llama.cpp/build -DGGML_CUDA=ON -DLLAMA_CURL=OFF "
        "-DCMAKE_CUDA_ARCHITECTURES=86 -DCMAKE_BUILD_TYPE=Release",
        "cmake --build /llama.cpp/build --config Release -j 8 --target llama-server",
        gpu="A10G",
    )
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1"})
    .add_local_file(str(BENCH / "app_scoring.py"), f"{R}/app_scoring.py")
    .add_local_file(str(BENCH / "test_speaker_split.py"), f"{R}/splitdata.py")
    .add_local_file(str(RUBRIC), f"{R}/rubric.json")
)

# Cache the GGUFs so repeat runs skip the ~7GB download.
hf_cache = modal.Volume.from_name("medadvisor-hf-cache", create_if_missing=True)

MODELS = [
    dict(key="7B", name="Qwen 2.5-7B (ships today)",
         repo="bartowski/Qwen2.5-7B-Instruct-GGUF",
         file="Qwen2.5-7B-Instruct-Q4_K_M.gguf",
         opening="<|im_start|>assistant\n"),
    dict(key="4B", name="Qwen 3.5-4B (the new one)",
         repo="bartowski/Qwen_Qwen3.5-4B-GGUF",
         file="Qwen_Qwen3.5-4B-Q4_K_M.gguf",
         opening="<|im_start|>assistant\n<think>\n\n</think>\n\n"),
]

# The transcripts the app produced, verbatim, as pasted from the device.
AS_RECORDED = {
"rushed": """Doctor: Come in, sit down.
Patient: I'm writing about half an hour behind, so on, speak quick.
Doctor: Back pain, is it?
Patient: Yes, my lower back. It started about 3 weeks ago.
Doctor: And three weeks, any numbness in the legs, any trouble passing water.
Patient: No, nothing like that, it's just fine. How bad, one to 10. About a 6. It's worse in the morning and sitting makes it right.
Doctor: Have you tried anything for it?
Patient: I'm proven. helps a little. Look, I'm quite worried, my father had spinal cancer, and I keep thinking, let me stop you there.
Doctor: I need to examine you. Shut up, bend forward. Does that hurt?
Patient: A bit. Sorry, I'm a bit emotional about all this.
Doctor: Okay. Straight leg, raise is negative. No focal neurology, likely mechanical, and ideology rather than radicular.
Patient: Sorry, what does that mean?
Doctor: It means it's mus- musculoskeletal. I'll put you on Nexoprin. That broke in, and refer you to physio, take, take it with food.
Patient: Okay.
Doctor: Do come back the same day if you get numbness between your legs.
Patient: Trouble with irritation or weakness, and either, like, those need looking at urgently. Right?
Doctor: Good, receptional, sort, your appointment, next patients waiting.""",
"good": """Doctor: Good morning, I'm Dr. Alice, one of the GPs here. Come in and take a seat.
Patient: Thank you.
Doctor: There's no rush at all. 20 minutes and the door is shut, so tell me, in your own words, what's been going on?
Patient: I've got this rash on my arms about 6 weeks now and it's driving me insane.
Doctor: Come on, tell me more.
Patient: I will interrupt. It's just worst at night. I tried a cream from the chemist, made no difference. It seems worse since I started a new job in a kitchen.
Doctor: That's really useful. When exactly did it start? How far has it spread and isn't sore as well as itchy? Start on my back?
Patient: My hands now up to my elbows sore. Where I've scratched it.
Doctor: And what's your own sense of what's causing it, anything you've been worried about?
Patient: I wondered if it's something I'm touching at work. I'm afraid I'll have to give up the job I've only started.
Doctor: That's a real worry, and I can hear how much your job matters to you. Let's take it seriously and see what we can do, giving it up is not where I'd start.
Patient: Thank you, that helps.
Doctor: I'd like to look at your arm and hands now. I just need you to roll your sleeves up. Tell me if anything I do is uncomfortable and I'll stop.
Patient: That's fine.
Doctor: Thank you, in plain terms, this looks like contact dermatitis, skin reacting to something. You're touching over and over and the kitchen fits that well. It isn't an infection and you can't pass it to anyone.
Patient: That's a relief.
Doctor: It usually settles once we work out what's causing it, and cut the contact down, so it can take a few weeks and it may flare again. I can't promise it'll clear completely without something changing at work.
Patient: Understood.
Doctor: Two options. We start a steroid ointment, plus... gloves and a barrier cream and a review in three weeks. Or I refer you for patch testing now. I just went over all the questions.""",
"headache": """Doctor: Like I said, have a seat. Make yourself comfortable. No rush. We. We have plenty of time, so tell me onwards what's brought you in today.
Patient: She has headaches nearly every day for a month now, and it's really getting to me.
Doctor: Go on, take your time.
Patient: Afternoons, mostly, like a light bat around my head. Parasitamo helps a bit worse after a long day off the computer.
Doctor: How bad do they get at their worst, and is there anything else that makes them better or worse?
Patient: 7 out of 10 maybe dark room helps. Coffee makes it worse.
Doctor: Is there anything else you wanted to raise today?
Patient: No, just headaches.
Doctor: And what do you think might be going on? Anything you've been worried it could be?
Patient: Honestly, I've been frightened. It's a tumor My mom had one. About my age. I've been lying awake over it.
Doctor: That sounds genuinely frightening, and with your mom's history. Of course, there, that's where your mind goes. I'm glad you told me. You did the right thing coming in and all work through this together.
Patient: Thank you.
Doctor: I'd like to examine you now. I'll check your blood pressure, then use a light to look at the back of your eye. It's spray, but it doesn't hurt. Say if anything is uncomfortable and I'll stop. Blood pressure is normal, and the backs of your eye look completely healthy in everyday terms. This looks like a tension type headache. The muscle across your scalp and neck tightening up and staying tight. So it's not serious.
Patient: That's a relief. Nothing. I've found today points that way.
Doctor: I won't promise you, certainly, though, if the pattern changes, I'd want to know.
Patient: That's a relief.
Doctor: Two reasonable options. We start with a simple thing, screen breaks, cutting the daily parasitamol, sorting your sleep. Or we arrange a scan for peace of mind. What feels right to you?
Patient: The simple things first. Good.
Doctor: I forget it all down for you, so you don't have to remember any of it.
Patient: Thanks.
Doctor: Let's put a review in the diary for 3 weeks.
Patient: Okay.
Doctor: Before you go, what questions do you have for me?
Patient: None, I don't think.
Doctor: Thanks for listening.""",
}

# Answer keys. "met" = the behaviour was genuinely demonstrated in the words
# spoken. Anything not listed as met is not-met. The `good` recording was cut
# short by a mis-press, so its closing criteria never happened.
TRUTH = {
"rushed": {"explore_complaint", "accurate_info", "safety_net"},
"good": {"intro_self", "set_tone", "open_questions", "explore_complaint",
         "avoid_interrupting", "explore_perspective", "respond_emotion",
         "support_respect", "explain_exam", "plain_language", "accurate_info"},
"headache": {"set_tone", "open_questions", "explore_complaint",
             "avoid_interrupting", "what_else", "explore_perspective",
             "respond_emotion", "support_respect", "explain_exam",
             "plain_language", "accurate_info", "shared_plan",
             "invite_questions"},
}


@app.function(image=image, gpu="A10G", timeout=3600,
              volumes={"/root/.cache/huggingface": hf_cache})
def run() -> dict:
    import json, subprocess, sys, time, requests
    sys.path.insert(0, R)
    from app_scoring import build_prompt, parse_criterion
    from splitdata import TRANSCRIPTS
    from huggingface_hub import hf_hub_download

    criteria = json.loads(Path(f"{R}/rubric.json").read_text())["criteria"]

    # PERFECT: same words, correct speaker on every line, consecutive same-speaker
    # fragments merged into turns exactly as SpeakerAttribution.turns would.
    perfect = {}
    for name, frags in TRANSCRIPTS.items():
        turns, cur, buf = [], None, []
        for spk, text in frags:
            if spk != cur and buf:
                turns.append(f"{'Doctor' if cur == 'D' else 'Patient'}: {' '.join(buf)}")
                buf = []
            cur = spk
            buf.append(text)
        if buf:
            turns.append(f"{'Doctor' if cur == 'D' else 'Patient'}: {' '.join(buf)}")
        perfect[name] = "\n".join(turns)

    out = {}
    for m in MODELS:
        gguf = hf_hub_download(m["repo"], m["file"])
        log = open("/tmp/s.log", "w+")
        srv = subprocess.Popen(
            ["/llama.cpp/build/bin/llama-server", "-m", gguf, "-c", "6144",
             "-ngl", "99", "--port", "8080", "--host", "127.0.0.1", "-t", "8"],
            stdout=log, stderr=subprocess.STDOUT)
        ready = False
        for _ in range(300):
            if srv.poll() is not None:
                break
            try:
                if requests.get("http://127.0.0.1:8080/health", timeout=2).status_code == 200:
                    ready = True
                    break
            except Exception:
                pass
            time.sleep(1)
        if not ready:
            srv.kill(); log.seek(0)
            raise RuntimeError(f"server failed for {m['name']}\n{log.read()[-1200:]}")

        for variant, texts in (("as-recorded", AS_RECORDED), ("perfect", perfect)):
            for name, transcript in texts.items():
                verdicts, flips = {}, []
                for c in criteria:
                    full = (f"<|im_start|>user\n{build_prompt(c, transcript)}"
                            f"<|im_end|>\n{m['opening']}")
                    raw = requests.post("http://127.0.0.1:8080/completion",
                                        timeout=240, json={
                        "prompt": full, "n_predict": 180, "temperature": 0,
                        "cache_prompt": True, "stop": ["<|im_end|>"]}
                    ).json().get("content", "")
                    v, _ = parse_criterion(raw, transcript)
                    verdicts[c["id"]] = v
                truth = TRUTH[name]
                correct = sum(1 for c in criteria
                              if (verdicts[c["id"]] == "met") == (c["id"] in truth))
                out[f"{m['key']}|{variant}|{name}"] = dict(
                    correct=correct, n=len(criteria),
                    met=sum(1 for v in verdicts.values() if v == "met"),
                    truth_met=len(truth),
                    over=[c["id"] for c in criteria
                          if verdicts[c["id"]] == "met" and c["id"] not in truth],
                    under=[c["id"] for c in criteria
                           if verdicts[c["id"]] != "met" and c["id"] in truth])
                print(f"[{m['key']} {variant:<11}] {name:<9} {correct}/{len(criteria)}",
                      flush=True)
        srv.kill()
    return out


@app.local_entrypoint()
def main():
    r = run.remote()
    names = ["rushed", "good", "headache"]
    L = ["=" * 78,
         "DOES FIXING SPEAKER LABELS FIX GRADING?",
         "=" * 78,
         "as-recorded = the transcript the app produced (mislabels included)",
         "perfect     = same words, every line correctly attributed (CEILING --",
         "              not shippable, nothing labels speakers flawlessly)", "",
         f"{'model':<5} {'variant':<12} {'transcript':<10} {'correct':>9} {'says met':>9} {'truth':>6} {'over':>5} {'under':>6}",
         "-" * 78]
    for k in ("7B", "4B"):
        for variant in ("as-recorded", "perfect"):
            tot = n = 0
            for nm in names:
                d = r.get(f"{k}|{variant}|{nm}")
                if not d:
                    continue
                L.append(f"{k:<5} {variant:<12} {nm:<10} {d['correct']:>4}/{d['n']:<4} "
                         f"{d['met']:>9} {d['truth_met']:>6} {len(d['over']):>5} {len(d['under']):>6}")
                tot += d["correct"]; n += d["n"]
            if n:
                L.append(f"{k:<5} {variant:<12} {'TOTAL':<10} {tot:>4}/{n:<4} "
                         f"{'':>9} {'':>6}   ({tot / n * 100:.0f}%)")
            L.append("")
    L += ["=" * 78, "WHAT PERFECT ATTRIBUTION CHANGED", "=" * 78]
    for k in ("7B", "4B"):
        for nm in names:
            a, b = r.get(f"{k}|as-recorded|{nm}"), r.get(f"{k}|perfect|{nm}")
            if not (a and b):
                continue
            fixed = (set(a["over"]) - set(b["over"])) | (set(a["under"]) - set(b["under"]))
            broke = (set(b["over"]) - set(a["over"])) | (set(b["under"]) - set(a["under"]))
            L.append(f"\n{k} / {nm}: {a['correct']}/16 -> {b['correct']}/16")
            if fixed:
                L.append(f"   fixed by correct labels: {', '.join(sorted(fixed))}")
            if broke:
                L.append(f"   newly wrong:             {', '.join(sorted(broke))}")
            if not fixed and not broke:
                L.append("   no change")
    text = "\n".join(L)
    (BENCH / "results" / "PERFECT-ATTRIBUTION.txt").write_text(text)
    print("\n" + text)
