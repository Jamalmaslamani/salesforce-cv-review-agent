/**
 * Transparent, rule-based candidate scoring and recommendation.
 *
 * Score (0-100) = sum of four weighted criteria (weights in CV_Agent_Setting__mdt):
 *   Required skills (45%) : listed skill = 1.0 credit, skill only inferred from experience = 0.5, absent = 0
 *   Experience      (25%) : computed years / required years (capped at 1). Uses the TIMELINE, not the claim.
 *   Nice-to-have    (15%) : same credit rules as required skills
 *   Data confidence (15%) : completeness of the CV, minus penalties for HIGH/MEDIUM issues (conflicts, gaps)
 * Knock-out rule: a candidate missing any required skill entirely cannot be a "Strong Match".
 *
 * Why not let the LLM score? Scores must be reproducible, explainable and comparable across
 * candidates and over time (Scoring_Version__c is stamped on every bookmark). The LLM may help
 * *explain* - it never decides the number.
 */
public with sharing class CandidateScoringService {
    public static final String STRONG = 'Strong Match';
    public static final String POSSIBLE = 'Possible Match';
    public static final String WEAK = 'Weak Match';

    public class Criterion {
        @AuraEnabled public String name;
        @AuraEnabled public Decimal weight;      // 0-1
        @AuraEnabled public Decimal rawScore;    // 0-1
        @AuraEnabled public Decimal points;      // weight * raw * 100
        @AuraEnabled public Decimal maxPoints;
        @AuraEnabled public String explanation;
    }

    public class CandidateEvaluation {
        @AuraEnabled public Id candidateId;
        @AuraEnabled public String candidateName;
        @AuraEnabled public String headline;
        @AuraEnabled public Decimal score;
        @AuraEnabled public Integer rank;
        @AuraEnabled public String tier;
        @AuraEnabled public Decimal years;
        @AuraEnabled public List<Criterion> breakdown = new List<Criterion>();
        @AuraEnabled public List<String> matchedRequired = new List<String>();
        @AuraEnabled public List<String> inferredRequired = new List<String>();
        @AuraEnabled public List<String> missingRequired = new List<String>();
        @AuraEnabled public List<String> matchedNiceToHave = new List<String>();
        @AuraEnabled public List<String> strengths = new List<String>();
        @AuraEnabled public List<String> concerns = new List<String>();
        @AuraEnabled public List<String> interviewFocus = new List<String>();
        @AuraEnabled public String reasoning;
        @AuraEnabled public Integer highIssues = 0;
    }

    public class EvaluationResponse {
        @AuraEnabled public RoleProfile role;
        @AuraEnabled public List<CandidateEvaluation> evaluations = new List<CandidateEvaluation>();
        @AuraEnabled public List<Id> recommendedIds = new List<Id>();
        @AuraEnabled public String recommendation;
        @AuraEnabled public List<String> tradeOffs = new List<String>();
        @AuraEnabled public Boolean noStrongMatch = false;
        @AuraEnabled public String scoringVersion;
        @AuraEnabled public Datetime evaluatedAt;
        @AuraEnabled public String correlationId;
    }

    public static EvaluationResponse evaluate(RoleProfile role, List<Id> candidateIds) {
        Long t0 = System.currentTimeMillis();
        List<Candidate__c> recs;
        if (candidateIds == null || candidateIds.isEmpty()) {
            recs = [SELECT Id, Name, Card_JSON__c, Raw_Text__c FROM Candidate__c WITH USER_MODE ORDER BY Name LIMIT 50];
        } else {
            recs = [SELECT Id, Name, Card_JSON__c, Raw_Text__c FROM Candidate__c WHERE Id IN :candidateIds WITH USER_MODE LIMIT 50];
        }
        if (recs.isEmpty()) { throw new ScoringException('No candidates to evaluate. Upload CVs first.'); }

        AgentSettings settings = AgentSettings.get();
        EvaluationResponse resp = new EvaluationResponse();
        resp.role = role;
        resp.scoringVersion = settings.scoringVersion;
        resp.evaluatedAt = System.now();
        resp.correlationId = AgentLogger.correlationId();

        for (Candidate__c c : recs) {
            CandidateCard card = CandidateCard.fromJson(c.Card_JSON__c);
            if (card == null) { card = new HeuristicCvParser().parse(c.Raw_Text__c); }
            resp.evaluations.add(score(c.Id, c.Name, card, role, settings));
        }
        rank(resp.evaluations);
        recommend(resp, settings);

        List<String> summary = new List<String>();
        for (CandidateEvaluation e : resp.evaluations) { summary.add(e.rank + '. ' + e.candidateName + ' ' + e.score + ' (' + e.tier + ')'); }
        AgentLogger.log('EVALUATE', AgentLogger.SUCCESS, null, JSON.serialize(role),
            resp.recommendation + '\n' + String.join(summary, '\n') + '\nversion=' + resp.scoringVersion, System.currentTimeMillis() - t0);
        AgentLogger.flush();
        return resp;
    }

    // ------------------------------------------------------------------ scoring
    @TestVisible
    private static CandidateEvaluation score(Id candidateId, String name, CandidateCard card, RoleProfile role, AgentSettings s) {
        CandidateEvaluation ev = new CandidateEvaluation();
        ev.candidateId = candidateId;
        ev.candidateName = name;
        ev.headline = CandidateCard.valueOf(card.headline);

        Decimal totalW = s.weightRequired + s.weightExperience + s.weightNiceToHave + s.weightConfidence;
        if (totalW <= 0) { totalW = 1; }

        // 1. Required skills
        Decimal reqCredit = 0;
        for (String skill : role.requiredSkills) {
            CandidateCard.Skill sk = card.findSkill(skill);
            if (sk == null) { ev.missingRequired.add(skill); }
            else if (sk.status == CandidateCard.INFERRED) { ev.inferredRequired.add(skill); reqCredit += 0.5; }
            else { ev.matchedRequired.add(skill); reqCredit += 1; }
        }
        Decimal reqRaw = role.requiredSkills.isEmpty() ? 1 : reqCredit / role.requiredSkills.size();
        ev.breakdown.add(criterion('Required skills', s.weightRequired / totalW, reqRaw,
            role.requiredSkills.isEmpty() ? 'No required skills specified.' :
            ev.matchedRequired.size() + '/' + role.requiredSkills.size() + ' listed' +
            (ev.matchedRequired.isEmpty() ? '' : ' (' + String.join(ev.matchedRequired, ', ') + ')') +
            (ev.inferredRequired.isEmpty() ? '' : '; half credit for inferred: ' + String.join(ev.inferredRequired, ', ')) +
            (ev.missingRequired.isEmpty() ? '' : '; missing: ' + String.join(ev.missingRequired, ', ')) + '.'));

        // 2. Experience (computed timeline, never the self-claim)
        String yv = CandidateCard.valueOf(card.totalYearsExperience);
        ev.years = yv == null ? null : Decimal.valueOf(yv);
        Decimal expRaw; String expWhy;
        if (ev.years == null) {
            expRaw = 0; expWhy = 'Experience could not be determined from the CV dates.';
        } else if (role.minYears == null || role.minYears == 0) {
            expRaw = 1; expWhy = ev.years + ' years; no minimum required.';
        } else {
            expRaw = Math.min(1, ev.years / role.minYears);
            expWhy = ev.years + ' years vs ' + role.minYears + ' required' + (expRaw >= 1 ? ' (meets requirement).' : ' (below requirement).');
        }
        if (card.totalYearsExperience != null && card.totalYearsExperience.status == CandidateCard.CONFLICT) {
            expWhy += ' The CV claims "' + card.claimedYearsExperience?.evidence + '" - the lower, date-based figure is used.';
        } else if (card.totalYearsExperience != null && card.totalYearsExperience.status == CandidateCard.INFERRED) {
            expWhy += ' Lower bound: some roles have no dates.';
        }
        ev.breakdown.add(criterion('Experience', s.weightExperience / totalW, expRaw, expWhy));

        // 3. Nice-to-have
        Decimal niceCredit = 0;
        List<String> niceInferred = new List<String>();
        for (String skill : role.niceToHaveSkills) {
            CandidateCard.Skill sk = card.findSkill(skill);
            if (sk == null) { continue; }
            if (sk.status == CandidateCard.INFERRED) { niceCredit += 0.5; niceInferred.add(skill); } else { niceCredit += 1; ev.matchedNiceToHave.add(skill); }
        }
        Decimal niceRaw = role.niceToHaveSkills.isEmpty() ? 1 : niceCredit / role.niceToHaveSkills.size();
        ev.breakdown.add(criterion('Nice-to-have skills', s.weightNiceToHave / totalW, niceRaw,
            role.niceToHaveSkills.isEmpty() ? 'None specified.' :
            (ev.matchedNiceToHave.size() + niceInferred.size()) + '/' + role.niceToHaveSkills.size() + ' present' +
            (ev.matchedNiceToHave.isEmpty() ? '' : ' (' + String.join(ev.matchedNiceToHave, ', ') + ')') +
            (niceInferred.isEmpty() ? '' : '; inferred: ' + String.join(niceInferred, ', ')) + '.'));

        // 4. Data confidence
        Integer high = 0; Integer medium = 0;
        for (CandidateCard.Issue i : card.issues) {
            if (i.severity == 'HIGH') { high++; } else if (i.severity == 'MEDIUM') { medium++; }
        }
        ev.highIssues = high;
        Decimal penalty = Math.min(1, high * 0.25 + medium * 0.1);
        Decimal confRaw = ((card.completeness == null ? 0 : card.completeness) / 100) * 0.5 + (1 - penalty) * 0.5;
        ev.breakdown.add(criterion('Data confidence', s.weightConfidence / totalW, confRaw,
            'CV ' + card.completeness + '% complete; ' + high + ' high and ' + medium + ' medium severity issue(s).'));

        Decimal total = 0;
        for (Criterion c : ev.breakdown) { total += c.points; }
        ev.score = total.setScale(1);

        // Tier, with knock-out rule
        if (ev.score >= s.strongThreshold && ev.missingRequired.isEmpty()) { ev.tier = STRONG; }
        else if (ev.score >= s.possibleThreshold) { ev.tier = POSSIBLE; }
        else { ev.tier = WEAK; }

        explain(ev, card, role);
        return ev;
    }

    private static Criterion criterion(String name, Decimal weight, Decimal raw, String why) {
        Criterion c = new Criterion();
        c.name = name;
        c.weight = weight.setScale(2);
        c.rawScore = raw.setScale(2);
        c.maxPoints = (weight * 100).setScale(1);
        c.points = (weight * raw * 100).setScale(1);
        c.explanation = why;
        return c;
    }

    private static void explain(CandidateEvaluation ev, CandidateCard card, RoleProfile role) {
        if (!ev.matchedRequired.isEmpty()) { ev.strengths.add('Lists required skills: ' + String.join(ev.matchedRequired, ', ')); }
        if (ev.years != null && role.minYears != null && ev.years >= role.minYears) { ev.strengths.add(ev.years + ' years of experience (' + role.minYears + ' required)'); }
        if (!ev.matchedNiceToHave.isEmpty()) { ev.strengths.add('Bonus skills: ' + String.join(ev.matchedNiceToHave, ', ')); }
        if (card.certifications != null && !card.certifications.isEmpty()) {
            List<String> certs = new List<String>();
            for (CandidateCard.Certification c : card.certifications) { if (!certs.contains(c.name)) { certs.add(c.name); } }
            ev.strengths.add(certs.size() + ' certification(s): ' + String.join(certs, ', '));
        }

        if (!ev.missingRequired.isEmpty()) {
            ev.concerns.add('No evidence of required skill(s): ' + String.join(ev.missingRequired, ', '));
            for (String m : ev.missingRequired) { ev.interviewFocus.add('Probe ' + m + ': not mentioned anywhere in the CV.'); }
        }
        if (!ev.inferredRequired.isEmpty()) {
            ev.concerns.add('Only indirect evidence for: ' + String.join(ev.inferredRequired, ', '));
            for (String m : ev.inferredRequired) {
                CandidateCard.Skill sk = card.findSkill(m);
                ev.interviewFocus.add('Ask for a concrete ' + m + ' example - CV only says: "' + (sk?.evidence ?? '').abbreviate(100) + '"');
            }
        }
        if (ev.years == null) { ev.concerns.add('Total experience cannot be computed from the CV.'); }
        else if (role.minYears != null && ev.years < role.minYears) { ev.concerns.add('Experience below requirement (' + ev.years + ' vs ' + role.minYears + ' years)'); }
        for (CandidateCard.Issue i : card.issues) {
            if (i.severity == 'HIGH' || (i.severity == 'MEDIUM' && i.type != CandidateCard.INFERRED)) {
                ev.concerns.add(i.message);
                ev.interviewFocus.add('Clarify: ' + i.message);
            }
        }

        ev.reasoning = ev.candidateName + ' scores ' + ev.score + '/100 (' + ev.tier + '). ';
        List<String> parts = new List<String>();
        for (Criterion c : ev.breakdown) { parts.add(c.name + ' ' + c.points + '/' + c.maxPoints + ' - ' + c.explanation); }
        ev.reasoning += String.join(parts, ' ');
        if (ev.tier != STRONG && ev.missingRequired.size() > 0 && ev.score >= AgentSettings.get().strongThreshold) {
            ev.reasoning += ' Capped below Strong Match because a required skill is missing.';
        }
    }

    // ------------------------------------------------------------------ ranking & recommendation
    private static void rank(List<CandidateEvaluation> evs) {
        // score desc; ties -> fewer high-severity issues -> more years
        for (Integer i = 1; i < evs.size(); i++) {
            CandidateEvaluation key = evs[i]; Integer j = i - 1;
            while (j >= 0 && better(key, evs[j])) { evs[j + 1] = evs[j]; j--; }
            evs[j + 1] = key;
        }
        for (Integer i = 0; i < evs.size(); i++) { evs[i].rank = i + 1; }
    }

    private static Boolean better(CandidateEvaluation a, CandidateEvaluation b) {
        if (a.score != b.score) { return a.score > b.score; }
        if (a.highIssues != b.highIssues) { return a.highIssues < b.highIssues; }
        return (a.years ?? 0) > (b.years ?? 0);
    }

    private static void recommend(EvaluationResponse resp, AgentSettings s) {
        List<CandidateEvaluation> strongOnes = new List<CandidateEvaluation>();
        for (CandidateEvaluation e : resp.evaluations) { if (e.tier == STRONG && strongOnes.size() < 3) { strongOnes.add(e); } }
        CandidateEvaluation top = resp.evaluations[0];

        if (!strongOnes.isEmpty()) {
            List<String> names = new List<String>();
            for (CandidateEvaluation e : strongOnes) { names.add(e.candidateName + ' (' + e.score + ')'); resp.recommendedIds.add(e.candidateId); }
            resp.recommendation = 'Recommended for "' + resp.role.title + '": ' + String.join(names, ', ') + '. ' +
                top.candidateName + ' ranks first: ' + firstOr(top.strengths, 'best overall coverage') + '.';
        } else {
            resp.noStrongMatch = true;
            resp.recommendedIds.add(top.candidateId);
            resp.recommendation = 'No strong match for "' + resp.role.title + '". Best available option: ' + top.candidateName +
                ' (' + top.score + ', ' + top.tier + '). Validate before progressing: ' +
                (top.interviewFocus.isEmpty() ? 'overall fit for the role' : String.join(subList(top.interviewFocus, 3), ' | ')) + '.';
        }

        // Trade-offs between the top two: where does #2 beat #1?
        if (resp.evaluations.size() > 1) {
            CandidateEvaluation second = resp.evaluations[1];
            for (Integer i = 0; i < top.breakdown.size(); i++) {
                Criterion a = top.breakdown[i]; Criterion b = second.breakdown[i];
                if (b.points > a.points) {
                    resp.tradeOffs.add(second.candidateName + ' is stronger on ' + a.name.toLowerCase() + ' (' + b.points + ' vs ' + a.points + ' pts): ' + b.explanation);
                }
            }
            Decimal gap = top.score - second.score;
            if (gap < 5) {
                resp.tradeOffs.add('The top two are within ' + gap + ' points - treat the ranking as a tie and let interviews decide.');
            }
            if (top.highIssues > 0) {
                resp.tradeOffs.add(top.candidateName + ' ranks first but has ' + top.highIssues + ' high-severity data issue(s) that need validating.');
            }
        }
    }

    private static String firstOr(List<String> l, String fallback) { return l.isEmpty() ? fallback : l[0]; }

    private static List<String> subList(List<String> l, Integer n) {
        List<String> out = new List<String>();
        for (Integer i = 0; i < l.size() && i < n; i++) { out.add(l[i]); }
        return out;
    }

    public class ScoringException extends Exception {}
}
