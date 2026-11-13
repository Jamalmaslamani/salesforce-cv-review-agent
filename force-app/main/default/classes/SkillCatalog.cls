/**
 * Canonical skill vocabulary + aliases. Normalising skills lets us compare
 * "Lightning Web Components" (experience text) with "LWC" (role requirement).
 * Production: move to Custom Metadata so recruiters/admins can maintain it.
 */
public with sharing class SkillCatalog {
    /** alias (lower-case) => canonical name */
    private static Map<String, String> aliasToCanonical;

    private static final Map<String, List<String>> CATALOG = new Map<String, List<String>>{
        'Apex' => new List<String>{ 'apex', 'apex triggers', 'apex classes' },
        'LWC' => new List<String>{ 'lwc', 'lightning web components', 'lightning web component' },
        'Aura' => new List<String>{ 'aura', 'aura components' },
        'Visualforce' => new List<String>{ 'visualforce' },
        'SOQL' => new List<String>{ 'soql', 'sosl' },
        'REST APIs' => new List<String>{ 'rest apis', 'rest api', 'rest', 'restful' },
        'Salesforce Flow' => new List<String>{ 'salesforce flow', 'flow', 'flows', 'flow builder' },
        'Platform Events' => new List<String>{ 'platform events', 'platform event' },
        'Agentforce' => new List<String>{ 'agentforce' },
        'Git' => new List<String>{ 'git', 'github', 'gitlab' },
        'CI/CD' => new List<String>{ 'ci/cd', 'cicd', 'continuous integration' },
        'MuleSoft' => new List<String>{ 'mulesoft' },
        'Integration Architecture' => new List<String>{ 'integration architecture' },
        'Data Modeling' => new List<String>{ 'data modeling', 'data modelling' },
        'Salesforce Administration' => new List<String>{ 'salesforce administration', 'salesforce admin', 'salesforce administrator' },
        'Reports and Dashboards' => new List<String>{ 'reports and dashboards', 'reports & dashboards' },
        'Data Loader' => new List<String>{ 'data loader' },
        'CRM Analytics' => new List<String>{ 'crm analytics', 'tableau crm', 'einstein analytics' },
        'Salesforce' => new List<String>{ 'salesforce' },
        'Data Cloud' => new List<String>{ 'data cloud' },
        'JavaScript' => new List<String>{ 'javascript', 'js' },
        'TypeScript' => new List<String>{ 'typescript' },
        'React' => new List<String>{ 'react', 'react.js', 'reactjs' },
        'Node.js' => new List<String>{ 'node.js', 'nodejs', 'node' },
        'PHP' => new List<String>{ 'php' },
        'jQuery' => new List<String>{ 'jquery' },
        'Java' => new List<String>{ 'java' },
        'Spring' => new List<String>{ 'spring', 'spring boot' },
        'Python' => new List<String>{ 'python' },
        'SQL' => new List<String>{ 'sql' },
        'PostgreSQL' => new List<String>{ 'postgresql', 'postgres' },
        'Tableau' => new List<String>{ 'tableau' },
        'Power BI' => new List<String>{ 'power bi', 'powerbi' },
        'Excel' => new List<String>{ 'excel' }
    };

    public static Map<String, String> aliases() {
        if (aliasToCanonical == null) {
            aliasToCanonical = new Map<String, String>();
            for (String canonical : CATALOG.keySet()) {
                aliasToCanonical.put(canonical.toLowerCase(), canonical);
                for (String a : CATALOG.get(canonical)) { aliasToCanonical.put(a, canonical); }
            }
        }
        return aliasToCanonical;
    }

    /** Returns the canonical name, or the trimmed input when unknown (we never drop stated skills). */
    public static String canonical(String raw) {
        if (raw == null) { return null; }
        String t = raw.trim();
        String c = aliases().get(t.toLowerCase());
        return c != null ? c : t;
    }

    public static String normalize(String raw) {
        String c = canonical(raw);
        return c == null ? null : c.toLowerCase();
    }

    /**
     * Finds catalog skills mentioned in free text using word-boundary matching.
     * Returns canonical name => the sentence it was found in (evidence).
     */
    public static Map<String, String> findMentions(String text) {
        Map<String, String> found = new Map<String, String>();
        if (String.isBlank(text)) { return found; }
        List<String> lines = text.split('\n');
        for (String alias : aliases().keySet()) {
            // Too ambiguous to infer from prose (e.g. "node", "rest", "flow", "js", "spring")
            if (alias.length() <= 4 && alias != 'apex' && alias != 'soql' && alias != 'lwc' && alias != 'sql' && alias != 'git' && alias != 'java' && alias != 'php') { continue; }
            if (alias == 'spring' || alias == 'salesforce admin') { continue; }
            Pattern p = Pattern.compile('(?i)(?<![A-Za-z0-9])' + escape(alias) + '(?![A-Za-z0-9])');
            for (String line : lines) {
                if (p.matcher(line).find()) {
                    String canonicalName = aliases().get(alias);
                    if (!found.containsKey(canonicalName)) { found.put(canonicalName, line.trim()); }
                    break;
                }
            }
        }
        return found;
    }

    private static String escape(String s) {
        String out = '';
        for (Integer i = 0; i < s.length(); i++) {
            String ch = s.substring(i, i + 1);
            out += '.+*?^$()[]{}|\\/'.contains(ch) ? '\\' + ch : ch;
        }
        return out;
    }
}
