/**
 * Abstraction over the language model. The rest of the agent depends only on this
 * interface, so the provider can be swapped (Anthropic, Einstein/Models API, Agentforce)
 * or stubbed in tests without touching business logic.
 */
public interface LlmProvider {
    /**
     * @param request  system prompt (grounding rules, output schema), user text and optional document
     * @return raw model text (callers parse/validate it - never trusted blindly)
     */
    String complete(LlmRequest request);
}
