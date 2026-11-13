/**
 * Grounding check for cards produced by an LLM: every value marked FOUND must be
 * supported by evidence that actually appears in the CV text. If not, it is downgraded
 * to INFERRED and an issue is recorded. This is the main anti-hallucination control
 * on the extraction path.
 */
public with sharing class CardValidator {

    public static CandidateCard validate(CandidateCard card, String rawText) {
        String haystack = squash(rawText);
        List<CandidateCard.CardField> fields = new List<CandidateCard.CardField>{
            card.name, card.headline, card.email, card.phone, card.location
        };
        List<String> labels = new List<String>{ 'name', 'headline', 'email', 'phone', 'location' };
        for (Integer i = 0; i < fields.size(); i++) {
            CandidateCard.CardField f = fields[i];
            if (f == null || f.status != CandidateCard.FOUND) { continue; }
            if (!isGrounded(f.value, f.evidence, haystack)) {
                f.status = CandidateCard.INFERRED;
                f.confidence = Math.min(f.confidence == null ? 0.5 : f.confidence, 0.5);
                card.addIssue(CandidateCard.INFERRED, labels[i], 'Value "' + f.value + '" could not be verified verbatim in the CV text.', f.evidence, 'MEDIUM');
            }
        }
        for (CandidateCard.Skill s : card.skills) {
            if (s.status == CandidateCard.FOUND && !isGrounded(s.name, s.evidence, haystack)) {
                s.status = CandidateCard.INFERRED;
                card.addIssue(CandidateCard.INFERRED, 'skills', 'Skill "' + s.name + '" not found verbatim in the CV.', s.evidence, 'LOW');
            }
        }
        return card;
    }

    /** Value or its evidence must appear in the source text (case/whitespace-insensitive). */
    public static Boolean isGrounded(String value, String evidence, String squashedSource) {
        if (String.isNotBlank(evidence) && squashedSource.contains(squash(evidence))) { return true; }
        if (String.isNotBlank(value) && squashedSource.contains(squash(value))) { return true; }
        return false;
    }

    public static String squash(String s) {
        return s == null ? '' : s.toLowerCase().replaceAll('[^a-z0-9@+]', '');
    }
}
