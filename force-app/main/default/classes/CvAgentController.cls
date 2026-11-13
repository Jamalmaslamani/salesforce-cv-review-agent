/**
 * Thin @AuraEnabled facade for the cvReviewAgent LWC. No business logic here: it validates
 * input, delegates to the services, and converts failures into user-friendly messages
 * (full details go to the Agent Log, never to the browser).
 */
public with sharing class CvAgentController {

    public class CandidateView {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String fileName;
        @AuraEnabled public String message;
        @AuraEnabled public Datetime extractedAt;
        @AuraEnabled public CandidateCard card;
    }

    public class AgentInfo {
        @AuraEnabled public String provider;
        @AuraEnabled public String scoringVersion;
        @AuraEnabled public Map<String, Decimal> weights;
    }

    @AuraEnabled(cacheable=true)
    public static AgentInfo getAgentInfo() {
        AgentSettings s = AgentSettings.get();
        AgentInfo i = new AgentInfo();
        i.provider = s.provider;
        i.scoringVersion = s.scoringVersion;
        i.weights = new Map<String, Decimal>{ 'Required skills' => s.weightRequired, 'Experience' => s.weightExperience,
            'Nice-to-have' => s.weightNiceToHave, 'Data confidence' => s.weightConfidence };
        return i;
    }

    @AuraEnabled
    public static List<CandidateView> getCandidates() {
        try {
            List<CandidateView> out = new List<CandidateView>();
            for (Candidate__c c : [
                SELECT Id, Name, Extraction_Status__c, Source_File_Name__c, Extraction_Message__c, Extracted_At__c, Card_JSON__c
                FROM Candidate__c WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 100
            ]) {
                CandidateView v = new CandidateView();
                v.id = c.Id; v.name = c.Name; v.status = c.Extraction_Status__c; v.fileName = c.Source_File_Name__c;
                v.message = c.Extraction_Message__c; v.extractedAt = c.Extracted_At__c;
                v.card = CandidateCard.fromJson(c.Card_JSON__c);
                out.add(v);
            }
            return out;
        } catch (Exception e) {
            throw fail('LOAD', e, null);
        }
    }

    @AuraEnabled
    public static List<CvIngestionService.FileResult> processFiles(List<Id> contentDocumentIds) {
        try {
            return CvIngestionService.ingest(contentDocumentIds);
        } catch (CvIngestionService.IngestionException e) {
            throw handled(e.getMessage());
        } catch (Exception e) {
            throw fail('INGEST', e, String.valueOf(contentDocumentIds));
        }
    }

    @AuraEnabled
    public static List<Id> createSampleFiles() {
        try {
            return SampleDataService.createSampleFiles();
        } catch (Exception e) {
            throw fail('SAMPLES', e, null);
        }
    }

    @AuraEnabled
    public static CandidateQueryService.Answer ask(String question, List<Id> candidateIds) {
        try {
            return CandidateQueryService.ask(question, candidateIds);
        } catch (CandidateQueryService.AgentQueryException e) {
            throw handled(e.getMessage());
        } catch (Exception e) {
            throw fail('QUERY', e, question);
        }
    }

    @AuraEnabled
    public static CandidateScoringService.EvaluationResponse evaluate(String roleJson, List<Id> candidateIds) {
        try {
            return CandidateScoringService.evaluate(RoleProfile.fromJson(roleJson), candidateIds);
        } catch (RoleProfile.RoleException e) {
            throw handled(e.getMessage());
        } catch (CandidateScoringService.ScoringException e) {
            throw handled(e.getMessage());
        } catch (Exception e) {
            throw fail('EVALUATE', e, roleJson);
        }
    }

    @AuraEnabled
    public static Id bookmark(Id candidateId, String evaluationJson, String roleJson, String notes,
                              Integer comparedCount, String scoringVersion, String correlationId) {
        try {
            CandidateScoringService.CandidateEvaluation ev = (CandidateScoringService.CandidateEvaluation)
                JSON.deserialize(evaluationJson, CandidateScoringService.CandidateEvaluation.class);
            return CandidateBookmarkService.create(candidateId, ev, RoleProfile.fromJson(roleJson), notes, comparedCount, scoringVersion, correlationId);
        } catch (CandidateBookmarkService.BookmarkException e) {
            throw handled(e.getMessage());
        } catch (Exception e) {
            throw fail('BOOKMARK', e, candidateId);
        }
    }

    /** AuraHandledException hides its message server-side unless setMessage is called. */
    private static AuraHandledException handled(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    private static AuraHandledException fail(String action, Exception e, String input) {
        AgentLogger.error(action, null, input, e);
        AgentLogger.flush();
        String msg = 'Something went wrong (' + action.toLowerCase() + '). Reference: ' + AgentLogger.correlationId() + '. ' +
            (e instanceof System.NoAccessException || e.getMessage().contains('access') ? 'You may be missing the "CV Review Agent User" permission set.' : '');
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}
