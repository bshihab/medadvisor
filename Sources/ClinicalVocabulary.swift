import Foundation

/// Terms fed to Apple's speech recogniser as contextual bias
/// (`AnalysisContext.contextualStrings`), so clinical words are recognised as
/// themselves instead of as whatever common English word sounds closest.
///
/// Every entry below except the padding is here because a real test recording
/// came back wrong:
///
///     "Parasitamo" / "parasitamol"  -> paracetamol
///     "Nexoprin. That broke in"     -> naproxen. Take it with food
///     "I'm proven. helps a little"  -> Ibuprofen. Helps a little
///     "likely mechanical, and ideology rather than radicular"
///                                   -> ... in aetiology rather than radicular
///
/// Those are not marginal: the drug-name errors land inside the clinician's
/// treatment explanation, which is exactly what the `accurate_info` criterion is
/// graded on. A grader reading "Nexoprin. That broke in" cannot tell whether the
/// advice was correct.
///
/// LIMITS, honestly: contextual bias helps with words the recogniser does not
/// expect. It does NOT help with ordinary words heard wrong — the same
/// recordings produced "I will interrupt" for "I won't interrupt" and "Shut up"
/// for "Shirt up", and no vocabulary list fixes those. Those two are the more
/// damaging errors (one inverts a criterion outright), so this is a partial fix
/// to a real problem, not a solution to transcription quality.
///
/// Kept deliberately short. Contextual bias is a hint, not a dictionary — a huge
/// list dilutes each term's weight and can pull ordinary speech toward clinical
/// homophones, which would be a regression. Add terms when a recording shows one
/// mis-heard, not speculatively.
enum ClinicalVocabulary {

    /// Drugs seen or likely in outpatient consultations. UK generic spellings,
    /// matching the register the rubric and test recordings use.
    static let medications = [
        "paracetamol", "ibuprofen", "naproxen", "codeine", "co-codamol",
        "amitriptyline", "amoxicillin", "penicillin", "flucloxacillin",
        "clarithromycin", "doxycycline", "trimethoprim", "nitrofurantoin",
        "omeprazole", "lansoprazole", "ranitidine", "gaviscon",
        "salbutamol", "beclometasone", "prednisolone", "hydrocortisone",
        "amlodipine", "ramipril", "bisoprolol", "atorvastatin", "simvastatin",
        "metformin", "gliclazide", "levothyroxine", "sertraline", "fluoxetine",
        "citalopram", "propranolol", "diazepam", "zopiclone",
        "cetirizine", "loratadine", "chlorphenamine",
        "emollient", "hydromol", "diprobase", "betnovate", "eumovate",
    ]

    /// Clinical vocabulary — examination findings, anatomy, diagnoses.
    static let clinical = [
        "aetiology", "radicular", "radiculopathy", "musculoskeletal",
        "neurology", "focal neurology", "straight leg raise",
        "dermatitis", "contact dermatitis", "eczema", "urticaria", "cellulitis",
        "tension-type headache", "migraine", "aura", "photophobia",
        "papilloedema", "fundoscopy", "ophthalmoscope",
        "sciatica", "lumbar", "thoracic", "cervical", "paraesthesia",
        "cauda equina", "red flags", "safety net", "safety-netting",
        "differential", "self-limiting", "conservative management",
        "post-viral", "viral", "bacterial", "antibiotics",
        "auscultation", "palpation", "percussion", "abdomen", "epigastric",
        "hypertension", "hypotension", "tachycardia", "palpitations",
        "dyspnoea", "haemoptysis", "dysphagia", "dysuria", "haematuria",
        "referral", "physiotherapy", "patch testing", "spirometry",
        "barrier cream", "steroid ointment", "topical",
    ]

    /// Phrases the rubric is scored on. Biasing these matters because a mangled
    /// clinician phrase can lose a criterion the clinician actually met — the
    /// grading prompt looks for exactly this kind of wording.
    static let consultationPhrases = [
        "what brought you in today", "in your own words",
        "is there anything else", "anything else you wanted to raise",
        "what do you think might be going on", "what are you most worried about",
        "how can I help", "tell me more about",
        "let me examine you", "I'd like to examine you",
        "say if anything is uncomfortable",
        "in plain terms", "what this means is",
        "what would you prefer", "what feels right to you",
        "could you tell me back", "in your own words what you'll do",
        "come back the same day", "seek help the same day",
        "what questions do you have",
    ]

    /// The full bias list. Order is not significant.
    static var all: [String] { medications + clinical + consultationPhrases }
}
