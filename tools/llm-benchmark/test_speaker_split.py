#!/usr/bin/env python3
"""Does finer segmentation produce chunks that contain only ONE speaker?

The app never sees speaker information. Apple's SpeechTranscriber returns one
whole-file blob (AppleSpeechTranscriber.swift:11 -- and note the .audioTimeRange
attribute it says "didn't resolve" was simply never requested, attributeOptions
is []), so SpeakerAttribution sentence-splits the flat text and an LLM labels each
sentence D or P.

That fails when a sentence boundary is not a speaker boundary. From a real
recording today, ONE "utterance":

    "No, nothing like that, it's just fine. How bad, one to 10. About a 6."
     ^^^^^^^^^^^^^^^^^^^^^ patient          ^^^^^^^^^^^^^^^^^^ DOCTOR

The classifier must pick one label for all of it. No classifier can be right --
including Apple's, which is why swapping the classifier was the wrong fix.

WHY OVER-SPLITTING IS SAFE: the pipeline merges consecutive same-role utterances
back into turns (SpeakerAttribution.turns). So splitting too finely costs a few
extra classifications and re-merges correctly; splitting too coarsely is
unrecoverable. The asymmetry says split aggressively.

WHY NOT JUST PAUSES: an interruption has no pause -- that is what makes it an
interruption. Pause-splitting would fail on exactly the case that produced the
mangled chunks above, and on the `avoid_interrupting` criterion specifically.
Pauses are one cue among several, not the mechanism. This script tests the TEXT
cues only, since the audio timings are not available outside the app.

METRIC: chunk purity -- the share of chunks whose text comes from a single real
speaker. It needs no model and no GPU, and it is precisely what the change
targets. Label accuracy is a separate question, worth measuring only if purity
improves.

Ground truth below is hand-aligned from the scripts that were read aloud against
what the transcriber actually produced.
"""
import re

