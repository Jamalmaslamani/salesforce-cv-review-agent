@IsTest
private class CvAgentControllerTest {
    @TestSetup
    static void setup() { TestDataFactory.createAgentUser(); }

    @IsTest
    static void endToEndWithSampleCvs() {
        System.runAs(TestDataFactory.agentUser()) {
            Test.startTest();
            List<Id> docs = CvAgentController.createSampleFiles();
            Assert.areEqual(5, docs.size(), 'five sample CVs (3 PDF, 2 DOCX) in the static resource');
            List<CvIngestionService.FileResult> results = CvAgentController.processFiles(docs);
            Test.stopTest();
            for (CvIngestionService.FileResult r : results) {
                Assert.areNotEqual('Failed', r.status, r.fileName + ': ' + r.message);
            }
            List<CvAgentController.CandidateView> views = CvAgentController.getCandidates();
            Assert.areEqual(5, views.size());
            Assert.isNotNull(views[0].card);
            Assert.areEqual(0, CvAgentController.createSampleFiles().size(), 'samples are not loaded twice');

            Assert.isTrue(CvAgentController.ask('Who knows Apex?', null).answer.contains('Sara'));
            CandidateScoringService.EvaluationResponse ev = CvAgentController.evaluate(
                '{"title":"Senior Salesforce Developer","requiredSkills":["Apex","LWC","SOQL","REST APIs"],"niceToHaveSkills":["Agentforce"],"minYears":5}', null);
            Assert.areEqual('Sara Haddad', ev.evaluations[0].candidateName);
            Assert.areEqual('Mock', CvAgentController.getAgentInfo().provider);
        }
    }

    @IsTest
    static void friendlyErrors() {
        System.runAs(TestDataFactory.agentUser()) {
            try { CvAgentController.evaluate('{"title":""}', null); Assert.fail(); } catch (AuraHandledException e) { Assert.isTrue(e.getMessage().contains('title')); }
            try { CvAgentController.ask('', null); Assert.fail(); } catch (AuraHandledException e) { Assert.isNotNull(e.getMessage()); }
            try { CvAgentController.processFiles(new List<Id>()); Assert.fail(); } catch (AuraHandledException e) { Assert.isNotNull(e.getMessage()); }
            try { CvAgentController.evaluate('not json', null); Assert.fail(); } catch (AuraHandledException e) { Assert.isTrue(e.getMessage().contains('Reference')); }
        }
    }
}
