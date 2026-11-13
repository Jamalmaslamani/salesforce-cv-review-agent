@IsTest
private class AgentInfrastructureTest {

    private class AnthropicMock implements HttpCalloutMock {
        Integer status;
        AnthropicMock(Integer status) { this.status = status; }
        public HttpResponse respond(HttpRequest req) {
            Assert.isTrue(req.getEndpoint().startsWith('callout:Anthropic_API'));
            Assert.areEqual('2023-06-01', req.getHeader('anthropic-version'));
            HttpResponse r = new HttpResponse();
            r.setStatusCode(status);
            r.setBody(status == 200 ? '{"content":[{"type":"text","text":"hello"}]}' : '{"error":"overloaded"}');
            return r;
        }
    }

    @IsTest
    static void anthropicProviderBuildsRequestAndHandlesErrors() {
        AnthropicLlmProvider p = new AnthropicLlmProvider('Anthropic_API', 'claude-sonnet-4-5');
        LlmRequest req = new LlmRequest('sys', 'hi');
        req.document = Blob.valueOf('%PDF'); req.documentMediaType = 'application/pdf';
        Test.setMock(HttpCalloutMock.class, new AnthropicMock(200));
        Assert.areEqual('hello', p.complete(req));
        Test.setMock(HttpCalloutMock.class, new AnthropicMock(529));
        try { p.complete(req); Assert.fail(); } catch (AnthropicLlmProvider.LlmException e) { Assert.isTrue(e.getMessage().contains('529')); }
    }

    @IsTest
    static void llmExtractionIsGroundedAgainstCvText() {
        String llmOut = '```json\n{"name":{"value":"Sara Haddad","status":"FOUND","confidence":0.99,"evidence":"Sara Haddad"},' +
            '"email":{"value":"sara@invented.com","status":"FOUND","confidence":0.9,"evidence":"sara@invented.com"},' +
            '"skills":[{"name":"Apex","status":"FOUND","evidence":"Apex"},{"name":"Kubernetes","status":"FOUND","evidence":"Kubernetes"}]}\n```';
        TestDataFactory.StubLlm stub = new TestDataFactory.StubLlm(llmOut);
        CandidateCard c = LlmCvExtractor.extract(stub, TestDataFactory.SARA, null);
        Assert.areEqual(CandidateCard.FOUND, c.name.status);
        Assert.areEqual(CandidateCard.INFERRED, c.email.status, 'hallucinated email is downgraded');
        Assert.areEqual(CandidateCard.INFERRED, c.findSkill('Kubernetes').status);
        Assert.isNotNull(c.totalYearsExperience, 'timeline maths comes from the rules engine, not the model');
        Assert.isTrue(Decimal.valueOf(c.totalYearsExperience.value) >= 8.5);
        Assert.isTrue(stub.lastRequest.systemPrompt.contains('Never invent'));
        Assert.areEqual(LlmCvExtractor.METHOD, c.extractionMethod);
    }

    @IsTest
    static void llmJsonHelper() {
        Assert.areEqual('{"a":1}', LlmJson.extractObject('Here you go: {"a":1} thanks'));
        try { LlmJson.extractObject('no json'); Assert.fail(); } catch (LlmJson.LlmJsonException e) { Assert.isNotNull(e); }
    }

    @IsTest
    static void loggerPersistsViaPlatformEvent() {
        Test.startTest();
        AgentLogger.log('TEST', AgentLogger.SUCCESS, null, 'in', 'out', 5L);
        AgentLogger.error('TEST', null, 'in', new DmlException('boom'));
        Assert.areEqual(2, AgentLogger.pending());
        AgentLogger.flush();
        Test.stopTest();
        List<Agent_Log__c> logs = [SELECT Status__c, Correlation_Id__c, Error__c FROM Agent_Log__c ORDER BY Status__c];
        Assert.areEqual(2, logs.size());
        Assert.areEqual(logs[0].Correlation_Id__c, logs[1].Correlation_Id__c, 'one request = one correlation id');
        Assert.isTrue(logs[0].Error__c.contains('boom'));
    }

    @IsTest
    static void settingsAndFactory() {
        AgentSettings s = new AgentSettings();
        s.provider = AgentSettings.PROVIDER_ANTHROPIC;
        AgentSettings.setForTest(s);
        Assert.isTrue(LlmProviderFactory.get() instanceof AnthropicLlmProvider);
        s.provider = AgentSettings.PROVIDER_MOCK;
        Assert.isNull(LlmProviderFactory.get());
    }

    @IsTest
    static void skillCatalog() {
        Assert.areEqual('LWC', SkillCatalog.canonical('Lightning Web Components'));
        Assert.areEqual('Unknown Thing', SkillCatalog.canonical(' Unknown Thing '));
        Map<String, String> m = SkillCatalog.findMentions('Used JavaScript daily.\nWrote SOQL-heavy code.');
        Assert.isTrue(m.containsKey('JavaScript'));
        Assert.isTrue(m.containsKey('SOQL'));
        Assert.isFalse(m.containsKey('Java'), 'word-boundary matching: JavaScript is not Java');
    }
}
