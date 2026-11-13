/**
 * The Candidate Card: a structured, self-describing view of one CV.
 *
 * Design principle: every value carries its own provenance. A recruiter (or the agent)
 * must always be able to tell whether a value was FOUND verbatim in the CV, INFERRED
 * from indirect evidence, is MISSING, or is in CONFLICT with another statement.
 * The card is serialised to Candidate__c.Card_JSON__c; key values are also promoted
 * to real fields for filtering/reporting.
 */
public with sharing class CandidateCard {
    public static final String FOUND = 'FOUND';
    public static final String INFERRED = 'INFERRED';
    public static final String MISSING = 'MISSING';
    public static final String CONFLICT = 'CONFLICT';

    public static final String SCHEMA_VERSION = '1.0';

    @AuraEnabled public String schemaVersion = SCHEMA_VERSION;
    @AuraEnabled public String extractionMethod;

    @AuraEnabled public CardField name;
    @AuraEnabled public CardField headline;
    @AuraEnabled public CardField email;
    @AuraEnabled public CardField phone;
    @AuraEnabled public CardField location;
    @AuraEnabled public CardField summary;
    /** Years computed from the employment timeline (overlaps merged). */
    @AuraEnabled public CardField totalYearsExperience;
    /** Years the candidate claims in their summary (may disagree with the timeline). */
    @AuraEnabled public CardField claimedYearsExperience;

    @AuraEnabled public List<Skill> skills = new List<Skill>();
    @AuraEnabled public List<Experience> experience = new List<Experience>();
    @AuraEnabled public List<Education> education = new List<Education>();
    @AuraEnabled public List<Certification> certifications = new List<Certification>();

    /** Everything a recruiter should double-check: missing, inferred, conflicting or ambiguous data. */
    @AuraEnabled public List<Issue> issues = new List<Issue>();
    @AuraEnabled public Decimal completeness = 0;

    public class CardField {
        @AuraEnabled public String value;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal confidence;
        /** Verbatim snippet(s) of the CV supporting this value. */
        @AuraEnabled public String evidence;
        @AuraEnabled public String note;
        public CardField() {}
        public CardField(String value, String status, Decimal confidence, String evidence) {
            this.value = value; this.status = status; this.confidence = confidence; this.evidence = evidence;
        }
        public Boolean isKnown() { return status == FOUND || status == INFERRED || status == CONFLICT; }
    }

    public class Skill {
        @AuraEnabled public String name;
        /** FOUND = listed by candidate; INFERRED = only mentioned in experience text. */
        @AuraEnabled public String status;
        @AuraEnabled public String evidence;
        public Skill() {}
        public Skill(String name, String status, String evidence) { this.name = name; this.status = status; this.evidence = evidence; }
    }

    public class Experience {
        @AuraEnabled public String title;
        @AuraEnabled public String company;
        @AuraEnabled public String startDate;   // yyyy-MM (null when missing)
        @AuraEnabled public String endDate;     // yyyy-MM or null when current
        @AuraEnabled public Boolean isCurrent = false;
        @AuraEnabled public Integer months;
        @AuraEnabled public String datePrecision; // MONTH | YEAR | NONE
        @AuraEnabled public String evidence;
        @AuraEnabled public List<String> highlights = new List<String>();
    }

    public class Education {
        @AuraEnabled public String degree;
        @AuraEnabled public String institution;
        @AuraEnabled public String year;
        @AuraEnabled public String evidence;
    }

    public class Certification {
        @AuraEnabled public String name;
        @AuraEnabled public String year;
        @AuraEnabled public String status;
        @AuraEnabled public String evidence;
    }

    public class Issue {
        /** MISSING | INFERRED | CONFLICT | AMBIGUOUS */
        @AuraEnabled public String type;
        @AuraEnabled public String field;
        @AuraEnabled public String message;
        @AuraEnabled public String evidence;
        /** HIGH issues should be validated before any hiring decision. */
        @AuraEnabled public String severity;
        public Issue() {}
        public Issue(String type, String field, String message, String evidence, String severity) {
            this.type = type; this.field = field; this.message = message; this.evidence = evidence; this.severity = severity;
        }
    }

    // ---------------------------------------------------------------- helpers
    public void addIssue(String type, String field, String message, String evidence, String severity) {
        issues.add(new Issue(type, field, message, evidence, severity));
    }

    public Integer countIssues(String type) {
        Integer n = 0;
        for (Issue i : issues) { if (i.type == type) { n++; } }
        return n;
    }

    public Boolean hasSkill(String skillName) {
        return findSkill(skillName) != null;
    }

    public Skill findSkill(String skillName) {
        String key = SkillCatalog.normalize(skillName);
        for (Skill s : skills) {
            if (SkillCatalog.normalize(s.name) == key) { return s; }
        }
        return null;
    }

    public static String valueOf(CardField f) {
        return f == null || f.status == MISSING ? null : f.value;
    }

    public String toJson() { return JSON.serializePretty(this, true); }

    public static CandidateCard fromJson(String jsonText) {
        if (String.isBlank(jsonText)) { return null; }
        return (CandidateCard) JSON.deserialize(jsonText, CandidateCard.class);
    }
}
