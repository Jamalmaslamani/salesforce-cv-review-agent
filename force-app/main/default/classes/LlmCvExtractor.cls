/**
 * LLM-based extraction (used when the provider is Anthropic). The model must return the
 * CandidateCard JSON schema with per-field status + verbatim evidence. Output is then:
 *   1. parsed defensively (bad JSON -> fall back to the heuristic parser, never fail the upload)
 *   2. grounded by CardValidator (unsupported FOUND values are downgraded)
 *   3. merged with deterministic timeline checks from the heuristic parser
 */
public with sharing class LlmCvExtractor {
    public static final String METHOD = 'LLM + grounding validation';

    @TestVisible
    private static final String SYSTEM_PROMPT =
        'You extract structured data from CVs for recruiters. Rules:\n' +
        '1. Use ONLY the CV content. Never invent or "fill in" values.\n' +
        '2. For each field set status: FOUND (stated verbatim), INFERRED (implied, explain in note), MISSING (absent), CONFLICT (CV contradicts itself; explain in note).\n' +
        '3. "evidence" must be an exact quote from the CV (max 200 chars).\n' +
        '4. List every gap, inference and contradiction in "issues" with type MISSING|INFERRED|CONFLICT|AMBIGUOUS and severity LOW|MEDIUM|HIGH.\n' +
        '5. Dates as yyyy-MM. Return ONLY one JSON object matching this schema:\n' +
        '{"name":F,"headline":F,"email":F,"phone":F,"location":F,"summary":F,"claimedYearsExperience":F,' +
        '"skills":[{"name","status","evidence"}],"experience":[{"title","company","startDate","endDate","isCurrent","evidence","highlights":[]}],' +
        '"education":[{"degree","institution","year","evidence"}],"certifications":[{"name","year","status","evidence"}],' +
        '"issues":[{"type","field","message","evidence","severity"}]} where F = {"value","status","confidence","evidence","note"}';

    public static CandidateCard extract(LlmProvider provider, String rawText, Blob pdf) {
        LlmRequest req = new LlmRequest(SYSTEM_PROMPT,
            pdf != null ? 'Extract the Candidate Card from the attached CV.' : 'Extract the Candidate Card from this CV:\n<cv>\n' + rawText + '\n</cv>');
        if (pdf != null) { req.document = pdf; req.documentMediaType = 'application/pdf'; }
        req.maxTokens = 4000;
        String response = provider.complete(req);
        CandidateCard llmCard = (CandidateCard) JSON.deserialize(LlmJson.extractObject(response), CandidateCard.class);
        llmCard.extractionMethod = METHOD;
        if (llmCard.issues == null) { llmCard.issues = new List<CandidateCard.Issue>(); }
        if (llmCard.skills == null) { llmCard.skills = new List<CandidateCard.Skill>(); }

        if (String.isBlank(rawText)) { return llmCard; } // nothing to cross-check against (e.g. compressed PDF)
        // Deterministic checks on top of the model: timeline math is not left to the LLM.
        CandidateCard rules = new HeuristicCvParser().parse(rawText);
        if (rules.totalYearsExperience != null) { llmCard.totalYearsExperience = rules.totalYearsExperience; }
        if (llmCard.experience == null || llmCard.experience.isEmpty()) { llmCard.experience = rules.experience; }
        if (llmCard.education == null) { llmCard.education = rules.education; }
        if (llmCard.certifications == null) { llmCard.certifications = rules.certifications; }
        for (CandidateCard.Issue i : rules.issues) {
            if (i.type == CandidateCard.CONFLICT || i.field == 'experience' || i.field == 'yearsExperience') { llmCard.issues.add(i); }
        }
        llmCard.completeness = rules.completeness;
        return CardValidator.validate(llmCard, rawText);
    }
}
