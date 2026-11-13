/** Provider-neutral request to a language model. */
public with sharing class LlmRequest {
    public String systemPrompt;
    public String userText;
    /** Optional binary document (e.g. a PDF CV) for providers with native document support. */
    public Blob document;
    public String documentMediaType;
    public Integer maxTokens = 2000;
    public Decimal temperature = 0; // deterministic as possible: we want extraction, not creativity

    public LlmRequest(String systemPrompt, String userText) {
        this.systemPrompt = systemPrompt;
        this.userText = userText;
    }
}