# Each transcript is a list of (true_speaker, text) fragments in spoken order.
# Concatenating the text gives the flat transcript a splitter sees; the speaker
# tags are the answer key. Fragments split ONLY where the real speaker changes.
TRANSCRIPTS = {
"rushed": [
 ("D", "Come in, sit down."),
 ("D", "I'm writing about half an hour behind, so on, speak quick."),
 ("D", "Back pain, is it?"),
 ("P", "Yes, my lower back. It started about 3 weeks ago."),
 ("D", "And three weeks, any numbness in the legs, any trouble passing water."),
 ("P", "No, nothing like that, it's just fine."),
 ("D", "How bad, one to 10."),
 ("P", "About a 6. It's worse in the morning and sitting makes it right."),
 ("D", "Have you tried anything for it?"),
 ("P", "I'm proven. helps a little. Look, I'm quite worried, my father had spinal cancer, and I keep thinking,"),
 ("D", "let me stop you there."),
 ("D", "I need to examine you. Shut up, bend forward. Does that hurt?"),
 ("P", "A bit. Sorry, I'm a bit emotional about all this."),
 ("D", "Okay. Straight leg, raise is negative. No focal neurology, likely mechanical, and ideology rather than radicular."),
 ("P", "Sorry, what does that mean?"),
 ("D", "It means it's mus- musculoskeletal. I'll put you on Nexoprin. That broke in, and refer you to physio, take, take it with food."),
 ("P", "Okay."),
 ("D", "Do come back the same day if you get numbness between your legs."),
 ("D", "Trouble with irritation or weakness, and either, like, those need looking at urgently."),
 ("P", "Right?"),
 ("D", "Good, receptional, sort, your appointment, next patients waiting."),
],
"good": [
 ("D", "Good morning, I'm Dr. Alice, one of the GPs here. Come in and take a seat."),
 ("P", "Thank you."),
 ("D", "There's no rush at all. 20 minutes and the door is shut, so tell me, in your own words, what's been going on?"),
 ("P", "I've got this rash on my arms about 6 weeks now and it's driving me insane."),
 ("D", "Come on, tell me more."),
 ("D", "I will interrupt."),
 ("P", "It's just worst at night. I tried a cream from the chemist, made no difference. It seems worse since I started a new job in a kitchen."),
 ("D", "That's really useful. When exactly did it start? How far has it spread and isn't sore as well as itchy? Start on my back?"),
 ("P", "My hands now up to my elbows sore. Where I've scratched it."),
 ("D", "And what's your own sense of what's causing it, anything you've been worried about?"),
 ("P", "I wondered if it's something I'm touching at work. I'm afraid I'll have to give up the job I've only started."),
 ("D", "That's a real worry, and I can hear how much your job matters to you. Let's take it seriously and see what we can do, giving it up is not where I'd start."),
 ("P", "Thank you, that helps."),
 ("D", "I'd like to look at your arm and hands now. I just need you to roll your sleeves up. Tell me if anything I do is uncomfortable and I'll stop."),
 ("P", "That's fine."),
 ("D", "Thank you, in plain terms, this looks like contact dermatitis, skin reacting to something. You're touching over and over and the kitchen fits that well. It isn't an infection and you can't pass it to anyone."),
 ("P", "That's a relief."),
 ("D", "It usually settles once we work out what's causing it, and cut the contact down, so it can take a few weeks and it may flare again. I can't promise it'll clear completely without something changing at work."),
 ("P", "Understood."),
 ("D", "Two options. We start a steroid ointment, plus... gloves and a barrier cream and a review in three weeks. Or I refer you for patch testing now. I just went over all the questions."),
],
"headache": [
 ("D", "Like I said, have a seat. Make yourself comfortable. No rush. We. We have plenty of time, so tell me onwards what's brought you in today."),
 ("P", "She has headaches nearly every day for a month now, and it's really getting to me."),
 ("D", "Go on, take your time."),
 ("P", "Afternoons, mostly, like a light bat around my head. Parasitamo helps a bit worse after a long day off the computer."),
 ("D", "How bad do they get at their worst, and is there anything else that makes them better or worse?"),
 ("P", "7 out of 10 maybe dark room helps. Coffee makes it worse."),
 ("D", "Is there anything else you wanted to raise today?"),
 ("P", "No, just headaches."),
 ("D", "And what do you think might be going on? Anything you've been worried it could be?"),
 ("P", "Honestly, I've been frightened. It's a tumor My mom had one. About my age. I've been lying awake over it."),
 ("D", "That sounds genuinely frightening, and with your mom's history. Of course, there, that's where your mind goes. I'm glad you told me. You did the right thing coming in and all work through this together."),
 ("P", "Thank you."),
 ("D", "I'd like to examine you now. I'll check your blood pressure, then use a light to look at the back of your eye. It's spray, but it doesn't hurt. Say if anything is uncomfortable and I'll stop. Blood pressure is normal, and the backs of your eye look completely healthy in everyday terms. This looks like a tension type headache. The muscle across your scalp and neck tightening up and staying tight."),
 ("P", "So it's not serious?"),
 ("D", "Nothing. I've found today points that way. I won't promise you, certainly, though, if the pattern changes, I'd want to know."),
 ("P", "That's a relief."),
 ("D", "Two reasonable options. We start with a simple thing, screen breaks, cutting the daily parasitamol, sorting your sleep. Or we arrange a scan for peace of mind. What feels right to you?"),
 ("P", "The simple things first."),
 ("D", "Good."),
 ("D", "I forget it all down for you, so you don't have to remember any of it."),
 ("P", "Thanks."),
 ("D", "Let's put a review in the diary for 3 weeks."),
 ("P", "Okay."),
 ("D", "Before you go, what questions do you have for me?"),
 ("P", "None, I don't think."),
 ("D", "Thanks for listening."),
],
}

# ---------------------------------------------------------------- splitters

def split_current(text):
    """What the app does today: sentence boundaries only.
    Returns (start, end) index pairs so purity can be checked by offset."""
    spans, start = [], 0
    for m in re.finditer(r'[.?!]+(?:\s+|$)', text):
        spans.append((start, m.end()))
        start = m.end()
    if start < len(text):
        spans.append((start, len(text)))
    return [(a, b) for a, b in spans if text[a:b].strip()]


# Phrases that almost always OPEN a clinician turn. Drawn from the strong-signal
# list already in PromptBuilder.speakerAttributionPrompt — the prompt knows these,
# it just never gets a chunk small enough to apply them to.
DOCTOR_OPENERS = [
    r"let me stop you there", r"let me stop you", r"let me examine", r"let me take a look",
    r"i need to examine", r"how bad", r"tell me more", r"go on,? take your time",
    r"what brought you in", r"what brings you in", r"any numbness", r"have you tried",
    r"have you noticed", r"when did it start", r"how long have you",
    r"i'd like to examine", r"i'd like to look", r"i'll check your",
    r"in plain terms", r"here's what i'd suggest", r"i'd recommend",
    r"do come back", r"come back or call", r"before we finish",
    r"what questions do you have", r"could you tell me back", r"is there anything else",
    r"i will interrupt", r"i won't interrupt", r"two options", r"two reasonable options",
]
PATIENT_OPENERS = [
    r"i've been", r"i've had", r"it started", r"i'm worried", r"i'm quite worried",
    r"i'm frightened", r"i wondered if", r"i googled", r"sorry,? what does that mean",
    r"about a \d", r"\d+ out of \d+", r"thank you", r"that's a relief", r"understood",
]

