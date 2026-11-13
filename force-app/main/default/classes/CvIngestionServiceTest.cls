@IsTest
private class CvIngestionServiceTest {
    @TestSetup
    static void setup() { TestDataFactory.createAgentUser(); }

    @IsTest
    static void ingestsMixedFormatsWithPartialSuccess() {
        System.runAs(TestDataFactory.agentUser()) {
            List<Id> docs = new List<Id>{
                TestDataFactory.createFile('Sara.txt', Blob.valueOf(TestDataFactory.SARA)),
                TestDataFactory.createFile('Jane.pdf', TestDataFactory.simplePdf(TestDataFactory.LINA.split('\n'))),
                TestDataFactory.createFile('Daniel.docx', TestDataFactory.simpleDocx(TestDataFactory.DANIEL.split('\n'))),
                TestDataFactory.createFile('Old.doc', Blob.valueOf('binary'))
            };
            Test.startTest();
            List<CvIngestionService.FileResult> results = CvIngestionService.ingest(docs);
            Test.getEventBus().deliver();
            Test.stopTest();

            Assert.areEqual(4, results.size());
            Integer failed = 0;
            for (CvIngestionService.FileResult r : results) { if (r.status == 'Failed') { failed++; Assert.isTrue(r.message.contains('.doc')); } }
            Assert.areEqual(1, failed, 'only the legacy .doc fails');

            List<Candidate__c> cands = [SELECT Name, Email__c, Total_Years_Experience__c, Card_JSON__c, Source_Document_Id__c, Extraction_Status__c FROM Candidate__c ORDER BY Name];
            Assert.areEqual(3, cands.size());
            Assert.areEqual('Daniel Reyes', cands[0].Name);
            Assert.isNotNull(CandidateCard.fromJson(cands[0].Card_JSON__c));
            Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :cands[0].Id], 'file linked to candidate');
        }
        Assert.isTrue([SELECT COUNT() FROM Agent_Log__c WHERE Action__c = 'INGEST'] >= 4, 'every file is audited');
    }

    @IsTest
    static void reprocessingSameFileUpdatesInsteadOfDuplicating() {
        System.runAs(TestDataFactory.agentUser()) {
            Id doc = TestDataFactory.createFile('Sara.txt', Blob.valueOf(TestDataFactory.SARA));
            CvIngestionService.ingest(new List<Id>{ doc });
            CvIngestionService.ingest(new List<Id>{ doc });
            Assert.areEqual(1, [SELECT COUNT() FROM Candidate__c]);
        }
    }

    @IsTest
    static void sameEmailOnDifferentFilesIsFlaggedAsDuplicate() {
        System.runAs(TestDataFactory.agentUser()) {
            CvIngestionService.ingest(new List<Id>{ TestDataFactory.createFile('Sara_v1.txt', Blob.valueOf(TestDataFactory.SARA)) });
            List<CvIngestionService.FileResult> r = CvIngestionService.ingest(new List<Id>{ TestDataFactory.createFile('Sara_v2.txt', Blob.valueOf(TestDataFactory.SARA)) });
            Assert.isTrue(r[0].message.contains('duplicate'), r[0].message);
        }
    }

    @IsTest
    static void llmPathIsUsedAndFallsBackOnFailure() {
        System.runAs(TestDataFactory.agentUser()) {
            LlmProviderFactory.testProvider = new TestDataFactory.StubLlm(null); // provider outage
            List<CvIngestionService.FileResult> r = CvIngestionService.ingest(new List<Id>{ TestDataFactory.createFile('Sara.txt', Blob.valueOf(TestDataFactory.SARA)) });
            Assert.areEqual('Sara Haddad', r[0].candidateName);
            Assert.isTrue(r[0].message.contains('fell back'), r[0].message);
        }
    }

    @IsTest
    static void validatesInput() {
        try { CvIngestionService.ingest(new List<Id>()); Assert.fail(); } catch (CvIngestionService.IngestionException e) { Assert.isNotNull(e.getMessage()); }
        List<Id> tooMany = new List<Id>();
        for (Integer i = 0; i < 11; i++) { tooMany.add('069000000000000AAA'); }
        try { CvIngestionService.ingest(tooMany); Assert.fail(); } catch (CvIngestionService.IngestionException e) { Assert.isTrue(e.getMessage().contains('at most')); }
    }
}
