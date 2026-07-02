#!/usr/bin/env python3
"""Generate N doctor-patient conversations (ground truth) + synthesize audio.

Writes:
  data/dataset.json   list of {id, turns:[{speaker,text}], flat, n_turns}
  data/audio/<id>.wav 16kHz mono WAV synthesized with macOS `say`

We author the transcripts, so the ground truth is exact.
"""
import argparse, json, os, random, subprocess
from pathlib import Path

HERE = Path(__file__).parent
DATA = HERE / "data"
AUDIO = DATA / "audio"

# Phrase pools (kept clinical but generic — no real PHI).
OPENINGS_D = [
    "Good morning, I'm Doctor Lee.",
    "Hello, come on in and take a seat.",
    "Hi there, I'm one of the doctors on the team today.",
    "Morning. Can I confirm your name and date of birth?",
]
CONCERNS_D = [
    "What's brought you in to see me today?",
    "Tell me a bit about what's been going on.",
    "So what seems to be the problem?",
    "How can I help you today?",
]
SYMPTOMS_P = [
    "I've had a headache for about two weeks now.",
    "I've been getting chest pains when I climb the stairs.",
    "My knee has been really swollen since the weekend.",
    "I've had a cough that just won't go away.",
    "I've been feeling really tired and run down lately.",
    "I keep getting these dizzy spells in the afternoon.",
]
PROBES_D = [
    "Can you tell me more about when it started?",
    "Does anything make it better or worse?",
    "Have you noticed any other symptoms alongside it?",
    "On a scale of one to ten, how bad is the pain?",
    "Have you had anything like this before?",
]
ANSWERS_P = [
    "It's mostly in the mornings, and it's worse when I'm tired.",
    "No, nothing really seems to change it.",
    "Now that you mention it, I have been a bit nauseous too.",
    "I'd say about a six, but sometimes it spikes higher.",
    "No, this is the first time it's happened.",
    "It comes and goes, but it's been more frequent this week.",
]
EMPATHY_D = [
    "I'm sorry to hear that, it sounds really frustrating.",
    "That must be worrying for you.",
    "Thank you for explaining that so clearly.",
    "I can see this has been on your mind.",
]
PLAN_D = [
    "Based on what you've told me, this is most likely tension-related.",
    "I'd like to run a couple of simple tests to be sure.",
    "Let's start with some basic bloods and check your blood pressure.",
    "I think we should try some lifestyle changes first and review in two weeks.",
]
SAFETY_D = [
    "If it gets much worse, or you get any new symptoms, come back straight away.",
    "If you notice any chest pain or shortness of breath, call for help immediately.",
    "Otherwise, let's review this in two weeks.",
]
CLOSING_P = [
    "Okay, that makes sense. Thank you, doctor.",
    "Alright, I'll do that. Thanks for your help.",
    "Got it. Thank you.",
]
CLOSING_D = [
    "You're very welcome. Take care.",
    "Great, see you in two weeks.",
    "Look after yourself.",
]


def make_conversation(rng: random.Random):
    """One varied conversation, length ~ 6..40 turns, alternating with some
    occasional same-speaker follow-ups."""
    turns = []
    turns.append(("Doctor", rng.choice(OPENINGS_D)))
    turns.append(("Doctor", rng.choice(CONCERNS_D)))
    turns.append(("Patient", rng.choice(SYMPTOMS_P)))

    rounds = rng.randint(1, 12)  # history-taking back-and-forth
    for _ in range(rounds):
        turns.append(("Doctor", rng.choice(PROBES_D)))
        turns.append(("Patient", rng.choice(ANSWERS_P)))
        if rng.random() < 0.25:  # occasional short patient add-on (same speaker)
            turns.append(("Patient", rng.choice(["It's really been bothering me.",
                                                  "I forgot to mention that.",
                                                  "That's about it, I think."])))

    if rng.random() < 0.8:
        turns.append(("Doctor", rng.choice(EMPATHY_D)))
    turns.append(("Doctor", rng.choice(PLAN_D)))
    if rng.random() < 0.8:
        turns.append(("Doctor", rng.choice(SAFETY_D)))
    turns.append(("Patient", rng.choice(CLOSING_P)))
    turns.append(("Doctor", rng.choice(CLOSING_D)))

    return [{"speaker": s, "text": t} for s, t in turns]


def synthesize(text: str, wav_path: Path, voice: str):
    """macOS `say` → 16kHz mono WAV (no ffmpeg needed to write)."""
    subprocess.run(
        ["say", "-v", voice, "--file-format=WAVE",
         "--data-format=LEI16@16000", "-o", str(wav_path), text],
        check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--voice", default="Alex", help="macOS `say` voice for audio")
    ap.add_argument("--no-audio", action="store_true", help="skip WAV synthesis")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    AUDIO.mkdir(parents=True, exist_ok=True)

    dataset = []
    for i in range(args.n):
        sid = f"conv{i:03d}"
        turns = make_conversation(rng)
        flat = " ".join(t["text"] for t in turns)
        dataset.append({"id": sid, "turns": turns, "flat": flat, "n_turns": len(turns)})
        if not args.no_audio:
            synthesize(flat, AUDIO / f"{sid}.wav", args.voice)
        if (i + 1) % 10 == 0:
            print(f"  generated {i + 1}/{args.n}")

    (DATA / "dataset.json").write_text(json.dumps(dataset, indent=2))
    lens = [d["n_turns"] for d in dataset]
    print(f"Wrote {len(dataset)} conversations to {DATA/'dataset.json'}")
    print(f"Turns per convo: min={min(lens)} max={max(lens)} avg={sum(lens)/len(lens):.1f}")
    if not args.no_audio:
        print(f"Audio in {AUDIO}")


if __name__ == "__main__":
    main()
