"""Faithful Python port of the app's per-criterion scoring — the STRICT prompt
(Analysis.swift scoringPrefix + criterionSuffix) plus the tolerant parser and the
evidence guardrail (FeedbackParser.parseCriterion). Keep this in sync with the
Swift so the benchmark measures what actually ships."""
import re

# Mirrors the app's PREFIX-CACHED prompt order (Analysis.swift): the shared
# prefix (instructions + transcript) comes FIRST, the per-criterion question
# LAST — so the transcript's KV state can be reused across all 16 criteria.
SCORING_PREFIX = """You are a STRICT clinical communication examiner. Below is the transcript of a \
medical consultation. You will then be asked ONE question about the Doctor's \
communication — assess ONLY the Doctor, ignore the Patient's lines entirely. \
(If the transcript has a single unlabeled speaker, treat that speaker as the clinician.)

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
EVIDENCE: a direct quote of the Doctor's words (write none if missed)
TIP: one short, specific improvement tip if partial or missed (write none if done)

TRANSCRIPT:
{transcript}"""

CRITERION_SUFFIX = """

QUESTION: {prompt}
{extras}
Answer now in the exact three-line format."""


def build_prompt(criterion: dict, transcript: str) -> str:
    extras = ""
    good = criterion.get("whatGoodLooksLike")
    if good:
        extras += f"Good looks like: {good}\n"
    req = criterion.get("requiredElements")
    if req:
        extras += "Must address: " + "; ".join(req) + "\n"
    return (SCORING_PREFIX.format(transcript=transcript)
            + CRITERION_SUFFIX.format(prompt=criterion["prompt"], extras=extras))


def _clean(line: str) -> str:
    """Strip markdown, list markers, and leading label so we can read the value."""
    s = line.strip().lstrip("*-•> \t")
    s = re.sub(r"^\d+[.)]\s*", "", s)          # "1. " / "1) "
    s = s.replace("*", "").strip()
    low = s.lower()
    for pfx in ("result:", "met:", "verdict:", "answer:", "score:"):
        if low.startswith(pfx):
            return s[len(pfx):].strip()
    return s


def _keyword(s: str):
    """Map a cleaned line to a status if it clearly states one, else None.
    Order matters: check missed/not-done before done (so 'not done' → missed)."""
    low = s.lower()
    if low.startswith("partial"):
        return "partial"
    if low.startswith("missed") or low.startswith("not done") or low in ("no", "no."):
        return "missed"
    if low.startswith("done") or low.startswith("met") or low in ("yes", "yes."):
        return "met"
    return None


def parse_criterion(raw: str, transcript: str):
    """Returns (status, evidence). Robust to bare / **bold** / labeled formats —
    models often drop the RESULT:/EVIDENCE: labels, which must not zero them out."""
    lines = [l for l in (ln.rstrip() for ln in raw.splitlines()) if l.strip()]

    status, result_idx = None, None
    for i, line in enumerate(lines):
        kw = _keyword(_clean(line))
        if kw is not None:
            status, result_idx = kw, i
            break
    if status is None:  # last resort: search anywhere
        low = raw.lower()
        status = ("partial" if "partial" in low
                  else "missed" if ("missed" in low or "not done" in low)
                  else "met" if ("done" in low or "yes" in low)
                  else "missed")

    # Evidence: prefer an EVIDENCE: line; else take the text between the result
    # line and the TIP line (models that drop labels put the quote there).
    evidence = None
    for line in lines:
        if _clean(line).lower().startswith("evidence") or line.strip().lower().startswith("evidence:"):
            evidence = line.split(":", 1)[-1].strip().strip(" \t\"'“”")
            break
    if evidence is None and result_idx is not None:
        mid = []
        for line in lines[result_idx + 1:]:
            if _clean(line).lower().startswith("tip"):
                break
            mid.append(_clean(line))
        cand = " ".join(mid).strip().strip(" \t\"'“”")
        if cand:
            evidence = cand
    if evidence and evidence.lower() == "none":
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
