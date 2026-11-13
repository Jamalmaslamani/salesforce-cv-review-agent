/** Helpers to safely pull a JSON object out of model output (models sometimes wrap JSON in prose or fences). */
public with sharing class LlmJson {
    public class LlmJsonException extends Exception {}

    public static String extractObject(String text) {
        if (String.isBlank(text)) { throw new LlmJsonException('Empty model response.'); }
        Integer start = text.indexOf('{');
        Integer finish = text.lastIndexOf('}');
        if (start < 0 || finish <= start) { throw new LlmJsonException('Model response did not contain a JSON object.'); }
        return text.substring(start, finish + 1);
    }
}
