/**
 * Creates a Candidate_Bookmark__c: a self-contained, immutable snapshot of an evaluation
 * (overview + score + reasoning + role criteria + timestamp) plus the recruiter's notes.
 * Snapshotting (instead of only linking to the candidate) keeps the record auditable even if
 * the CV is re-uploaded or the scoring model changes later (Scoring_Version__c).
 */
public with sharing class CandidateBookmarkService {

    public static Id create(Id candidateId, CandidateScoringService.CandidateEvaluation ev, RoleProfile role,
                            String notes, Integer comparedCount, String scoringVersion, String correlationId) {
        if (candidateId == null || ev == null || role == null) {
            throw new BookmarkException('A candidate, an evaluation and a role are required to create a bookmark.');
        }
        if (ev.candidateId != candidateId) {
            throw new BookmarkException('The evaluation does not belong to this candidate.');
        }
        List<Candidate__c> recs = [SELECT Id, Name, Card_JSON__c FROM Candidate__c WHERE Id = :candidateId WITH USER_MODE LIMIT 1];
        if (recs.isEmpty()) { throw new BookmarkException('Candidate not found or you do not have access to it.'); }
        CandidateCard card = CandidateCard.fromJson(recs[0].Card_JSON__c);

        Candidate_Bookmark__c b = new Candidate_Bookmark__c(
            Candidate__c = candidateId,
            Role_Title__c = role.title.left(255),
            Role_Criteria_JSON__c = JSON.serializePretty(role).left(32768),
            Score__c = ev.score,
            Rank__c = ev.rank,
            Compared_Count__c = comparedCount,
            Fit_Tier__c = ev.tier,
            Reasoning__c = buildReasoning(ev).left(32768),
            Score_Breakdown_JSON__c = JSON.serializePretty(ev.breakdown).left(131072),
            Candidate_Overview__c = buildOverview(recs[0].Name, card).left(32768),
            Interview_Focus__c = String.join(ev.interviewFocus, '\n').left(32768),
            Recruiter_Notes__c = notes == null ? null : notes.trim().left(32768),
            Status__c = 'New',
            Evaluated_At__c = System.now(),
            Scoring_Version__c = scoringVersion,
            Correlation_Id__c = correlationId
        );
        // Snapshot fields are read-only for users (FLS) so the evaluation cannot be altered later.
        // We therefore check object-level create access explicitly and write in system mode.
        // Record access to the candidate was already enforced by the USER_MODE query above.
        if (!Schema.SObjectType.Candidate_Bookmark__c.isCreateable()) {
            throw new BookmarkException('You do not have permission to create bookmarks.');
        }
        Database.insert(b, AccessLevel.SYSTEM_MODE);
        AgentLogger.log('BOOKMARK', AgentLogger.SUCCESS, candidateId, role.title + (String.isBlank(notes) ? '' : ' | notes: ' + notes),
            'Bookmark ' + b.Id + ' score=' + ev.score + ' tier=' + ev.tier + ' evaluationCorrelation=' + correlationId, null);
        AgentLogger.flush();
        return b.Id;
    }

    private static String buildReasoning(CandidateScoringService.CandidateEvaluation ev) {
        List<String> out = new List<String>{ ev.reasoning };
        if (!ev.strengths.isEmpty()) { out.add('\nStrengths:\n- ' + String.join(ev.strengths, '\n- ')); }
        if (!ev.concerns.isEmpty()) { out.add('\nConcerns:\n- ' + String.join(ev.concerns, '\n- ')); }
        return String.join(out, '\n');
    }

    @TestVisible
    private static String buildOverview(String name, CandidateCard card) {
        if (card == null) { return name; }
        List<String> stated = new List<String>(); List<String> inferred = new List<String>();
        for (CandidateCard.Skill s : card.skills) {
            if (s.status == CandidateCard.INFERRED) { inferred.add(s.name); } else { stated.add(s.name); }
        }
        List<String> certs = new List<String>();
        for (CandidateCard.Certification c : card.certifications) { certs.add(c.name + (c.year != null ? ' (' + c.year + ')' : '')); }
        List<String> roles = new List<String>();
        for (CandidateCard.Experience e : card.experience) {
            roles.add(e.title + (e.company != null ? ' @ ' + e.company : '') + ' [' + (e.startDate ?? '?') + ' - ' + (e.isCurrent == true ? 'present' : (e.endDate ?? '?')) + ']');
        }
        return name + ' - ' + (CandidateCard.valueOf(card.headline) ?? 'no headline') +
            '\nEmail: ' + (CandidateCard.valueOf(card.email) ?? 'not stated') + ' | Phone: ' + (CandidateCard.valueOf(card.phone) ?? 'not stated') +
            ' | Location: ' + (CandidateCard.valueOf(card.location) ?? 'not stated') +
            '\nExperience: ' + (CandidateCard.valueOf(card.totalYearsExperience) ?? '?') + ' years (computed)' +
            '\nRoles: ' + (roles.isEmpty() ? 'none listed' : String.join(roles, '; ')) +
            '\nSkills (listed): ' + String.join(stated, ', ') +
            (inferred.isEmpty() ? '' : '\nSkills (inferred): ' + String.join(inferred, ', ')) +
            '\nCertifications: ' + (certs.isEmpty() ? 'none listed' : String.join(certs, ', ')) +
            '\nData quality: ' + card.completeness + '% complete, ' + card.countIssues(CandidateCard.CONFLICT) + ' conflict(s), ' +
            card.countIssues(CandidateCard.MISSING) + ' missing item(s), ' + card.countIssues(CandidateCard.INFERRED) + ' inferred item(s).';
    }

    public class BookmarkException extends Exception {}
}
