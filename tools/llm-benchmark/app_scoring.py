"""Faithful Python port of the app's per-criterion scoring — the STRICT prompt
(Analysis.swift PromptBuilder.scoringPrefix + criterionSuffix) plus the tolerant
parser and the evidence guardrail (FeedbackParser.parseCriterion). Keep this in
sync with the Swift so the benchmark measures what actually ships.

Re-synced 2026-07-22 against Analysis.swift @ 9b578bf (see PORT-DIFF.md):
- evidence guardrail tightened: verbatim / contiguous 4-word phrase / >=60% of
  substantive words (min 2) — was any single >=4-char shared word
- rubric placeholder text ("[Director to specify …]", TBD) stripped from prompts
- parser: N/A keyword handling, '#' header stripping, last EVIDENCE line wins,
  colon-less EVIDENCE/TIP lines yield no value
"""
import os
import re

# --- CANDIDATE APP CHANGE, off by default -----------------------------------
# Set APP_SCORING_FEW_SHOT=1 to prepend worked examples to the shared prefix.
# This deliberately DIVERGES from Analysis.swift: it is a proposed prompt change
# being measured, not shipped behavior. Baseline runs must leave it unset.
#
# Why these three examples: the measured failure of small models here is pure
# leniency (stock Apple FM credited 75% of absent behaviors). Positive exemplars
# already exist in the rubric; what is missing is negative calibration. So each
# example teaches one of the three ways a lenient grader goes wrong:
#   1. a polite sign-off mistaken for safety-netting  (surface-similarity trap)
#   2. a genuine behavior with a verbatim quote       (keeps recall from collapsing)
#   3. the PATIENT saying it, credited to the clinician (attribution trap)
# The example transcript is authored fresh and is deliberately unrelated to any
# benchmark case; the evidence guardrail also downgrades any answer that quotes
# from the examples instead of the real transcript.
FEW_SHOT_BLOCK = """
Worked examples — study how strictly these are judged. \
These use a DIFFERENT, UNRELATED transcript; never quote from them.

EXAMPLE TRANSCRIPT:
Doctor: Right, so it's the ankle. I'll get you some ibuprofen.
Patient: I'm a bit worried, my mother had a clot in her leg.
Doctor: Mm. Keep it elevated. Cheers, take care now.

EXAMPLE 1 — QUESTION: Did the clinician safety-net (what to watch for, when to seek help)?
RESULT: missed
EVIDENCE: none
TIP: Name specific red flags and say exactly when and where to seek help; "take care now" is a farewell, not a safety-net.

EXAMPLE 2 — QUESTION: Did the clinician discuss a clear plan?
RESULT: partial
EVIDENCE: I'll get you some ibuprofen.
TIP: State the plan fully and invite the patient's preference rather than issuing it.

EXAMPLE 3 — QUESTION: Did the clinician explore the patient's fears and concerns?
RESULT: missed
EVIDENCE: none
TIP: The patient raised a fear about a clot; the clinician must follow it up. A concern the PATIENT voices is never credited to the clinician.

END OF EXAMPLES. Now judge the REAL transcript below.
"""


def _few_shot_enabled() -> bool:
    return os.environ.get("APP_SCORING_FEW_SHOT") == "1"

# Mirrors the app's PREFIX-CACHED prompt order (Analysis.swift): the shared
# prefix (instructions + transcript) comes FIRST, the per-criterion question
# LAST — so the transcript's KV state can be reused across all 16 criteria.
SCORING_PREFIX = """You are a STRICT clinical communication examiner. Below is the transcript of a \
medical consultation between a clinician and a patient. The speaker labels come \
from automatic transcription and are SOMETIMES WRONG — a line labelled "Patient:" \
may actually be the clinician, and vice versa. Decide who is speaking from the \
CONTENT, not just the label: the clinician greets, takes the history, asks the \
questions, examines, explains, reassures, and gives the plan; the patient \
describes their own symptoms, feelings, and worries. (If there is a single \
unlabelled speaker, treat that speaker as the clinician.)

You will then be asked ONE question about the CLINICIAN's communication.

Scoring rules — follow exactly:
- Judge whether the CLINICIAN actually demonstrated this, based on what was said \
anywhere in the transcript — NOT on the possibly-wrong speaker label.
- NEVER credit the clinician for something the PATIENT said. A patient describing \
their own symptoms or feelings is not the clinician exploring them.
- The quote must ACTUALLY demonstrate the SPECIFIC behavior being asked about. A \
generic greeting, acknowledgement, or sign-off ("take care", "I've got other \
patients", "okay", "goodbye") does NOT count as safety-netting, teach-back, \
exploring concerns, or inviting questions. If the quote does not clearly show \
THIS exact behavior, answer "missed".
- "done" REQUIRES a direct supporting quote of the clinician actually doing it. If \
you cannot quote it, it is NOT done. Never reward intentions or things that \
"could have" been said.
- If the clinician did not clearly do this, answer "missed".
- If the transcript is empty or very short, answer "missed".

Result:
- "done" = the clinician clearly did this, and you can quote it
- "partial" = the clinician attempted it but it was incomplete
- "missed" = the clinician did not do this (or there is no evidence they did)

Answer in EXACTLY three lines and nothing else:
RESULT: done, partial, or missed
EVIDENCE: a short direct quote of the clinician's OWN words, with NO speaker labels (write none if missed)
TIP: one short, specific improvement tip if partial or missed (write none if done)

TRANSCRIPT:
{transcript}"""


