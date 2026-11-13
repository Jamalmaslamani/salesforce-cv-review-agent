/** Agentforce / Flow action: ask a grounded question about candidate CVs. */
public with sharing class AskCandidatesAction {
    public class Request {
        @InvocableVariable(label='Question' description='Natural-language question about the candidates' required=true)
        public String question;
        @InvocableVariable(label='Candidate Ids' description='Optional: limit the question to these Candidate__c records')
        public List<Id> candidateIds;
    }
    public class Response {
        @InvocableVariable(label='Answer' description='Grounded answer with CV citations and confidence')
        public String answer;
        @InvocableVariable(label='Confidence' description='HIGH, MEDIUM, LOW or NONE (CVs do not contain the answer)')
        public String confidence;
    }

    @InvocableMethod(label='Ask CV Review Agent' description='Answers questions about candidates using only their CV content, with citations.' category='CV Review Agent')
    public static List<Response> run(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            CandidateQueryService.Answer a = CandidateQueryService.ask(r.question, r.candidateIds);
            Response res = new Response();
            List<String> cites = new List<String>();
            for (CandidateQueryService.Citation c : a.citations) { cites.add('- ' + c.candidateName + ': "' + c.snippet + '"'); }
            res.answer = a.answer + (cites.isEmpty() ? '' : '\n\nSources:\n' + String.join(cites, '\n')) +
                (a.warnings.isEmpty() ? '' : '\n\nNote: ' + String.join(a.warnings, ' '));
            res.confidence = a.confidence;
            out.add(res);
        }
        return out;
    }
}