def split_aggressive(text):
    """Sentence boundaries PLUS clause boundaries that precede a strong
    speaker-signal phrase. Interruptions live mid-sentence, after a comma:

        "... and I keep thinking, let me stop you there."
                                 ^ split here

    Over-splitting is safe -- consecutive same-role chunks re-merge downstream --
    so a boundary is inserted whenever a clause STARTS with a phrase that strongly
    implies a particular speaker."""
    out = []
    for a, b in split_current(text):
        seg = text[a:b]
        cuts = [0]
        # candidate clause starts inside this sentence: after , ; : or a dash
        for m in re.finditer(r'(?<=[,;:])\s+|\s+[—–-]\s+', seg):
            rest = seg[m.end():].lstrip().lower()
            if any(re.match(p, rest) for p in DOCTOR_OPENERS + PATIENT_OPENERS):
                cuts.append(m.end())
        cuts.append(len(seg))
        for i in range(len(cuts) - 1):
            s, e = cuts[i], cuts[i + 1]
            if seg[s:e].strip():
                out.append((a + s, a + e))
    return out


# ---------------------------------------------------------------- measurement

def evaluate(name, fragments, splitter):
    """A chunk is PURE if every character in it comes from one real speaker."""
    text = " ".join(t for _, t in fragments)
    # character -> true speaker
    owner, pos = [], 0
    for spk, frag in fragments:
        owner.extend(spk * len(frag))
        owner.append(" ")            # the joining space belongs to nobody
        pos += len(frag) + 1
    owner = owner[:len(text)]

    spans = splitter(text)
    pure = mixed = 0
    impure_examples = []
    for a, b in spans:
        speakers = {c for c in owner[a:b] if c in "DP"}
        if len(speakers) <= 1:
            pure += 1
        else:
            mixed += 1
            if len(impure_examples) < 3:
                impure_examples.append(text[a:b].strip()[:110])
    return dict(chunks=len(spans), pure=pure, mixed=mixed,
                purity=pure / len(spans) * 100 if spans else 0,
                examples=impure_examples)


def main():
    print("=" * 78)
    print("CHUNK PURITY — can a classifier possibly be right?")
    print("=" * 78)
    print("A chunk is PURE if all its text came from one real speaker. A mixed")
    print("chunk is unlabelable: one label must cover two people.\n")
    print(f"{'transcript':<12} {'splitter':<12} {'chunks':>7} {'pure':>6} {'mixed':>6} {'purity':>8}")
    print("-" * 78)
    totals = {}
    for name, frags in TRANSCRIPTS.items():
        for label, fn in (("current", split_current), ("aggressive", split_aggressive)):
            r = evaluate(name, frags, fn)
            totals.setdefault(label, []).append(r)
            print(f"{name:<12} {label:<12} {r['chunks']:>7} {r['pure']:>6} "
                  f"{r['mixed']:>6} {r['purity']:>7.1f}%")
        print()

    print("-" * 78)
    for label, rs in totals.items():
        c = sum(r["chunks"] for r in rs); p = sum(r["pure"] for r in rs)
        print(f"{'ALL THREE':<12} {label:<12} {c:>7} {p:>6} {c-p:>6} {p/c*100:>7.1f}%")

    print("\n" + "=" * 78)
    print("MIXED CHUNKS UNDER THE CURRENT SPLITTER — these are unlabelable today")
    print("=" * 78)
    for name, frags in TRANSCRIPTS.items():
        r = evaluate(name, frags, split_current)
        if r["examples"]:
            print(f"\n{name}:")
            for e in r["examples"]:
                print(f"   \"{e}\"")

    print("\n" + "=" * 78)
    print("STILL MIXED AFTER AGGRESSIVE SPLITTING — what the cues do not catch")
    print("=" * 78)
    any_left = False
    for name, frags in TRANSCRIPTS.items():
        r = evaluate(name, frags, split_aggressive)
        if r["examples"]:
            any_left = True
            print(f"\n{name}:")
            for e in r["examples"]:
                print(f"   \"{e}\"")
    if not any_left:
        print("\n  none — every chunk is single-speaker.")

    print("\nNOTE: the pause cue (audioTimeRange) is NOT tested here — that needs")
    print("the audio, so it can only be validated on device. This measures the")
    print("clause cues, which are the half that handles interruptions.")


if __name__ == "__main__":
    main()
