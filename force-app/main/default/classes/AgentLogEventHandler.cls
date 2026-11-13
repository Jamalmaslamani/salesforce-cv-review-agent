/** Persists Agent_Log_Event__e into Agent_Log__c (runs as Automated Process user). */
public without sharing class AgentLogEventHandler {
    public static void persist(List<Agent_Log_Event__e> events) {
        List<Agent_Log__c> logs = new List<Agent_Log__c>();
        for (Agent_Log_Event__e e : events) {
            logs.add(new Agent_Log__c(
                Action__c = e.Action__c,
                Status__c = e.Status__c,
                Candidate_Id__c = e.Candidate_Id__c,
                Correlation_Id__c = e.Correlation_Id__c,
                Provider__c = e.Provider__c,
                Duration_Ms__c = e.Duration_Ms__c,
                Input__c = e.Input__c,
                Output__c = e.Output__c,
                Error__c = e.Error__c,
                User_Id__c = e.User_Id__c
            ));
        }
        Database.insert(logs, false);
    }
}