# Faithful port of PromptBuilder.speakerAttributionPrompt (Analysis.swift:161).
# The model only CLASSIFIES fixed utterance boundaries — it never guesses where
# turns break, which is what caused phase-slips in earlier designs.
ATTRIBUTION_PROMPT = """These are numbered utterances from a two-person doctor–patient consultation, \
in chronological order. Label EVERY utterance as D (Doctor) or P (Patient).

Decide each one from its CONTENT and clinical role — do NOT just assume the \
speakers take strict turns:
- The DOCTOR opens by greeting and introducing themselves, then asks the \
history questions, proposes and narrates the exam, explains findings, \
reassures, and gives the plan and safety-net.
- The PATIENT describes their own symptoms, feelings, worries, and answers \
questions about themselves.
- Speakers do NOT alternate every line. A greeting, a multi-part question, or \
a follow-up is usually the SAME speaker as the line before it — one speaker \
often has several utterances in a row.
- Assign short lines ("Okay.", "Right.", "Yeah, that's fine.") to whoever the \
surrounding content shows is speaking.

Output ONLY one line per number in the form "N: D" or "N: P". Nothing else.

UTTERANCES:
{numbered}"""


def build_attribution_prompt(utterances) -> str:
    numbered = "\n".join(f"{i + 1}. {u}" for i, u in enumerate(utterances))
    return ATTRIBUTION_PROMPT.format(numbered=numbered)


# Proposed summary prompt: the shipped summaryPrompt (Analysis.swift:219) passes
# ONLY the met/applicable counts, so every model can answer nothing but
# "meet the remaining criteria". Naming the missed criteria is what makes a
# specific summary possible at all. Training on this shape means the fine-tune
# and the app-side prompt fix must ship together.
SUMMARY_PROMPT = """A doctor met {met} of {applicable} criteria in a {encounter} consultation.
They did NOT demonstrate: {missed}.
In 2 sentences, summarize how they did overall and the single most important thing to \
improve next time. Plain prose, no lists."""


def is_placeholder(s: str) -> bool:
    """PromptBuilder.isPlaceholder — draft-rubric author placeholders must never
    reach the model as scoring guidance."""
    t = s.strip()
    if not t:
        return True
    if t.startswith("[") and t.endswith("]"):
        return True
    low = t.lower()
    return "to specify" in low or "tbd" in low or "director to" in low


def build_prompt(criterion: dict, transcript: str) -> str:
    """scoringPrefix + criterionSuffix, byte-for-byte with the Swift."""
    extras = ""
    good = criterion.get("whatGoodLooksLike")
    if good and not is_placeholder(good):
        extras += f"Good looks like: {good}\n"
    req = [r for r in (criterion.get("requiredElements") or []) if not is_placeholder(r)]
    if req:
        extras += "Must address: " + "; ".join(req) + "\n"
    prefix = SCORING_PREFIX.format(transcript=transcript)
    if _few_shot_enabled():
        # Insert before the real transcript so the whole block stays inside the
        # KV-cached shared prefix (prefill paid once, not 16x).
        head, _, tail = prefix.partition("\nTRANSCRIPT:\n")
        prefix = head + FEW_SHOT_BLOCK + "\nTRANSCRIPT:\n" + tail
    return (prefix
            + f"\n\nQUESTION: {criterion['prompt']}\n{extras}\nAnswer now in the exact three-line format.")


def _clean(line: str) -> str:
    """FeedbackParser.clean — strip markdown, list markers, and a leading label."""
    s = line.strip()
    s = re.sub(r"^[*\-•>#\s]+", "", s)
    s = re.sub(r"^\d+[.)]\s*", "", s)          # "1. " / "1) "
    s = s.replace("*", "").strip()
    low = s.lower()
    for pfx in ("result:", "met:", "verdict:", "answer:", "score:"):
        if low.startswith(pfx):
            return s[len(pfx):].strip()
    return s


