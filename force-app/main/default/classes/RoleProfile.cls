/** What the recruiter is hiring for. Kept explicit (not free text) so scoring is reproducible. */
public with sharing class RoleProfile {
    @AuraEnabled public String title;
    @AuraEnabled public List<String> requiredSkills = new List<String>();
    @AuraEnabled public List<String> niceToHaveSkills = new List<String>();
    @AuraEnabled public Decimal minYears;

    public static RoleProfile fromJson(String jsonText) {
        RoleProfile r = (RoleProfile) JSON.deserialize(jsonText, RoleProfile.class);
        r.requiredSkills = clean(r.requiredSkills);
        r.niceToHaveSkills = clean(r.niceToHaveSkills);
        if (String.isBlank(r.title)) { throw new RoleException('Please give the role a title.'); }
        if (r.requiredSkills.isEmpty() && r.minYears == null) {
            throw new RoleException('Add at least one required skill or a minimum years of experience, otherwise there is nothing to rank on.');
        }
        if (r.minYears != null && (r.minYears < 0 || r.minYears > 40)) { throw new RoleException('Minimum years must be between 0 and 40.'); }
        return r;
    }

    public static List<String> splitCsv(String csv) {
        return clean(String.isBlank(csv) ? new List<String>() : csv.split('[,;\\n]'));
    }

    private static List<String> clean(List<String> raw) {
        List<String> out = new List<String>();
        Set<String> seen = new Set<String>();
        if (raw == null) { return out; }
        for (String s : raw) {
            if (String.isBlank(s)) { continue; }
            String c = SkillCatalog.canonical(s);
            if (seen.add(c.toLowerCase())) { out.add(c); }
        }
        return out;
    }

    public class RoleException extends Exception {}
}
