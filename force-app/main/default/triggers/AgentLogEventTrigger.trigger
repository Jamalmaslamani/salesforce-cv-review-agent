trigger AgentLogEventTrigger on Agent_Log_Event__e (after insert) {
    AgentLogEventHandler.persist(Trigger.new);
}
