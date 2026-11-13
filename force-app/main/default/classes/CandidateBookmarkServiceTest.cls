@IsTest
private class CandidateBookmarkServiceTest {
    @TestSetup
    static void setup() {
        User u = TestDataFactory.createAgentUser();
        System.runAs(u) { TestDataFactory.ingestAll(); }
    }

    @IsTest
    static void bookmarkSnapshotsEvaluation() {
        System.runAs(TestDataFactory.agentUser()) {
            RoleProfile role = new RoleProfile();
            role.title = 'Senior Salesforce Developer';
            role.requiredSkills = new List<String>{ 'Apex', 'LWC', 'REST APIs' };
            role.minYears = 5;
            CandidateScoringService.EvaluationResponse res = CandidateScoringService.evaluate(role, null);
            CandidateScoringService.CandidateEvaluation daniel;
            for (CandidateScoringService.CandidateEvaluation e : res.evaluations) { if (e.candidateName == 'Daniel Reyes') { daniel = e; } }

            Test.startTest();
            // Go through the controller to also cover JSON (de)serialisation from the UI
            Id bmId = CvAgentController.bookmark(daniel.candidateId, JSON.serialize(daniel), JSON.serialize(role),
                'Strong architect; check REST depth.', res.evaluations.size(), res.scoringVersion, res.correlationId);
            Test.stopTest();

            Candidate_Bookmark__c b = [SELECT Candidate__c, Role_Title__c, Score__c, Fit_Tier__c, Reasoning__c, Candidate_Overview__c,
                Recruiter_Notes__c, Evaluated_At__c, Scoring_Version__c, Correlation_Id__c, Interview_Focus__c, Rank__c, Compared_Count__c,
                Score_Breakdown_JSON__c FROM Candidate_Bookmark__c WHERE Id = :bmId];
            Assert.areEqual(daniel.candidateId, b.Candidate__c);
            Assert.areEqual('Senior Salesforce Developer', b.Role_Title__c);
            Assert.areEqual(daniel.score, b.Score__c);
            Assert.areEqual('Strong architect; check REST depth.', b.Recruiter_Notes__c);
            Assert.isTrue(b.Candidate_Overview__c.contains('daniel.reyes@example.com'));
            Assert.isTrue(b.Reasoning__c.contains('Concerns'));
            Assert.isTrue(b.Interview_Focus__c.contains('REST APIs'), 'inferred required skill becomes an interview topic');
            Assert.areEqual(res.correlationId, b.Correlation_Id__c, 'bookmark traceable to the evaluation log');
            Assert.areEqual(5, b.Compared_Count__c);
            Assert.isNotNull(b.Evaluated_At__c);
            Assert.isTrue(b.Score_Breakdown_JSON__c.contains('Required skills'));
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Agent_Log__c WHERE Action__c = 'BOOKMARK']);
    }

    @IsTest
    static void rejectsMismatchedEvaluation() {
        System.runAs(TestDataFactory.agentUser()) {
            Map<String, Id> ids = new Map<String, Id>();
            for (Candidate__c c : [SELECT Id, Name FROM Candidate__c]) { ids.put(c.Name.substringBefore(' '), c.Id); }
            CandidateScoringService.CandidateEvaluation ev = new CandidateScoringService.CandidateEvaluation();
            ev.candidateId = ids.get('Sara');
            RoleProfile role = new RoleProfile(); role.title = 'X'; role.minYears = 1;
            try {
                CandidateBookmarkService.create(ids.get('Omar'), ev, role, null, 1, 'v', 'c');
                Assert.fail();
            } catch (CandidateBookmarkService.BookmarkException e) {
                Assert.isTrue(e.getMessage().contains('does not belong'));
            }
            try {
                CvAgentController.bookmark(ids.get('Omar'), JSON.serialize(ev), JSON.serialize(role), null, 1, 'v', 'c');
                Assert.fail();
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
    }
}
