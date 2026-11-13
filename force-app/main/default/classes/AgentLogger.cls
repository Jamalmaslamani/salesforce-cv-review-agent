/**
 * Audit trail / observability for agent decisions.
 *
 * Entries are buffered and published as Agent_Log_Event__e (publish-immediately), which a
 * trigger persists into Agent_Log__c. Two reasons:
 *  1. Errors are still recorded when the business transaction rolls back.
 *  2. Buffering lets us flush AFTER callouts (Apex forbids callouts after DML in a transaction).
 * Every user request gets a correlation id that also lands on bookmarks, so a bookmark can be
 * traced back to the exact evaluation that produced it.
 */
public without sharing class AgentLogger {
    // without sharing: logging must work regardless of the caller's record access;
    // it only ever writes the log event, never reads business data.
    public static final String SUCCESS = 'SUCCESS';
    public static final String WARNING = 'WARNING';
    public static final String ERROR = 'ERROR';

    private static final Integer MAX_TEXT = 32000;
    private static List<Agent_Log_Event__e> buffer = new List<Agent_Log_Event__e>();
    private static String correlationId;

    public static String correlationId() {
        if (correlationId == null) {
            correlationId = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(32);
        }
        return correlationId;
    }

    public static void log(String action, String status, Id candidateId, String input, String output, Long durationMs) {
        buffer.add(new Agent_Log_Event__e(
            Action__c = action,
            Status__c = status,
            Candidate_Id__c = candidateId,
            Correlation_Id__c = correlationId(),
            Provider__c = AgentSettings.get().provider,
            Duration_Ms__c = durationMs,
            Input__c = trunc(input),
            Output__c = trunc(output),
            User_Id__c = UserInfo.getUserId()
        ));
    }

    public static void error(String action, Id candidateId, String input, Exception e) {
        buffer.add(new Agent_Log_Event__e(
            Action__c = action,
            Status__c = ERROR,
            Candidate_Id__c = candidateId,
            Correlation_Id__c = correlationId(),
            Provider__c = AgentSettings.get().provider,
            Input__c = trunc(input),
            Error__c = trunc(e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString()),
            User_Id__c = UserInfo.getUserId()
        ));
    }

    /** Publishes buffered entries. Call at the end of each entry point (after any callouts). */
    public static void flush() {
        if (buffer.isEmpty()) { return; }
        List<Database.SaveResult> results = EventBus.publish(buffer);
        for (Database.SaveResult r : results) {
            if (!r.isSuccess()) { System.debug(LoggingLevel.ERROR, 'Agent log publish failed: ' + r.getErrors()); }
        }
        buffer.clear();
    }

    @TestVisible private static Integer pending() { return buffer.size(); }

    private static String trunc(String s) {
        return s == null ? null : s.abbreviate(MAX_TEXT);
    }
}
