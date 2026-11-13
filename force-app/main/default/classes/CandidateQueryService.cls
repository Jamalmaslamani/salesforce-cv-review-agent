/**
 * Natural-language Q&A over candidate CVs.
 *
 * Grounding contract (applies to both modes):
 *  - Answers are built only from the Candidate Card and the CV text.
 *  - Every factual statement carries a citation (candidate + verbatim CV snippet).
 *  - When the CVs do not contain the answer, the agent says so instead of guessing.
 *
 * Modes:
 *  - Rules (default): intent routing (contact, location, education, certifications, years, skills,
 *    risks, overview) + keyword retrieval fallback. Deterministic and fully explainable.
 *  - LLM: the CVs are passed as numbered lines; the model must answer in JSON with line references.
 *    Each citation is verified against the actual line; unverifiable citations are removed and the
 *    answer is downgraded. If the LLM fails, the rules engine answers instead.
 */
public with sharing class CandidateQueryService {
    public static final Integer MAX_CANDIDATES = 25;

    public class Citation {
        @AuraEnabled public Id candidateId;
        @AuraEnabled public String candidateName;
        @AuraEnabled public String snippet;
        public Citation(Id candidateId, String candidateName, String snippet) {
            this.candidateId = candidateId; this.candidateName = candidateName; this.snippet = snippet;
        }
    }

    public class Answer {
        @AuraEnabled public String question;
        @AuraEnabled public String answer;
        @AuraEnabled public List<Citation> citations = new List<Citation>();
        /** HIGH | MEDIUM | LOW | NONE (NONE = the CVs do not answer this) */
        @AuraEnabled public String confidence = 'HIGH';
        @AuraEnabled public String mode = 'Rules';
        @AuraEnabled public List<String> warnings = new List<String>();
        @AuraEnabled public Integer candidatesConsidered;
    }

    @TestVisible
    private class Ctx {
        Candidate__c rec;
        CandidateCard card;
        String first;
        Ctx(Candidate__c rec) {
            this.rec = rec;
            this.card = CandidateCard.fromJson(rec.Card_JSON__c);
            if (this.card == null) { this.card = new HeuristicCvParser().parse(rec.Raw_Text__c); }
            this.first = rec.Name.substringBefore(' ').toLowerCase();
        }
    }

    public static Answer ask(String question, List<Id> candidateIds) {
        if (String.isBlank(question)) { throw new AgentQueryException('Please enter a question.'); }
        Long t0 = System.currentTimeMillis();
        List<Ctx> scope = load(candidateIds);
        Answer a;
        if (scope.isEmpty()) {
            a = new Answer();
            a.answer = 'There are no candidates to search yet. Upload CVs first.';
            a.confidence = 'NONE';
        } else {
            LlmProvider llm = LlmProviderFactory.get();
            if (llm != null) {
                try {
                    a = askLlm(llm, question, scope);
                } catch (Exception e) {
                    AgentLogger.error('QUERY_LLM', null, question, e);
                    a = askRules(question, scope);
                    a.warnings.add('The AI model was unavailable; answered with the rule-based engine.');
                }
            } else {
                a = askRules(question, scope);
            }
        }
        a.question = question;
        a.candidatesConsidered = scope.size();
        AgentLogger.log('QUERY', a.confidence == 'NONE' ? AgentLogger.WARNING : AgentLogger.SUCCESS,
            scope.size() == 1 ? scope[0].rec.Id : null, question,
            a.answer + '\n[confidence=' + a.confidence + ', citations=' + a.citations.size() + ']', System.currentTimeMillis() - t0);
        AgentLogger.flush();
        return a;
    }

    private static List<Ctx> load(List<Id> candidateIds) {
        List<Candidate__c> recs;
        if (candidateIds == null || candidateIds.isEmpty()) {
            recs = [SELECT Id, Name, Card_JSON__c, Raw_Text__c, Total_Years_Experience__c FROM Candidate__c WITH USER_MODE ORDER BY Name LIMIT :MAX_CANDIDATES];
        } else {
            recs = [SELECT Id, Name, Card_JSON__c, Raw_Text__c, Total_Years_Experience__c FROM Candidate__c WHERE Id IN :candidateIds WITH USER_MODE ORDER BY Name LIMIT :MAX_CANDIDATES];
        }
        List<Ctx> out = new List<Ctx>();
        for (Candidate__c c : recs) { out.add(new Ctx(c)); }
        return out;
    }

    // =====================================================================  RULES ENGINE
    @TestVisible
    private static Answer askRules(String question, List<Ctx> scope) {
        String q = question.toLowerCase();
        // Narrow to candidates named in the question ("What is Sara's email?")
        List<Ctx> targets = new List<Ctx>();
        for (Ctx c : scope) {
            if (Pattern.compile('\\b' + Pattern.quote(c.first) + '\\b').matcher(q).find() || q.contains(c.rec.Name.toLowerCase())) { targets.add(c); }
        }
        Boolean named = !targets.isEmpty();
        if (!named) { targets = scope; }

        if (has(q, new List<String>{ 'email', 'phone', 'contact', 'reach' })) { return fieldAnswer(targets, new List<String>{ 'email', 'phone' }, q); }
        if (has(q, new List<String>{ 'where', 'location', 'based', 'live', 'relocat', 'city', 'country' })) { return fieldAnswer(targets, new List<String>{ 'location' }, q); }
        if (has(q, new List<String>{ 'degree', 'education', 'universit', 'studied', 'graduat', 'study' })) { return educationAnswer(targets); }
        if (has(q, new List<String>{ 'certif', 'certified', 'credential' })) { return certAnswer(targets, q); }
        if (has(q, new List<String>{ 'risk', 'concern', 'red flag', 'gap', 'missing', 'conflict', 'inconsisten', 'verify', 'validate' })) { return issuesAnswer(targets); }
        List<String> skills = skillsInQuestion(q);
        if (q.contains('year') || q.contains('senior') || q.contains('most experience') || q.contains('experienced')) {
            if (skills.isEmpty()) { return yearsAnswer(targets, q); }
        }
        if (!skills.isEmpty()) { return skillAnswer(targets, skills, q); }
        if (named && has(q, new List<String>{ 'tell me', 'summar', 'overview', 'who is', 'about', 'profile', 'background' })) { return overviewAnswer(targets); }
        return retrievalAnswer(targets, q);
    }

    private static Answer fieldAnswer(List<Ctx> targets, List<String> fields, String q) {
        Answer a = new Answer();
        List<String> lines = new List<String>();
        Boolean anyMissing = false;
        for (Ctx c : targets) {
            List<String> parts = new List<String>();
            for (String f : fields) {
                if (f == 'phone' && q.contains('email') && !q.contains('phone') && !q.contains('contact')) { continue; }
                if (f == 'email' && q.contains('phone') && !q.contains('email') && !q.contains('contact')) { continue; }
                CandidateCard.CardField cf = f == 'email' ? c.card.email : (f == 'phone' ? c.card.phone : c.card.location);
                if (cf == null || cf.status == CandidateCard.MISSING) {
                    parts.add(f + ': not stated in the CV'); anyMissing = true;
                } else {
                    String v = f + ': ' + cf.value;
                    if (cf.status == CandidateCard.CONFLICT) { v += ' (conflict - ' + cf.note + ')'; }
                    parts.add(v);
                    a.citations.add(new Citation(c.rec.Id, c.rec.Name, cf.evidence));
                }
            }
            lines.add('• ' + c.rec.Name + ' - ' + String.join(parts, '; '));
        }
        a.answer = String.join(lines, '\n');
        if (anyMissing) { a.confidence = 'MEDIUM'; a.warnings.add('Some requested details are missing from the CVs; nothing was guessed.'); }
        return a;
    }

    private static Answer educationAnswer(List<Ctx> targets) {
        Answer a = new Answer();
        List<String> lines = new List<String>();
        for (Ctx c : targets) {
            if (c.card.education == null || c.card.education.isEmpty()) {
                lines.add('• ' + c.rec.Name + ' - no education listed in the CV.');
                a.confidence = 'MEDIUM';
                continue;
            }
            List<String> eds = new List<String>();
            for (CandidateCard.Education e : c.card.education) {
                eds.add(e.degree + (e.institution != null ? ', ' + e.institution : '') + (e.year != null ? ' (' + e.year + ')' : ' (year not stated)'));
                a.citations.add(new Citation(c.rec.Id, c.rec.Name, e.evidence));
            }
            lines.add('• ' + c.rec.Name + ' - ' + String.join(eds, '; '));
        }
        a.answer = String.join(lines, '\n');
        return a;
    }

    private static Answer certAnswer(List<Ctx> targets, String q) {
        Answer a = new Answer();
        List<String> lines = new List<String>();
        Set<String> ignore = new Set<String>{ 'certified', 'certification', 'certifications', 'certificate', 'certificates', 'salesforce', 'credential', 'credentials', 'hold', 'holds' };
        for (Ctx c : targets) { ignore.add(c.first); ignore.add(c.rec.Name.substringAfterLast(' ').toLowerCase()); }
        List<String> keywords = meaningfulWords(q, ignore);
        for (Ctx c : targets) {
            List<String> certs = new List<String>();
            for (CandidateCard.Certification ct : c.card.certifications) {
                if (!keywords.isEmpty() && !containsAny(ct.name.toLowerCase(), keywords)) { continue; }
                certs.add(ct.name + (ct.year != null ? ' (' + ct.year + ')' : '') + (ct.status == CandidateCard.CONFLICT ? ' [listed with conflicting years]' : ''));
                a.citations.add(new Citation(c.rec.Id, c.rec.Name, ct.evidence));
            }
            if (!certs.isEmpty()) { lines.add('• ' + c.rec.Name + ' - ' + String.join(certs, '; ')); }
            else if (targets.size() <= 3) { lines.add('• ' + c.rec.Name + ' - no matching certifications in the CV.'); }
        }
        a.answer = lines.isEmpty() ? 'None of the CVs list a matching certification.' : String.join(lines, '\n');
        if (lines.isEmpty()) { a.confidence = 'NONE'; }
        a.warnings.add('Certifications are self-reported; verify them on the issuer\'s verification site.');
        return a;
    }

    private static Answer issuesAnswer(List<Ctx> targets) {
        Answer a = new Answer();
        List<String> lines = new List<String>();
        for (Ctx c : targets) {
            List<String> items = new List<String>();
            for (CandidateCard.Issue i : c.card.issues) {
                if (i.severity == 'LOW' && i.type == CandidateCard.INFERRED) { continue; }
                items.add('[' + i.type + ', ' + i.severity + '] ' + i.message);
                if (String.isNotBlank(i.evidence)) { a.citations.add(new Citation(c.rec.Id, c.rec.Name, i.evidence)); }
            }
            lines.add(c.rec.Name + ': ' + (items.isEmpty() ? 'no significant data issues found.' : '\n   - ' + String.join(items, '\n   - ')));
        }
        a.answer = 'Points to validate (from the CV analysis):\n' + String.join(lines, '\n');
        return a;
    }

    private static Answer yearsAnswer(List<Ctx> targets, String q) {
        Answer a = new Answer();
        Decimal threshold;
        Matcher m = Pattern.compile('(\\d{1,2})\\s*\\+?\\s*(years|yrs)').matcher(q);
        if (m.find()) { threshold = Decimal.valueOf(m.group(1)); }
        List<Ctx> sorted = sortByYears(targets);
        List<String> lines = new List<String>();
        for (Ctx c : sorted) {
            CandidateCard.CardField y = c.card.totalYearsExperience;
            if (y == null || y.status == CandidateCard.MISSING) { lines.add('• ' + c.rec.Name + ' - experience cannot be determined from the CV.'); continue; }
            Decimal years = Decimal.valueOf(y.value);
            if (threshold != null && years < threshold) { continue; }
            String line = '• ' + c.rec.Name + ' - ' + years + ' years (from dated roles)';
            if (y.status == CandidateCard.INFERRED) { line += ' - lower bound, some roles are undated'; }
            if (c.card.claimedYearsExperience != null) {
                line += '; claims "' + c.card.claimedYearsExperience.evidence + '"' + (c.card.claimedYearsExperience.status == CandidateCard.CONFLICT ? ' (CONFLICT with timeline)' : '');
                a.citations.add(new Citation(c.rec.Id, c.rec.Name, c.card.claimedYearsExperience.evidence));
            }
            for (CandidateCard.Experience e : c.card.experience) {
                if (e.evidence != null) { a.citations.add(new Citation(c.rec.Id, c.rec.Name, e.evidence)); break; }
            }
            lines.add(line);
        }
        if (lines.isEmpty()) {
            a.answer = 'No candidate has ' + threshold + '+ years of dated experience in their CV.';
            a.confidence = 'MEDIUM';
        } else {
            a.answer = (threshold != null ? 'Candidates with at least ' + threshold + ' years:\n' : 'Experience (computed from employment dates, overlaps merged):\n') + String.join(lines, '\n');
        }
        a.warnings.add('Years are computed from the dates in each CV, not from the candidate\'s own claim.');
        return a;
    }

    private static Answer skillAnswer(List<Ctx> targets, List<String> skills, String q) {
        Answer a = new Answer();
        Boolean requireAll = q.contains(' and ') || q.contains(' both ');
        List<String> yes = new List<String>(); List<String> partial = new List<String>(); List<String> no = new List<String>();
        for (Ctx c : targets) {
            List<String> stated = new List<String>(); List<String> inferred = new List<String>(); List<String> absent = new List<String>();
            for (String s : skills) {
                CandidateCard.Skill sk = c.card.findSkill(s);
                if (sk == null) { absent.add(s); continue; }
                if (sk.status == CandidateCard.INFERRED) { inferred.add(s + ' (inferred from: "' + sk.evidence.abbreviate(90) + '")'); }
                else { stated.add(s); }
                a.citations.add(new Citation(c.rec.Id, c.rec.Name, sk.evidence));
            }
            Boolean match = requireAll ? absent.isEmpty() : (stated.size() + inferred.size()) > 0;
            String detail = c.rec.Name + ' - ' + (stated.isEmpty() ? '' : 'listed: ' + String.join(stated, ', ')) +
                (inferred.isEmpty() ? '' : (stated.isEmpty() ? '' : '; ') + String.join(inferred, '; ')) +
                (absent.isEmpty() ? '' : ((stated.isEmpty() && inferred.isEmpty()) ? '' : '; ') + 'no evidence of ' + String.join(absent, ', '));
            if (match && inferred.isEmpty()) { yes.add('• ' + detail); }
            else if (match || !inferred.isEmpty() || !stated.isEmpty()) { partial.add('• ' + detail); }
            else { no.add(c.rec.Name); }
        }
        List<String> out = new List<String>();
        if (!yes.isEmpty()) { out.add('Clear evidence:\n' + String.join(yes, '\n')); }
        if (!partial.isEmpty()) { out.add('Partial or inferred evidence (verify in interview):\n' + String.join(partial, '\n')); }
        if (!no.isEmpty()) { out.add('No evidence in the CV: ' + String.join(no, ', ')); }
        a.answer = String.join(out, '\n\n');
        if (yes.isEmpty() && partial.isEmpty()) { a.confidence = 'NONE'; a.answer = 'None of the CVs mention ' + String.join(skills, ' / ') + '.'; }
        else if (yes.isEmpty()) { a.confidence = 'MEDIUM'; }
        return a;
    }

    private static Answer overviewAnswer(List<Ctx> targets) {
        Answer a = new Answer();
        List<String> blocks = new List<String>();
        for (Ctx c : targets) {
            CandidateCard k = c.card;
            List<String> stated = new List<String>();
            for (CandidateCard.Skill s : k.skills) { if (s.status == CandidateCard.FOUND) { stated.add(s.name); } }
            String b = c.rec.Name + ' - ' + (CandidateCard.valueOf(k.headline) ?? 'headline not stated') +
                '\n   Experience: ' + (CandidateCard.valueOf(k.totalYearsExperience) ?? '?') + ' years across ' + k.experience.size() + ' roles' +
                (k.experience.isEmpty() ? '' : '; most recent: ' + k.experience[0].title + (k.experience[0].company != null ? ' at ' + k.experience[0].company : '')) +
                '\n   Skills (listed): ' + (stated.isEmpty() ? 'none listed' : String.join(stated, ', ')) +
                '\n   Data quality: ' + k.completeness + '% complete, ' + k.countIssues(CandidateCard.CONFLICT) + ' conflict(s), ' + k.countIssues(CandidateCard.MISSING) + ' missing item(s).';
            blocks.add(b);
            if (k.summary != null && k.summary.evidence != null) { a.citations.add(new Citation(c.rec.Id, c.rec.Name, k.summary.evidence)); }
            if (!k.experience.isEmpty()) { a.citations.add(new Citation(c.rec.Id, c.rec.Name, k.experience[0].evidence)); }
        }
        a.answer = String.join(blocks, '\n\n');
        return a;
    }

    /** Fallback: keyword retrieval over CV lines. Returns excerpts rather than a synthesised claim. */
    private static Answer retrievalAnswer(List<Ctx> targets, String q) {
        Answer a = new Answer();
        List<String> words = meaningfulWords(q, new Set<String>());
        if (words.isEmpty()) {
            a.answer = 'Could you be more specific? Try asking about skills, experience, education, certifications, contact details or risks.';
            a.confidence = 'NONE';
            return a;
        }
        List<String> hits = new List<String>();
        for (Ctx c : targets) {
            if (c.rec.Raw_Text__c == null) { continue; }
            Integer best = 0; String bestLine;
            for (String line : c.rec.Raw_Text__c.split('\n')) {
                Integer score = 0;
                String l = line.toLowerCase();
                for (String w : words) { if (l.contains(w)) { score++; } }
                if (score > best) { best = score; bestLine = line.trim(); }
            }
            if (best > 0 && (Decimal.valueOf(best) / words.size()) >= 0.5) {
                hits.add('• ' + c.rec.Name + ': "' + bestLine + '"');
                a.citations.add(new Citation(c.rec.Id, c.rec.Name, bestLine));
            }
        }
        if (hits.isEmpty()) {
            a.answer = 'I could not find anything in the CVs about that. The CVs do not mention it, so I will not guess.';
            a.confidence = 'NONE';
        } else {
            a.answer = 'I did not find a structured answer, but these CV passages look relevant:\n' + String.join(hits, '\n');
            a.confidence = 'LOW';
            a.warnings.add('Keyword match only - read the excerpts before relying on them.');
        }
        return a;
    }

    // =====================================================================  LLM MODE
    @TestVisible
    private static final String LLM_SYSTEM =
        'You answer recruiter questions about candidates using ONLY the CV lines provided. ' +
        'Each line is prefixed with a reference like [C2:L14]. Rules: (1) Every factual claim must cite at least one reference. ' +
        '(2) If the CVs do not contain the answer, say so and set "insufficientEvidence": true - never guess or use outside knowledge. ' +
        '(3) Point out conflicting or missing information explicitly. ' +
        'Respond with ONE JSON object: {"answer": string, "citations": [{"ref": "C1:L3", "quote": "exact text from that line"}], ' +
        '"confidence": "HIGH"|"MEDIUM"|"LOW"|"NONE", "insufficientEvidence": boolean}';

    private class LlmCitation { String ref; String quote; }
    private class LlmAnswer { String answer; List<LlmCitation> citations; String confidence; Boolean insufficientEvidence; }

    @TestVisible
    private static Answer askLlm(LlmProvider llm, String question, List<Ctx> scope) {
        Map<String, String> lineByRef = new Map<String, String>();
        Map<String, Ctx> ctxByRef = new Map<String, Ctx>();
        List<String> blocks = new List<String>();
        for (Integer ci = 0; ci < scope.size(); ci++) {
            Ctx c = scope[ci];
            List<String> numbered = new List<String>();
            List<String> lines = (c.rec.Raw_Text__c ?? '').left(8000).split('\n');
            for (Integer li = 0; li < lines.size(); li++) {
                if (String.isBlank(lines[li])) { continue; }
                String ref = 'C' + (ci + 1) + ':L' + (li + 1);
                lineByRef.put(ref, lines[li]);
                ctxByRef.put(ref, c);
                numbered.add('[' + ref + '] ' + lines[li]);
            }
            blocks.add('### Candidate C' + (ci + 1) + ': ' + c.rec.Name + ' (computed experience: ' +
                (CandidateCard.valueOf(c.card.totalYearsExperience) ?? 'unknown') + ' years; known data issues: ' + c.card.issues.size() + ')\n' + String.join(numbered, '\n'));
        }
        LlmRequest req = new LlmRequest(LLM_SYSTEM, 'CVs:\n' + String.join(blocks, '\n\n') + '\n\nQuestion: ' + question);
        req.maxTokens = 1500;
        LlmAnswer parsed = (LlmAnswer) JSON.deserialize(LlmJson.extractObject(llm.complete(req)), LlmAnswer.class);

        Answer a = new Answer();
        a.mode = 'LLM (grounded)';
        a.answer = parsed.answer;
        a.confidence = String.isBlank(parsed.confidence) ? 'MEDIUM' : parsed.confidence.toUpperCase();
        Integer dropped = 0;
        if (parsed.citations != null) {
            for (LlmCitation cit : parsed.citations) {
                String line = cit.ref == null ? null : lineByRef.get(cit.ref.replace('[', '').replace(']', '').trim());
                if (line != null && (String.isBlank(cit.quote) || CardValidator.squash(line).contains(CardValidator.squash(cit.quote)))) {
                    Ctx c = ctxByRef.get(cit.ref.replace('[', '').replace(']', '').trim());
                    a.citations.add(new Citation(c.rec.Id, c.rec.Name, line.trim()));
                } else {
                    dropped++;
                }
            }
        }
        if (dropped > 0) { a.warnings.add(dropped + ' citation(s) from the model did not match the CV text and were removed.'); }
        if (parsed.insufficientEvidence == true) {
            a.confidence = 'NONE';
        } else if (a.citations.isEmpty()) {
            a.confidence = 'LOW';
            a.warnings.add('The answer could not be tied to any CV line - treat it as unverified.');
        }
        return a;
    }

    // =====================================================================  helpers
    private static final Set<String> STOP = new Set<String>{
        'the','a','an','of','in','on','for','to','is','are','was','were','who','what','which','does','do','did','has','have','had',
        'with','and','or','any','candidate','candidates','cv','cvs','their','them','they','he','she','his','her','me','tell','about',
        'how','many','much','there','this','that','can','could','would','should','be','been','at','by','from','as','it','its','i','we','you','show','list','give','all','most'
    };

    private static List<String> meaningfulWords(String q, Set<String> extraStop) {
        List<String> out = new List<String>();
        for (String w : q.toLowerCase().replaceAll('[^a-z0-9+#./ ]', ' ').split('\\s+')) {
            if (w.length() > 1 && !STOP.contains(w) && !extraStop.contains(w)) { out.add(w.removeEnd('\'s')); }
        }
        return out;
    }

    private static List<String> skillsInQuestion(String q) {
        List<String> out = new List<String>();
        Map<String, String> aliases = SkillCatalog.aliases();
        for (String alias : aliases.keySet()) {
            if (alias == 'salesforce' || alias == 'js' || alias == 'node' && !q.contains('node ')) { continue; }
            if (Pattern.compile('(?<![a-z0-9])' + Pattern.quote(alias) + '(?![a-z0-9])').matcher(q).find()) {
                String canonical = aliases.get(alias);
                if (!out.contains(canonical)) { out.add(canonical); }
            }
        }
        // "salesforce" on its own only counts when no more specific Salesforce skill was asked for
        if (out.isEmpty() && Pattern.compile('\\bsalesforce\\b').matcher(q).find()) { out.add('Salesforce'); }
        return out;
    }

    private static List<Ctx> sortByYears(List<Ctx> items) {
        List<Ctx> sorted = new List<Ctx>(items);
        for (Integer i = 1; i < sorted.size(); i++) {
            Ctx key = sorted[i]; Integer j = i - 1;
            while (j >= 0 && years(sorted[j]) < years(key)) { sorted[j + 1] = sorted[j]; j--; }
            sorted[j + 1] = key;
        }
        return sorted;
    }

    private static Decimal years(Ctx c) {
        String v = CandidateCard.valueOf(c.card.totalYearsExperience);
        return v == null ? -1 : Decimal.valueOf(v);
    }

    private static Boolean has(String q, List<String> keys) { return containsAny(q, keys); }

    private static Boolean containsAny(String s, List<String> keys) {
        for (String k : keys) { if (s.contains(k)) { return true; } }
        return false;
    }

    public class AgentQueryException extends Exception {}
}
