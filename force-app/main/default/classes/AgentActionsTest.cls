@IsTest
private class AgentActionsTest {
    @TestSetup
    static void setup() {
        User u = TestDataFactory.createAgentUser();
        System.runAs(u) { TestDataFactory.ingestAll(); }
    }

    @IsTest
    static void invocableActionsForAgentforce() {
        System.runAs(TestDataFactory.agentUser()) {
            AskCandidatesAction.Request q = new AskCandidatesAction.Request();
            q.question = 'Who knows MuleSoft?';
            AskCandidatesAction.Response a = AskCandidatesAction.run(new List<AskCandidatesAction.Request>{ q })[0];
            Assert.isTrue(a.answer.contains('Daniel Reyes'));
            Assert.isTrue(a.answer.contains('Sources:'));

            EvaluateCandidatesAction.Request e = new EvaluateCandidatesAction.Request();
            e.roleTitle = 'Salesforce Architect';
            e.requiredSkills = 'Apex, MuleSoft, Integration Architecture';
            e.minYears = 10;
            EvaluateCandidatesAction.Response r = EvaluateCandidatesAction.run(new List<EvaluateCandidatesAction.Request>{ e })[0];
            Assert.isTrue(r.ranking.startsWith('1. Daniel Reyes'), r.ranking);
            Assert.isNotNull(r.evaluationJson);
        }
    }
}
