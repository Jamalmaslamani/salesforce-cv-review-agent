/** Returns the configured provider; null when the agent runs in deterministic Mock mode. */
public with sharing class LlmProviderFactory {
    @TestVisible private static LlmProvider testProvider;

    public static LlmProvider get() {
        if (testProvider != null) { return testProvider; }
        AgentSettings s = AgentSettings.get();
        if (s.useLlm()) { return new AnthropicLlmProvider(s.namedCredential, s.model); }
        return null;
    }
}
