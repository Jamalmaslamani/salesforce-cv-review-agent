@IsTest
private class HeuristicCvParserTest {

    private static CandidateCard parse(String text) {
        return new HeuristicCvParser(TestDataFactory.AS_OF).parse(text);
    }

    private static Boolean hasIssue(CandidateCard c, String type, String field, String contains) {
        for (CandidateCard.Issue i : c.issues) {
            if (i.type == type && i.field == field && (contains == null || i.message.contains(contains))) { return true; }
        }
        return false;
    }

    @IsTest
    static void cleanCvIsFullyExtracted() {
        CandidateCard c = parse(TestDataFactory.SARA);
        Assert.areEqual('Sara Haddad', c.name.value);
        Assert.areEqual('Senior Salesforce Developer', c.headline.value);
        Assert.areEqual('sara.haddad@example.com', c.email.value);
        Assert.areEqual(CandidateCard.FOUND, c.email.status);
        Assert.areEqual('Beirut, Lebanon', c.location.value);
        Assert.areEqual('8.5', c.totalYearsExperience.value, 'Jun 2018 - Nov 2026, contiguous roles');
        Assert.areEqual(CandidateCard.FOUND, c.claimedYearsExperience.status, '8 claimed vs 8.5 computed is consistent');
        Assert.areEqual(2, c.experience.size());
        Assert.isTrue(c.experience[0].isCurrent);
        Assert.areEqual(3, c.certifications.size());
        Assert.areEqual('2018', c.education[0].year);
        Assert.areEqual(CandidateCard.FOUND, c.findSkill('Lightning Web Components').status, 'alias resolves to LWC');
        Assert.areEqual(100, c.completeness);
        Assert.areEqual(0, c.countIssues(CandidateCard.CONFLICT));
        Assert.areEqual(0, c.countIssues(CandidateCard.MISSING));
    }

    @IsTest
    static void conflictingClaimsAndEmailsAreFlagged() {
        CandidateCard c = parse(TestDataFactory.OMAR);
        Assert.areEqual(CandidateCard.CONFLICT, c.email.status);
        Assert.isTrue(c.email.note.contains('omar.k.dev@gmail.com'));
        Assert.areEqual(CandidateCard.CONFLICT, c.claimedYearsExperience.status, 'claims 12+ but timeline is ~8.4');
        Assert.areEqual('8.4', c.totalYearsExperience.value);
        Assert.isTrue(hasIssue(c, CandidateCard.CONFLICT, 'yearsExperience', '12+'));
        Assert.isTrue(hasIssue(c, 'AMBIGUOUS', 'experience', 'overlap'), 'Jan-Mar 2022 overlap');
        Assert.isTrue(hasIssue(c, 'AMBIGUOUS', 'experience', 'years only'), '2018 - 2019 is year precision');
        Assert.isTrue(hasIssue(c, CandidateCard.MISSING, 'education', 'graduation year'));
        Assert.areEqual(CandidateCard.INFERRED, c.findSkill('LWC').status, 'only mentioned in a bullet');
        Assert.isNull(c.findSkill('Contact: omar.k.dev@gmail.com'), 'footer must not become a skill');
    }

    @IsTest
    static void missingInformationIsExplicit() {
        CandidateCard c = parse(TestDataFactory.LINA);
        Assert.areEqual(CandidateCard.MISSING, c.email.status);
        Assert.areEqual(CandidateCard.MISSING, c.phone.status);
        Assert.areEqual('Amman, Jordan', c.location.value);
        Assert.isTrue(hasIssue(c, CandidateCard.MISSING, 'experience', 'No start date'));
        Assert.areEqual(CandidateCard.INFERRED, c.totalYearsExperience.status, 'lower bound because a role is undated');
        Assert.areEqual('0.6', c.totalYearsExperience.value);
        Assert.isTrue(c.completeness < 100);
    }

    @IsTest
    static void duplicateCertificationsAndGapsAreFlagged() {
        CandidateCard c = parse(TestDataFactory.DANIEL);
        Assert.isTrue(hasIssue(c, CandidateCard.CONFLICT, 'certifications', 'Platform Developer II'));
        Assert.isTrue(hasIssue(c, 'AMBIGUOUS', 'experience', '19 months'));
        Assert.areEqual('12.8', c.totalYearsExperience.value);
        Assert.areEqual(CandidateCard.FOUND, c.claimedYearsExperience.status, '"over 12 years" is consistent');
        Assert.areEqual(CandidateCard.INFERRED, c.findSkill('REST APIs').status);
    }

    @IsTest
    static void emptyTextProducesMissingCardNotException() {
        CandidateCard c = parse('');
        Assert.areEqual(CandidateCard.MISSING, c.name.status);
        Assert.areEqual(CandidateCard.MISSING, c.totalYearsExperience.status);
        Assert.isTrue(c.countIssues(CandidateCard.MISSING) >= 3);
    }

    @IsTest
    static void nameFallsBackToEmailAsInferred() {
        CandidateCard c = parse('john.doe@example.com\nSKILLS\nJava');
        Assert.areEqual('John Doe', c.name.value);
        Assert.areEqual(CandidateCard.INFERRED, c.name.status);
    }

    @IsTest
    static void endBeforeStartIsAConflict() {
        CandidateCard c = parse('Jane Roe\nEXPERIENCE\nDeveloper | Acme | Mar 2022 - Jan 2020');
        Assert.isTrue(hasIssue(c, CandidateCard.CONFLICT, 'experience', 'before start'));
    }

    @IsTest
    static void cardRoundTripsThroughJson() {
        CandidateCard c = parse(TestDataFactory.SARA);
        CandidateCard back = CandidateCard.fromJson(c.toJson());
        Assert.areEqual(c.name.value, back.name.value);
        Assert.areEqual(c.skills.size(), back.skills.size());
        Assert.isNull(CandidateCard.fromJson(''));
    }
}
