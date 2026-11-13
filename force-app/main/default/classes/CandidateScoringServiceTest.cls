@IsTest
private class CandidateScoringServiceTest {
    @TestSetup
    static void setup() {
        User u = TestDataFactory.createAgentUser();
        System.runAs(u) { TestDataFactory.ingestAll(); }
    }

    private static RoleProfile sfDevRole() {
        RoleProfile r = new RoleProfile();
        r.title = 'Senior Salesforce Developer';
        r.requiredSkills = new List<String>{ 'Apex', 'Lightning Web Components', 'SOQL', 'REST APIs' };
        r.niceToHaveSkills = new List<String>{ 'Agentforce', 'Platform Events', 'CI/CD' };
        r.minYears = 5;
        return RoleProfile.fromJson(JSON.serialize(r));
    }

    @IsTest
    static void ranksAndExplains() {
        System.runAs(TestDataFactory.agentUser()) {
            Test.startTest();
            CandidateScoringService.EvaluationResponse r = CandidateScoringService.evaluate(sfDevRole(), null);
            Test.stopTest();
            Assert.areEqual(5, r.evaluations.size());
            CandidateScoringService.CandidateEvaluation top = r.evaluations[0];
            Assert.areEqual('Sara Haddad', top.candidateName);
            Assert.areEqual(CandidateScoringService.STRONG, top.tier);
            Assert.areEqual(1, top.rank);
            Assert.areEqual(4, top.breakdown.size());
            Assert.isFalse(r.noStrongMatch);
            Assert.isTrue(r.recommendation.contains('Sara Haddad'));
            Assert.areEqual('Daniel Reyes', r.evaluations[1].candidateName);
            Assert.isTrue(r.evaluations[1].inferredRequired.contains('REST APIs'), 'half credit for inferred skill');
            Assert.isFalse(r.evaluations[1].interviewFocus.isEmpty());

            CandidateScoringService.CandidateEvaluation omar;
            for (CandidateScoringService.CandidateEvaluation e : r.evaluations) { if (e.candidateName.startsWith('Omar')) { omar = e; } }
            Assert.areEqual(CandidateScoringService.WEAK, omar.tier);
            Assert.isTrue(String.join(omar.concerns, ' ').contains('12+'), 'conflicting claim surfaced as a concern');
            Assert.isTrue(omar.breakdown[1].explanation.contains('date-based'), omar.breakdown[1].explanation);
            Decimal sum = 0;
            for (CandidateScoringService.Criterion c : top.breakdown) { sum += c.points; }
            Assert.areEqual(top.score, sum.setScale(1), 'score is exactly the sum of the explained parts');
        }
        Assert.isTrue([SELECT COUNT() FROM Agent_Log__c WHERE Action__c = 'EVALUATE'] == 1);
    }

    @IsTest
    static void noStrongMatchReturnsBestOptionAndGaps() {
        System.runAs(TestDataFactory.agentUser()) {
            RoleProfile r = new RoleProfile();
            r.title = 'Data Cloud Engineer';
            r.requiredSkills = new List<String>{ 'Data Cloud', 'Python', 'SQL' };
            r.minYears = 4;
            CandidateScoringService.EvaluationResponse res = CandidateScoringService.evaluate(r, null);
            Assert.isTrue(res.noStrongMatch);
            Assert.areEqual('Priya Nair', res.evaluations[0].candidateName);
            Assert.isTrue(res.recommendation.startsWith('No strong match'), res.recommendation);
            Assert.isTrue(res.recommendation.contains('Data Cloud'), 'the gap to validate is named');
        }
    }

    @IsTest
    static void roleValidation() {
        for (String bad : new List<String>{ '{"title":""}', '{"title":"X"}', '{"title":"X","minYears":99}' }) {
            try { RoleProfile.fromJson(bad); Assert.fail(bad); } catch (RoleProfile.RoleException e) { Assert.isNotNull(e.getMessage()); }
        }
        Assert.areEqual(new List<String>{ 'LWC', 'Apex' }, RoleProfile.splitCsv('Lightning Web Components, apex; LWC'));
    }

    @IsTest
    static void noCandidates() {
        System.runAs(TestDataFactory.agentUser()) {
            delete [SELECT Id FROM Candidate__c];
            RoleProfile r = new RoleProfile(); r.title = 'X'; r.minYears = 1;
            try { CandidateScoringService.evaluate(r, null); Assert.fail(); } catch (CandidateScoringService.ScoringException e) { Assert.isNotNull(e); }
        }
    }
}