def _keyword(s: str):
    """FeedbackParser.keyword — map a cleaned line to a status if it clearly
    states one. Order matters: n/a and missed/not-done BEFORE done."""
    low = s.lower()
    if low.startswith("n/a") or low.startswith("not applicable") or low == "na":
        return "na"
    if low.startswith("partial"):
        return "partial"
    if low.startswith("missed") or low.startswith("not done") or low in ("no", "no."):
        return "missed"
    if low.startswith("done") or low.startswith("met") or low in ("yes", "yes."):
        return "met"
    return None


_QUOTE_CHARS = " \t\"'“”"


def _value_after(line: str):
    """FeedbackParser.value(after:) — text after the first ':' in the ORIGINAL
    line; None if there is no colon or the value is empty."""
    if ":" not in line:
        return None
    v = line.split(":", 1)[1].strip(_QUOTE_CHARS)
    return v or None


def _strip_speaker_labels(s: str) -> str:
    out = re.sub(r"(?i)\b(doctor|patient|clinician|speaker\s*\d+)\s*:\s*", "", s)
    return re.sub(r"\s{2,}", " ", out).strip()


def parse_criterion(raw: str, transcript: str, allows_na: bool = False):
    """FeedbackParser.parseCriterion. Returns (status, evidence); status is
    met/partial/missed (or "na" only when allows_na). Robust to bare / **bold**
    / labeled formats — models often drop the RESULT:/EVIDENCE: labels, which
    must not zero them out."""
    lines = [l for l in (ln.rstrip() for ln in raw.splitlines()) if l.strip()]

    status, result_idx = "missed", None
    for i, line in enumerate(lines):
        kw = _keyword(_clean(line))
        if kw is not None:
            status, result_idx = kw, i
            break
    if result_idx is None:  # last resort: search anywhere
        low = raw.lower()
        if "n/a" in low or "not applicable" in low:
            status = "na"
        elif "partial" in low:
            status = "partial"
        elif "missed" in low or "not done" in low:
            status = "missed"
        elif "done" in low or "yes" in low:
            status = "met"

    # N/A is only honored for criteria that allow it; otherwise it's a miss.
    if status == "na" and not allows_na:
        status = "missed"

    # Evidence: an EVIDENCE: line if present (LAST one wins, as in the Swift),
    # else the text between the result line and the TIP line.
    evidence = None
    for line in lines:
        if _clean(line).lower().startswith("evidence"):
            evidence = _value_after(line)
    if evidence is None and result_idx is not None:
        # First plausible line only — joining all lines glued stray
        # verdict/none/tip words into the quote.
        for line in lines[result_idx + 1:]:
            c = _clean(line)
            low = c.lower()
            if low.startswith("tip"):
                break
            if _keyword(c) is not None or low == "none" or not c:
                continue
            evidence = c.strip(_QUOTE_CHARS)
            break
    if evidence:
        e = _strip_speaker_labels(evidence).strip(_QUOTE_CHARS)
        evidence = None if (not e or e.lower() == "none") else e

    # Guardrail: a "met" must be grounded in the transcript, else downgrade.
    if status == "met" and not _supported(evidence, transcript):
        status = "missed"
    return status, evidence


def _norm(s: str) -> str:
    """FeedbackParser.normalize — lowercase, alnum-only, collapsed whitespace."""
    return " ".join("".join(c if c.isalnum() else " " for c in s.lower()).split())


def _supported(evidence, transcript: str) -> bool:
    """FeedbackParser.isSupported — grounding requires ONE of: a (near-)verbatim
    substring; a contiguous 4-word phrase appearing verbatim; or a MAJORITY
    (>=60%) of the quote's substantive (>=4-char) words present, min 2 such
    words. The old rule — a single shared >=4-char word — let fabricated quotes
    pass, which is exactly the over-scoring this guardrail exists to stop."""
    if not evidence:
        return False
    t, e = _norm(transcript), _norm(evidence)
    if not e:
        return False
    if e in t:
        return True

    words = e.split()
    if len(words) >= 4:
        for start in range(len(words) - 3):
            if " ".join(words[start:start + 4]) in t:
                return True

    tw = set(t.split())
    content = [w for w in words if len(w) >= 4]
    if len(content) < 2:
        return False
    present = sum(w in tw for w in content)
    return present / len(content) >= 0.6
