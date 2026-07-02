"""Faithful Python port of the app's per-criterion scoring — the STRICT prompt
(Analysis.swift PromptBuilder.criterionPrompt) plus the tolerant parser and the
evidence guardrail (FeedbackParser.parseCriterion). Keep this in sync with the
Swift so the benchmark measures what actually ships."""
import re

STRICT_PROMPT = """You are a STRICT clinical communication examiner. In the transcript below, assess ONLY \
the Doctor's communication — ignore the Patient's lines entirely. (If the \
transcript has a single unlabeled speaker, treat that speaker as the clinician.)

QUESTION: {prompt}
{extras}
Scoring rules — follow exactly:
- Judge ONLY what the Doctor ACTUALLY said in the transcript. Never reward \
intentions, assumptions, or things that "could have" been said.
- "done" REQUIRES a direct supporting quote from the Doctor. If you cannot quote \
the Doctor actually doing this, it is NOT done.
- If the Doctor did not clearly do this, answer "missed".
- If the transcript is empty, very short, or has no relevant Doctor communication, \
answer "missed".

Result:
- "done" = the Doctor clearly did this, and you can quote it
- "partial" = the Doctor attempted it but it was incomplete
- "missed" = the Doctor did not do this (or there is no evidence they did)

Answer in EXACTLY three lines and nothing else:
RESULT: done, partial, or missed
EVIDENCE: a direct quote of the Doctor's words, or the word none
TIP: one short, specific improvement tip

TRANSCRIPT:
{transcript}
"""


def build_prompt(criterion: dict, transcript: str) -> str:
    extras = ""
    good = criterion.get("whatGoodLooksLike")
    if good:
        extras += f"Good looks like: {good}\n"
    req = criterion.get("requiredElements")
    if req:
        extras += "Must address: " + "; ".join(req) + "\n"
    return STRICT_PROMPT.format(prompt=criterion["prompt"], extras=extras, transcript=transcript)


def parse_criterion(raw: str, transcript: str):
    """Returns (status, evidence). status in {met, partial, missed}."""
    status, evidence = "missed", None
    for line in raw.splitlines():
        low = line.strip().lower()
        if low.startswith("result:") or low.startswith("met:"):
            if "partial" in low:
                status = "partial"
            elif "missed" in low or "not done" in low or low.endswith(" no") or low.endswith("no"):
                status = "missed"
            elif "done" in low or "yes" in low:
                status = "met"
        elif low.startswith("evidence:"):
            evidence = line.split(":", 1)[1].strip().strip(" \t\"'“”")
            if evidence.lower() == "none" or not evidence:
                evidence = None
    # Guardrail: a "met" must be grounded in the transcript, else downgrade.
    if status == "met" and not _supported(evidence, transcript):
        status = "missed"
    return status, evidence


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9\s]", " ", s.lower())).strip()


def _supported(evidence, transcript: str) -> bool:
    if not evidence:
        return False
    t, e = _norm(transcript), _norm(evidence)
    if not e:
        return False
    if e in t:
        return True
    tw = set(t.split())
    content = [w for w in e.split() if len(w) >= 4]
    if not content:
        return any(w in tw for w in e.split())
    return any(w in tw for w in content)
