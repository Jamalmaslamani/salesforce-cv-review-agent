@IsTest
private class CandidateQueryServiceTest {
    @TestSetup
    static void setup() {
        User u = TestDataFactory.createAgentUser();
        System.runAs(u) { TestDataFactory.ingestAll(); }
    }

    private static CandidateQueryService.Answer ask(String q) {
        return CandidateQueryService.ask(q, null);
    }

    @IsTest
    static void singleCandidateFieldQuestions() {
        System.runAs(TestDataFactory.agentUser()) {
            CandidateQueryService.Answer a = ask('What is Sara\'s email?');
            Assert.isTrue(a.answer.contains('sara.haddad@example.com'), a.answer);
            Assert.isFalse(a.answer.contains('Omar'), 'scoped to the named candidate');
            Assert.areEqual(1, a.citations.size());

            a = ask('How can I contact Lina?');
            Assert.isTrue(a.answer.contains('not stated in the CV'), 'missing data is reported, not invented: ' + a.answer);
            Assert.areEqual('MEDIUM', a.confidence);

            a = ask('What email does Omar use?');
            Assert.isTrue(a.answer.contains('conflict'), a.answer);
        }
    }

    @IsTest
    static void crossCandidateSkillQuestion() {
        System.runAs(TestDataFactory.agentUser()) {
            CandidateQueryService.Answer a = ask('Which candidates know LWC and Apex?');
            Assert.isTrue(a.answer.contains('Sara Haddad'), a.answer);
            Assert.isTrue(a.answer.contains('Partial or inferred'), 'Omar only has inferred LWC: ' + a.answer);
            Assert.isTrue(a.answer.contains('No evidence in the CV'), a.answer);
            Assert.isFalse(a.citations.isEmpty());
        }
    }

    @IsTest
    static void yearsUseTimelineNotClaims() {
        System.runAs(TestDataFactory.agentUser()) {
            CandidateQueryService.Answer a = ask('Who has at least 8 years of experience?');
            Assert.isTrue(a.answer.contains('Daniel Reyes'), a.answer);
            Assert.isTrue(a.answer.contains('CONFLICT'), 'Omar claims 12+ but has ~8.4: ' + a.answer);
            Assert.isFalse(a.answer.contains('Priya'), a.answer);
        }
    }

    @IsTest
    static void otherIntents() {
        System.runAs(TestDataFactory.agentUser()) {
            Assert.isTrue(ask('Where is Daniel based?').answer.contains('Austin'));
            Assert.isTrue(ask('What did Priya study?').answer.contains('Data Science'));
            Assert.isTrue(ask('Is Daniel certified?').answer.contains('conflicting years'));
            Assert.isTrue(ask('What are the risks with Omar?').answer.contains('12+'));
            Assert.isTrue(ask('Tell me about Sara').answer.contains('Nimbus Cloud Solutions'));
            Assert.isTrue(ask('Who knows Salesforce?').answer.contains('Priya'), 'inferred Salesforce exposure');
        }
    }

    @IsTest
    static void unknownTopicsAreNotHallucinated() {
        System.runAs(TestDataFactory.agentUser()) {
            CandidateQueryService.Answer a = ask('Who speaks Mandarin fluently?');
            Assert.areEqual('NONE', a.confidence);
            Assert.isTrue(a.citations.isEmpty());

            a = ask('Who worked with scratch orgs?');
            Assert.areEqual('LOW', a.confidence, 'keyword retrieval returns excerpts, flagged as low confidence');
            Assert.isTrue(a.answer.contains('Sara'), a.answer);
        }
        try { CandidateQueryService.ask('  ', null); Assert.fail(); } catch (CandidateQueryService.AgentQueryException e) { Assert.isNotNull(e); }
    }

    @IsTest
    static void llmAnswersAreCitationChecked() {
        System.runAs(TestDataFactory.agentUser()) {
            Id saraId = [SELECT Id FROM Candidate__c WHERE Name = 'Sara Haddad'].Id;
            String resp = 'Sure: {"answer":"Sara led an event-driven order sync [C1:L9].","citations":[' +
                '{"ref":"C1:L1","quote":"Sara Haddad"},{"ref":"C1:L99","quote":"invented"},{"ref":"C1:L1","quote":"Not in the line"}],' +
                '"confidence":"high","insufficientEvidence":false}';
            LlmProviderFactory.testProvider = new TestDataFactory.StubLlm(resp);
            CandidateQueryService.Answer a = CandidateQueryService.ask('What integrations has Sara built?', new List<Id>{ saraId });
            Assert.areEqual('LLM (grounded)', a.mode);
            Assert.areEqual(1, a.citations.size(), 'only the verifiable citation survives');
            Assert.isTrue(a.warnings[0].contains('2 citation'), String.valueOf(a.warnings));

            LlmProviderFactory.testProvider = new TestDataFactory.StubLlm('{"answer":"Not in the CVs","citations":[],"confidence":"NONE","insufficientEvidence":true}');
            Assert.areEqual('NONE', CandidateQueryService.ask('Hobbies?', new List<Id>{ saraId }).confidence);

            LlmProviderFactory.testProvider = new TestDataFactory.StubLlm('{"answer":"Probably great","citations":[],"confidence":"HIGH"}');
            Assert.areEqual('LOW', CandidateQueryService.ask('Is she good?', new List<Id>{ saraId }).confidence, 'uncited answers are downgraded');

            LlmProviderFactory.testProvider = new TestDataFactory.StubLlm(null);
            CandidateQueryService.Answer fb = CandidateQueryService.ask('What is Sara\'s email?', new List<Id>{ saraId });
            Assert.areEqual('Rules', fb.mode, 'falls back to rules when the model is down');
        }
    }
}
