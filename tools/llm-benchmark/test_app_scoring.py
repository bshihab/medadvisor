"""Unit tests for the re-synced app_scoring.py (see PORT-DIFF.md).

Each test pins a behavior of Analysis.swift @ 9b578bf so future drift in the
Python port fails loudly instead of skewing benchmark numbers silently.
"""
from app_scoring import build_prompt, parse_criterion, is_placeholder, _supported

T = ("Doctor: Hello, I'm Dr. Patel, one of the clinic doctors here.\n"
     "Patient: Hi doctor, I've had this cough for three weeks now.\n"
     "Doctor: If the cough gets worse or you cough up blood, come straight back or call us.\n"
     "Patient: Okay, thank you.")


# ---- guardrail: the 3ad3ea0 tightening ----

def test_verbatim_quote_is_met():
    raw = "RESULT: done\nEVIDENCE: come straight back or call us\nTIP: none"
    assert parse_criterion(raw, T) == ("met", "come straight back or call us")

def test_single_shared_common_word_no_longer_rescues_met():
    # Old rule: "doctors" (>=4 chars, in transcript) => supported. New rule: 1
    # matching content word out of 4 (25% < 60%) and no verbatim 4-gram => missed.
    raw = "RESULT: done\nEVIDENCE: the doctors reviewed previous scan results\nTIP: none"
    status, _ = parse_criterion(raw, T)
    assert status == "missed"

def test_contiguous_four_word_phrase_grounds_a_paraphrased_quote():
    raw = ("RESULT: done\n"
           "EVIDENCE: he said if the cough gets worse she must return\nTIP: none")
    status, _ = parse_criterion(raw, T)
    assert status == "met"

def test_majority_of_content_words_grounds():
    # "cough" + "weeks" + "three" present, "persistent" not: 3/4 = 75% >= 60%.
    raw = "RESULT: done\nEVIDENCE: persistent cough three weeks\nTIP: none"
    assert parse_criterion(raw, T)[0] == "met"

def test_fewer_than_two_content_words_never_grounds():
    raw = "RESULT: done\nEVIDENCE: the un md\nTIP: none"
    assert parse_criterion(raw, T)[0] == "missed"

def test_met_without_evidence_is_downgraded():
    raw = "RESULT: done\nEVIDENCE: none\nTIP: none"
    assert parse_criterion(raw, T) == ("missed", None)


# ---- parser robustness (pre-existing, must not regress) ----

def test_bare_done_without_labels():
    raw = "done\ncome straight back or call us\nnone"
    assert parse_criterion(raw, T) == ("met", "come straight back or call us")

def test_bold_markdown_result():
    raw = "**RESULT:** done\n**EVIDENCE:** \"come straight back or call us\"\n**TIP:** none"
    assert parse_criterion(raw, T)[0] == "met"

def test_numbered_and_hash_markdown_stripped():
    raw = "# RESULT: missed\n## EVIDENCE: none\nTIP: greet the patient by name"
    assert parse_criterion(raw, T) == ("missed", None)

def test_not_done_maps_to_missed_before_done():
    assert parse_criterion("RESULT: not done\nEVIDENCE: none\nTIP: x", T)[0] == "missed"

def test_speaker_labels_stripped_from_evidence():
    raw = "RESULT: done\nEVIDENCE: Doctor: come straight back or call us\nTIP: none"
    assert parse_criterion(raw, T) == ("met", "come straight back or call us")


# ---- 3ad3ea0 parser changes ----

def test_na_is_missed_unless_allowed():
    raw = "RESULT: N/A\nEVIDENCE: none\nTIP: none"
    assert parse_criterion(raw, T)[0] == "missed"
    assert parse_criterion(raw, T, allows_na=True)[0] == "na"

def test_last_evidence_line_wins():
    raw = ("RESULT: done\nEVIDENCE: something unrelated entirely\n"
           "EVIDENCE: come straight back or call us\nTIP: none")
    assert parse_criterion(raw, T) == ("met", "come straight back or call us")

def test_colonless_evidence_label_yields_no_value_from_label_path():
    # Swift value(after:) returns nil when the line has no colon, so the
    # between-lines fallback takes the raw line as a quote — harmless here
    # (status already missed; an ungrounded "met" dies at the guardrail), but
    # the LABEL path must not swallow it, or a later real EVIDENCE: line and
    # the last-wins rule would be bypassed.
    raw = "RESULT: missed\nEVIDENCE none\nTIP: safety-net explicitly"
    assert parse_criterion(raw, T) == ("missed", "EVIDENCE none")

    # And an ungrounded met built this way is still killed by the guardrail.
    assert parse_criterion("RESULT: done\nEVIDENCE none\nTIP: none", T)[0] == "missed"


# ---- prompt building ----

def test_placeholder_required_elements_are_stripped():
    c = {"id": "safety_net", "prompt": "Did the clinician safety-net?",
         "whatGoodLooksLike": "[Director to specify examples]",
         "requiredElements": ["explicit return advice", "[Director to specify red flags]"]}
    p = build_prompt(c, T)
    assert "Director to specify" not in p
    assert "Must address: explicit return advice\n" in p
    assert "Good looks like" not in p

def test_placeholder_detection():
    assert is_placeholder("[Director to specify …]")
    assert is_placeholder("TBD")
    assert is_placeholder("  ")
    assert not is_placeholder("explicit return advice")

def test_suffix_spacing_matches_swift():
    c = {"id": "x", "prompt": "Q?"}
    p = build_prompt(c, "line")
    assert p.endswith("TRANSCRIPT:\nline\n\nQUESTION: Q?\n\nAnswer now in the exact three-line format.")


# ---- guardrail internals ----

def test_supported_is_unicode_aware():
    assert _supported("café visit follow up", "Doctor: we discussed the café visit follow up plan")
