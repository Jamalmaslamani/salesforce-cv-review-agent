/**
 * Claude via the Anthropic Messages API, called through a Named Credential
 * (the API key never appears in code or in custom settings).
 * Setup: see README "Enabling the LLM provider".
 */
public with sharing class AnthropicLlmProvider implements LlmProvider {
    public class LlmException extends Exception {}

    private final String namedCredential;
    private final String model;

    public AnthropicLlmProvider(String namedCredential, String model) {
        this.namedCredential = namedCredential;
        this.model = model;
    }

    public String complete(LlmRequest req) {
        List<Object> content = new List<Object>();
        if (req.document != null) {
            content.add(new Map<String, Object>{
                'type' => 'document',
                'source' => new Map<String, Object>{
                    'type' => 'base64',
                    'media_type' => req.documentMediaType,
                    'data' => EncodingUtil.base64Encode(req.document)
                }
            });
        }
        content.add(new Map<String, Object>{ 'type' => 'text', 'text' => req.userText });

        Map<String, Object> body = new Map<String, Object>{
            'model' => model,
            'max_tokens' => req.maxTokens,
            'temperature' => req.temperature,
            'system' => req.systemPrompt,
            'messages' => new List<Object>{ new Map<String, Object>{ 'role' => 'user', 'content' => content } }
        };

        HttpRequest http = new HttpRequest();
        http.setEndpoint('callout:' + namedCredential + '/v1/messages');
        http.setMethod('POST');
        http.setHeader('Content-Type', 'application/json');
        http.setHeader('anthropic-version', '2023-06-01');
        http.setTimeout(110000);
        http.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(http);
        if (res.getStatusCode() != 200) {
            throw new LlmException('LLM call failed (HTTP ' + res.getStatusCode() + '): ' + res.getBody().abbreviate(500));
        }
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> blocks = (List<Object>) parsed.get('content');
        List<String> texts = new List<String>();
        for (Object b : blocks) {
            Map<String, Object> block = (Map<String, Object>) b;
            if (block.get('type') == 'text') { texts.add((String) block.get('text')); }
        }
        return String.join(texts, '\n');
    }
}
