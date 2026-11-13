/**
 * Typed access to CV_Agent_Setting__mdt (record "Default"), with safe in-code defaults
 * so the agent still works if the metadata record is missing. Tests can override via setForTest.
 */
public with sharing class AgentSettings {
    public static final String PROVIDER_MOCK = 'Mock';
    public static final String PROVIDER_ANTHROPIC = 'Anthropic';

    public String provider = PROVIDER_MOCK;
    public String namedCredential = 'Anthropic_API';
    public String model = 'claude-sonnet-4-5';
    public Decimal weightRequired = 0.45;
    public Decimal weightExperience = 0.25;
    public Decimal weightNiceToHave = 0.15;
    public Decimal weightConfidence = 0.15;
    public Decimal strongThreshold = 75;
    public Decimal possibleThreshold = 55;
    public String scoringVersion = 'rules-v1.0';

    private static AgentSettings instance;

    public static AgentSettings get() {
        if (instance == null) {
            instance = new AgentSettings();
            CV_Agent_Setting__mdt rec = CV_Agent_Setting__mdt.getInstance('Default');
            if (rec != null) {
                instance.provider = String.isBlank(rec.Provider__c) ? PROVIDER_MOCK : rec.Provider__c;
                instance.namedCredential = coalesce(rec.Named_Credential__c, instance.namedCredential);
                instance.model = coalesce(rec.Model__c, instance.model);
                instance.weightRequired = rec.Weight_Required_Skills__c != null ? rec.Weight_Required_Skills__c : instance.weightRequired;
                instance.weightExperience = rec.Weight_Experience__c != null ? rec.Weight_Experience__c : instance.weightExperience;
                instance.weightNiceToHave = rec.Weight_Nice_To_Have__c != null ? rec.Weight_Nice_To_Have__c : instance.weightNiceToHave;
                instance.weightConfidence = rec.Weight_Data_Confidence__c != null ? rec.Weight_Data_Confidence__c : instance.weightConfidence;
                instance.strongThreshold = rec.Strong_Threshold__c != null ? rec.Strong_Threshold__c : instance.strongThreshold;
                instance.possibleThreshold = rec.Possible_Threshold__c != null ? rec.Possible_Threshold__c : instance.possibleThreshold;
                instance.scoringVersion = coalesce(rec.Scoring_Version__c, instance.scoringVersion);
            }
        }
        return instance;
    }

    public Boolean useLlm() { return provider == PROVIDER_ANTHROPIC; }

    @TestVisible
    private static void setForTest(AgentSettings s) { instance = s; }

    private static String coalesce(String a, String b) { return String.isBlank(a) ? b : a; }
}
