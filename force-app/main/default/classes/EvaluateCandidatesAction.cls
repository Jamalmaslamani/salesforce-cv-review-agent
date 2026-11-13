/** Agentforce / Flow action: rank candidates for a role and explain the recommendation. */
public with sharing class EvaluateCandidatesAction {
    public class Request {
        @InvocableVariable(label='Role Title' required=true)
        public String roleTitle;
        @InvocableVariable(label='Required Skills' description='Comma-separated, e.g. "Apex, LWC, SOQL"')
        public String requiredSkills;
        @InvocableVariable(label='Nice-to-have Skills' description='Comma-separated')
        public String niceToHaveSkills;
        @InvocableVariable(label='Minimum Years of Experience')
        public Decimal minYears;
        @InvocableVariable(label='Candidate Ids' description='Optional: only compare these candidates')
        public List<Id> candidateIds;
    }
    public class Response {
        @InvocableVariable(label='Recommendation') public String recommendation;
        @InvocableVariable(label='Ranking') public String ranking;
        @InvocableVariable(label='Evaluation JSON' description='Full machine-readable evaluation (for bookmarking)') public String evaluationJson;
    }

    @InvocableMethod(label='Evaluate Candidates for Role' description='Scores and ranks candidates with transparent, rule-based criteria and explains trade-offs.' category='CV Review Agent')
    public static List<Response> run(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            RoleProfile role = new RoleProfile();
            role.title = r.roleTitle;
            role.requiredSkills = RoleProfile.splitCsv(r.requiredSkills);
            role.niceToHaveSkills = RoleProfile.splitCsv(r.niceToHaveSkills);
            role.minYears = r.minYears;
            role = RoleProfile.fromJson(JSON.serialize(role)); // reuse validation
            CandidateScoringService.EvaluationResponse ev = CandidateScoringService.evaluate(role, r.candidateIds);
            Response res = new Response();
            res.recommendation = ev.recommendation + (ev.tradeOffs.isEmpty() ? '' : '\nTrade-offs: ' + String.join(ev.tradeOffs, ' '));
            List<String> lines = new List<String>();
            for (CandidateScoringService.CandidateEvaluation e : ev.evaluations) {
                lines.add(e.rank + '. ' + e.candidateName + ' - ' + e.score + ' (' + e.tier + ')' +
                    (e.concerns.isEmpty() ? '' : ' | concerns: ' + String.join(e.concerns, '; ')));
            }
            res.ranking = String.join(lines, '\n');
            res.evaluationJson = JSON.serialize(ev);
            out.add(res);
        }
        return out;
    }
}
