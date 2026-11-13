/**
 * Deterministic, rule-based CV parser. Turns plain CV text into a CandidateCard and
 * records every gap, inference and contradiction it notices as an Issue.
 *
 * Why rules first (and LLM optional)?
 *  - Reproducible: the same CV always yields the same card -> testable, auditable.
 *  - No data leaves Salesforce by default (PII).
 *  - It is also the safety net for the LLM path: CardValidator re-checks LLM output against the raw text.
 *
 * Limitation: it relies on common CV conventions (section headers, "Title | Company | Dates" lines).
 * Unconventional layouts degrade to "Needs Review" rather than to invented data.
 */
public with sharing class HeuristicCvParser {
    public static final String METHOD = 'Heuristic Parser v1';

    private static final Map<String, String> HEADERS = new Map<String, String>{
        'summary' => 'SUMMARY', 'profile' => 'SUMMARY', 'professional summary' => 'SUMMARY', 'about me' => 'SUMMARY', 'objective' => 'SUMMARY',
        'experience' => 'EXPERIENCE', 'work experience' => 'EXPERIENCE', 'professional experience' => 'EXPERIENCE',
        'employment' => 'EXPERIENCE', 'employment history' => 'EXPERIENCE', 'work history' => 'EXPERIENCE',
        'education' => 'EDUCATION', 'academic background' => 'EDUCATION',
        'skills' => 'SKILLS', 'technical skills' => 'SKILLS', 'core skills' => 'SKILLS', 'key skills' => 'SKILLS',
        'certifications' => 'CERTIFICATIONS', 'certificates' => 'CERTIFICATIONS', 'licenses and certifications' => 'CERTIFICATIONS'
    };
    private static final Map<String, Integer> MONTHS = new Map<String, Integer>{
        'jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'may' => 5, 'jun' => 6,
        'jul' => 7, 'aug' => 8, 'sep' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12
    };
    private static final Pattern EMAIL_P = Pattern.compile('[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}');
    private static final Pattern PHONE_P = Pattern.compile('\\+?\\(?\\d[\\d ().-]{7,}\\d');
    private static final Pattern YEARS_P = Pattern.compile('(?i)(over |more than )?(\\d{1,2})(\\+)?\\s*\\+?\\s*years?');
    private static final Pattern YEAR_P = Pattern.compile('(19|20)\\d{2}');
    private static final Pattern MONTH_YEAR_P = Pattern.compile('(?i)\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?\\s+((?:19|20)\\d{2})');
    private static final Pattern NUM_MONTH_YEAR_P = Pattern.compile('\\b(\\d{1,2})/((?:19|20)\\d{2})');
    private static final Pattern CURRENT_P = Pattern.compile('(?i)\\b(present|current|now|today|ongoing)\\b');
    private static final Pattern CERT_P = Pattern.compile('^(.*?)\\s*[\\(,-]\\s*((?:19|20)\\d{2})\\)?\\s*$');
    private static final Pattern DEGREE_P = Pattern.compile('(?i)\\b(b\\.?sc|b\\.?a|b\\.?eng|b\\.?s|m\\.?sc|m\\.?a|m\\.?eng|m\\.?s|mba|ph\\.?d|bachelor|master|diploma|associate)\\b');
    private static final Pattern INSTITUTION_P = Pattern.compile('(?i)(university|college|institute|school|academy|polytechnic)');
    private static final Pattern LOCATION_P = Pattern.compile('^[A-Z][A-Za-z .\'-]+,\\s*[A-Z][A-Za-z .\'-]+$');
    private static final Pattern NAME_P = Pattern.compile('^[A-Z][A-Za-z\'-]+(\\s+[A-Z][A-Za-z\'-]+){1,3}$');

    private Date asOf;

    public HeuristicCvParser() { this(Date.today()); }
    /** asOf = the date "Present" resolves to; injectable for deterministic tests. */
    public HeuristicCvParser(Date asOf) { this.asOf = asOf; }

    public CandidateCard parse(String text) {
        CandidateCard card = new CandidateCard();
        card.extractionMethod = METHOD;
        text = text == null ? '' : text;

        List<String> header = new List<String>();
        Map<String, List<String>> sections = splitSections(text, header);

        parseContact(card, text, header);
        parseNameAndHeadline(card, header, sections);
        parseSummary(card, sections.get('SUMMARY'));
        parseExperience(card, sections.get('EXPERIENCE'));
        parseEducation(card, sections.get('EDUCATION'));
        parseSkills(card, sections);
        parseCertifications(card, sections.get('CERTIFICATIONS'));
        reconcileExperience(card);
        computeCompleteness(card);
        return card;
    }

    // ---------------------------------------------------------------- sections
    private Map<String, List<String>> splitSections(String text, List<String> header) {
        Map<String, List<String>> sections = new Map<String, List<String>>();
        String current = null;
        for (String raw : text.split('\n')) {
            String line = raw.trim();
            if (String.isBlank(line)) { continue; }
            String key = line.toLowerCase().removeEnd(':').trim();
            if (HEADERS.containsKey(key) && line.length() < 40) {
                current = HEADERS.get(key);
                if (!sections.containsKey(current)) { sections.put(current, new List<String>()); }
                continue;
            }
            if (current == null) { header.add(line); } else { sections.get(current).add(line); }
        }
        return sections;
    }

    // ---------------------------------------------------------------- contact
    private void parseContact(CandidateCard card, String text, List<String> header) {
        // Email: any address anywhere in the CV. More than one distinct address = conflict.
        List<String> emails = new List<String>();
        Map<String, String> emailEvidence = new Map<String, String>();
        for (String line : text.split('\n')) {
            Matcher m = EMAIL_P.matcher(line);
            while (m.find()) {
                String e = m.group().toLowerCase();
                if (!emails.contains(e)) { emails.add(e); emailEvidence.put(e, line.trim()); }
            }
        }
        if (emails.isEmpty()) {
            card.email = missing('No email address found in the CV.');
            card.addIssue(CandidateCard.MISSING, 'email', 'No email address in the CV - the candidate cannot be contacted by email.', null, 'MEDIUM');
        } else if (emails.size() == 1) {
            card.email = new CandidateCard.CardField(emails[0], CandidateCard.FOUND, 1.0, emailEvidence.get(emails[0]));
        } else {
            card.email = new CandidateCard.CardField(emails[0], CandidateCard.CONFLICT, 0.6, emailEvidence.get(emails[0]));
            card.email.note = 'Also found: ' + String.join(subList(emails, 1), ', ');
            card.addIssue(CandidateCard.CONFLICT, 'email', 'The CV contains ' + emails.size() + ' different email addresses (' +
                String.join(emails, ', ') + '). Confirm which one is current.', emailEvidence.get(emails[1]), 'MEDIUM');
        }

        // Phone: only look in the header block or explicitly labelled lines (avoids date ranges / numbers in bullets).
        String phone; String phoneEvidence;
        List<String> candidates = new List<String>(header);
        for (String line : text.split('\n')) {
            if (line.toLowerCase().contains('phone') || line.toLowerCase().contains('mobile') || line.toLowerCase().contains('tel')) { candidates.add(line); }
        }
        for (String line : candidates) {
            Matcher m = PHONE_P.matcher(line);
            while (m.find() && phone == null) {
                String digits = m.group().replaceAll('[^0-9]', '');
                if (digits.length() >= 9 && digits.length() <= 15) { phone = m.group().trim(); phoneEvidence = line.trim(); }
            }
        }
        if (phone == null) {
            card.phone = missing('No phone number found in the CV.');
            card.addIssue(CandidateCard.MISSING, 'phone', 'No phone number in the CV.', null, 'LOW');
        } else {
            card.phone = new CandidateCard.CardField(phone, CandidateCard.FOUND, 0.9, phoneEvidence);
        }

        // Location: "City, Country" segment in the header block, or a "Location:" label.
        String location; String locEvidence;
        for (String line : header) {
            for (String seg : line.split('\\|')) {
                String s = seg.trim().removeStartIgnoreCase('location:').trim();
                if (LOCATION_P.matcher(s).matches() && !s.contains('@')) { location = s; locEvidence = line.trim(); break; }
            }
            if (location != null) { break; }
        }
        if (location == null) {
            card.location = missing('No location found in the CV header.');
            card.addIssue(CandidateCard.MISSING, 'location', 'Location not stated - relocation/remote eligibility unknown.', null, 'LOW');
        } else {
            card.location = new CandidateCard.CardField(location, CandidateCard.FOUND, 0.85, locEvidence);
        }
    }

    // ---------------------------------------------------------------- name / headline
    private void parseNameAndHeadline(CandidateCard card, List<String> header, Map<String, List<String>> sections) {
        if (!header.isEmpty() && NAME_P.matcher(header[0]).matches()) {
            card.name = new CandidateCard.CardField(header[0], CandidateCard.FOUND, 0.9, header[0]);
            card.name.note = 'Taken from the first line of the document.';
        } else if (CandidateCard.valueOf(card.email) != null) {
            String local = card.email.value.substringBefore('@').replaceAll('[._\\d-]+', ' ').trim();
            List<String> parts = new List<String>();
            for (String p : local.split(' ')) { if (p.length() > 1) { parts.add(p.capitalize()); } }
            card.name = new CandidateCard.CardField(String.join(parts, ' '), CandidateCard.INFERRED, 0.4, card.email.value);
            card.addIssue(CandidateCard.INFERRED, 'name', 'Candidate name not clearly stated; guessed from the email address.', card.email.value, 'HIGH');
        } else {
            card.name = missing('Candidate name could not be identified.');
            card.addIssue(CandidateCard.MISSING, 'name', 'Candidate name could not be identified.', null, 'HIGH');
        }

        String headline;
        for (Integer i = 1; i < header.size() && i < 3; i++) {
            String l = header[i];
            if (!l.contains('@') && !l.contains('|') && !Pattern.compile('\\d').matcher(l).find() && !LOCATION_P.matcher(l).matches()) {
                headline = l; break;
            }
        }
        if (headline != null) {
            card.headline = new CandidateCard.CardField(headline, CandidateCard.FOUND, 0.85, headline);
        } else {
            card.headline = missing('No headline found.');
        }
    }

    // ---------------------------------------------------------------- summary
    private void parseSummary(CandidateCard card, List<String> lines) {
        if (lines == null || lines.isEmpty()) {
            card.summary = missing('No summary section.');
            return;
        }
        String s = String.join(lines, ' ');
        card.summary = new CandidateCard.CardField(s, CandidateCard.FOUND, 1.0, s.abbreviate(250));
        Matcher m = YEARS_P.matcher(s);
        if (m.find()) {
            Boolean isMinimum = m.group(1) != null || m.group(3) != null || m.group().contains('+');
            card.claimedYearsExperience = new CandidateCard.CardField(m.group(2), CandidateCard.FOUND, 0.9, m.group().trim());
            card.claimedYearsExperience.note = isMinimum ? 'Stated as a minimum ("' + m.group().trim() + '").' : null;
        }
    }

    // ---------------------------------------------------------------- experience
    private void parseExperience(CandidateCard card, List<String> lines) {
        if (lines == null) { return; }
        CandidateCard.Experience current;
        for (String line : lines) {
            if (line.startsWith('-') || line.startsWith('•') || line.startsWith('*')) {
                if (current != null) { current.highlights.add(line.substring(1).trim()); }
                continue;
            }
            if (!line.contains('|') && !CURRENT_P.matcher(line).find() && !YEAR_P.matcher(line).find()) {
                if (current != null) { current.highlights.add(line); }
                continue;
            }
            current = new CandidateCard.Experience();
            current.evidence = line;
            List<String> textParts = new List<String>();
            String datePart;
            for (String p : line.split('\\|')) {
                String t = p.trim();
                if (datePart == null && (YEAR_P.matcher(t).find() || CURRENT_P.matcher(t).find()) && t.length() < 40) { datePart = t; }
                else if (String.isNotBlank(t)) { textParts.add(t); }
            }
            current.title = textParts.size() > 0 ? textParts[0] : null;
            current.company = textParts.size() > 1 ? textParts[1] : null;
            applyDates(card, current, datePart);
            card.experience.add(current);
        }
    }

    private void applyDates(CandidateCard card, CandidateCard.Experience exp, String datePart) {
        String role = describe(exp);
        if (datePart == null) {
            exp.datePrecision = 'NONE';
            card.addIssue(CandidateCard.MISSING, 'experience', 'No dates for ' + role + ' - duration unknown and excluded from total experience.', exp.evidence, 'MEDIUM');
            return;
        }
        List<String> range = datePart.split('\\s+(?:-|–|—|to)\\s+|\\s*[–—]\\s*');
        Integer[] start = parseDate(range[0]);
        Integer[] finish = range.size() > 1 ? parseDate(range[1]) : null;
        Boolean startIsCurrent = CURRENT_P.matcher(range[0]).find();
        exp.isCurrent = CURRENT_P.matcher(datePart).find();

        if (startIsCurrent || start == null) {
            exp.datePrecision = 'NONE';
            card.addIssue(CandidateCard.MISSING, 'experience', 'No start date for ' + role + ' (only "' + datePart + '") - duration unknown and excluded from total experience.', exp.evidence, 'MEDIUM');
            return;
        }
        Integer startIdx = start[0] * 12 + start[1] - 1;
        Integer endIdx;
        if (exp.isCurrent) {
            endIdx = asOf.year() * 12 + asOf.month() - 1;
        } else if (finish != null) {
            endIdx = finish[0] * 12 + finish[1] - 1;
        } else {
            endIdx = startIdx; // single date, e.g. "2019" -> treat as <= 1 year
        }
        Boolean yearOnly = start[2] == 1 || (finish != null && finish[2] == 1);
        exp.datePrecision = yearOnly ? 'YEAR' : 'MONTH';
        if (yearOnly) {
            card.addIssue('AMBIGUOUS', 'experience', 'Dates for ' + role + ' are given as years only; duration approximated assuming mid-year start/end.', exp.evidence, 'LOW');
        }
        if (endIdx < startIdx) {
            card.addIssue(CandidateCard.CONFLICT, 'experience', 'End date is before start date for ' + role + '.', exp.evidence, 'HIGH');
            return;
        }
        exp.startDate = fmt(startIdx);
        exp.endDate = exp.isCurrent ? null : fmt(endIdx);
        exp.months = endIdx - startIdx + (yearOnly ? 0 : 1);
        if (exp.months == 0) { exp.months = 12; }
    }

    /** Returns [year, month, isYearOnly(1/0)] or null. Year-only uses a mid-year assumption (Jul start). */
    private Integer[] parseDate(String s) {
        if (s == null) { return null; }
        Matcher m = MONTH_YEAR_P.matcher(s);
        if (m.find()) { return new Integer[]{ Integer.valueOf(m.group(2)), MONTHS.get(m.group(1).toLowerCase().left(3)), 0 }; }
        m = NUM_MONTH_YEAR_P.matcher(s);
        if (m.find()) {
            Integer month = Integer.valueOf(m.group(1));
            if (month >= 1 && month <= 12) { return new Integer[]{ Integer.valueOf(m.group(2)), month, 0 }; }
        }
        m = YEAR_P.matcher(s);
        if (m.find()) { return new Integer[]{ Integer.valueOf(m.group()), 7, 1 }; }
        return null;
    }

    /** Timeline analysis: total (overlaps merged), overlaps, gaps, and claimed-vs-computed check. */
    private void reconcileExperience(CandidateCard card) {
        List<Integer[]> intervals = new List<Integer[]>();
        Boolean undated = false;
        for (Integer k = 0; k < card.experience.size(); k++) {
            CandidateCard.Experience e = card.experience[k];
            if (e.startDate == null) { undated = true; continue; }
            Integer s = idx(e.startDate);
            intervals.add(new Integer[]{ s, s + e.months - 1, k, e.datePrecision == 'YEAR' ? 1 : 0 });
        }
        // sort by start (insertion sort; lists are tiny)
        for (Integer i = 1; i < intervals.size(); i++) {
            Integer[] key = intervals[i]; Integer j = i - 1;
            while (j >= 0 && intervals[j][0] > key[0]) { intervals[j + 1] = intervals[j]; j--; }
            intervals[j + 1] = key;
        }
        Integer total = 0; Integer curS; Integer curE;
        for (Integer i = 0; i < intervals.size(); i++) {
            Integer[] iv = intervals[i];
            if (i > 0) {
                Integer[] prev = intervals[i - 1];
                if (iv[0] <= prev[1]) {
                    Integer overlap = Math.min(prev[1], iv[1]) - iv[0] + 1;
                    if (overlap >= 2 && iv[3] == 0 && prev[3] == 0) {
                        card.addIssue('AMBIGUOUS', 'experience', 'Roles overlap by ' + overlap + ' months (' + describe(card.experience[prev[2]]) + ' and ' +
                            describe(card.experience[iv[2]]) + '). Concurrent jobs or a date error?', null, 'LOW');
                    }
                } else if (curE != null && iv[0] - curE - 1 >= 6) {
                    Integer gap = iv[0] - curE - 1;
                    card.addIssue('AMBIGUOUS', 'experience', 'Unexplained employment gap of ' + gap + ' months (' + fmtHuman(curE + 1) + ' - ' + fmtHuman(iv[0] - 1) + ').', null, 'MEDIUM');
                }
            }
            if (curS == null) { curS = iv[0]; curE = iv[1]; }
            else if (iv[0] <= curE + 1) { curE = Math.max(curE, iv[1]); }
            else { total += curE - curS + 1; curS = iv[0]; curE = iv[1]; }
        }
        if (curS != null) { total += curE - curS + 1; }

        if (card.experience.isEmpty()) {
            card.totalYearsExperience = missing('No work experience section found.');
            card.addIssue(CandidateCard.MISSING, 'experience', 'No work experience could be identified.', null, 'HIGH');
            return;
        }
        Decimal years = (Decimal.valueOf(total) / 12).setScale(1);
        card.totalYearsExperience = new CandidateCard.CardField(String.valueOf(years),
            undated ? CandidateCard.INFERRED : CandidateCard.FOUND, undated ? 0.5 : 0.9, null);
        card.totalYearsExperience.note = 'Computed from dated roles (overlaps merged).' + (undated ? ' Lower bound: some roles have no dates.' : '');

        if (card.claimedYearsExperience != null) {
            Decimal claimed = Decimal.valueOf(card.claimedYearsExperience.value);
            if ((claimed - years).abs() >= 2 && !(undated && claimed > years)) {
                card.claimedYearsExperience.status = CandidateCard.CONFLICT;
                card.totalYearsExperience.status = CandidateCard.CONFLICT;
                card.addIssue(CandidateCard.CONFLICT, 'yearsExperience', 'Summary claims "' + card.claimedYearsExperience.evidence +
                    '" but the dated roles add up to about ' + years + ' years.', card.claimedYearsExperience.evidence, 'HIGH');
            }
        }
    }

    // ---------------------------------------------------------------- education
    private void parseEducation(CandidateCard card, List<String> lines) {
        if (lines == null || lines.isEmpty()) {
            card.addIssue(CandidateCard.MISSING, 'education', 'No education section in the CV.', null, 'LOW');
            return;
        }
        for (String line : lines) {
            if (line.startsWith('-')) { continue; }
            CandidateCard.Education ed = new CandidateCard.Education();
            ed.evidence = line;
            for (String p : line.split('\\|')) {
                String t = p.trim();
                if (YEAR_P.matcher(t).matches()) { ed.year = t; }
                else if (ed.degree == null && DEGREE_P.matcher(t).find()) { ed.degree = t; }
                else if (ed.institution == null && INSTITUTION_P.matcher(t).find()) { ed.institution = t; }
                else if (ed.degree == null) { ed.degree = t; }
            }
            if (ed.year == null) {
                Matcher m = YEAR_P.matcher(line);
                if (m.find()) { ed.year = m.group(); }
            }
            if (ed.year == null) {
                card.addIssue(CandidateCard.MISSING, 'education', 'No graduation year for "' + ed.degree + '".', line, 'LOW');
            }
            card.education.add(ed);
        }
    }

    // ---------------------------------------------------------------- skills
    private void parseSkills(CandidateCard card, Map<String, List<String>> sections) {
        Set<String> seen = new Set<String>();
        List<String> skillLines = sections.get('SKILLS');
        if (skillLines != null) {
            for (String token : String.join(skillLines, ',').split('[,;•|\\n]')) {
                String t = token.trim().removeStart('-').trim();
                if (String.isBlank(t) || t.length() > 60 || t.contains('@') || t.contains(':')) { continue; }
                String canonical = SkillCatalog.canonical(t);
                if (seen.add(canonical.toLowerCase())) {
                    card.skills.add(new CandidateCard.Skill(canonical, CandidateCard.FOUND, 'Skills section: "' + t + '"'));
                }
            }
        } else {
            card.addIssue(CandidateCard.MISSING, 'skills', 'No skills section; skills below are inferred from experience only.', null, 'MEDIUM');
        }
        // Inferred: mentioned in experience / summary but not listed as a skill.
        List<String> prose = new List<String>();
        for (CandidateCard.Experience e : card.experience) { prose.addAll(e.highlights); }
        if (card.summary != null && card.summary.value != null) { prose.add(card.summary.value); }
        Map<String, String> mentions = SkillCatalog.findMentions(String.join(prose, '\n'));
        for (String skill : mentions.keySet()) {
            if (seen.add(skill.toLowerCase())) {
                card.skills.add(new CandidateCard.Skill(skill, CandidateCard.INFERRED, mentions.get(skill)));
                card.addIssue(CandidateCard.INFERRED, 'skills', 'Skill "' + skill + '" is not listed but inferred from: "' + mentions.get(skill).abbreviate(140) + '"', mentions.get(skill), 'LOW');
            }
        }
    }

    // ---------------------------------------------------------------- certifications
    private void parseCertifications(CandidateCard card, List<String> lines) {
        if (lines == null) { return; }
        Map<String, List<CandidateCard.Certification>> byName = new Map<String, List<CandidateCard.Certification>>();
        for (String line : lines) {
            CandidateCard.Certification c = new CandidateCard.Certification();
            c.evidence = line;
            c.status = CandidateCard.FOUND;
            Matcher m = CERT_P.matcher(line);
            if (m.matches()) { c.name = m.group(1).trim(); c.year = m.group(2); }
            else { c.name = line.removeStart('-').trim(); }
            String key = c.name.toLowerCase();
            if (!byName.containsKey(key)) { byName.put(key, new List<CandidateCard.Certification>()); }
            byName.get(key).add(c);
            card.certifications.add(c);
        }
        for (String key : byName.keySet()) {
            List<CandidateCard.Certification> certs = byName.get(key);
            if (certs.size() > 1) {
                List<String> years = new List<String>();
                for (CandidateCard.Certification c : certs) { c.status = CandidateCard.CONFLICT; years.add(c.year == null ? '?' : c.year); }
                card.addIssue(CandidateCard.CONFLICT, 'certifications', '"' + certs[0].name + '" is listed ' + certs.size() + ' times with different years (' +
                    String.join(years, ', ') + '). Verify on the Salesforce credential verification site.', certs[0].evidence, 'MEDIUM');
            }
        }
    }

    // ---------------------------------------------------------------- completeness
    private void computeCompleteness(CandidateCard card) {
        List<CandidateCard.CardField> core = new List<CandidateCard.CardField>{ card.name, card.email, card.phone, card.location, card.headline, card.summary };
        Integer known = 0;
        Integer total = core.size() + 3;
        for (CandidateCard.CardField f : core) { if (f != null && f.status != CandidateCard.MISSING) { known++; } }
        if (!card.experience.isEmpty()) { known++; }
        if (!card.education.isEmpty()) { known++; }
        if (!card.skills.isEmpty()) { known++; }
        card.completeness = (Decimal.valueOf(known) * 100 / total).setScale(0);
    }

    // ---------------------------------------------------------------- utils
    private static CandidateCard.CardField missing(String note) {
        CandidateCard.CardField f = new CandidateCard.CardField(null, CandidateCard.MISSING, 0, null);
        f.note = note;
        return f;
    }
    private static String describe(CandidateCard.Experience e) {
        return '"' + (e.title == null ? 'untitled role' : e.title) + (e.company == null ? '' : ' at ' + e.company) + '"';
    }
    private static Integer idx(String yyyyMM) {
        return Integer.valueOf(yyyyMM.left(4)) * 12 + Integer.valueOf(yyyyMM.right(2)) - 1;
    }
    private static String fmt(Integer i) {
        Integer y = i / 12; Integer m = Math.mod(i, 12) + 1;
        return y + '-' + (m < 10 ? '0' + m : String.valueOf(m));
    }
    private static String fmtHuman(Integer i) {
        List<String> names = new List<String>{ 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' };
        return names[Math.mod(i, 12)] + ' ' + (i / 12);
    }
    private static List<String> subList(List<String> l, Integer fromIdx) {
        List<String> out = new List<String>();
        for (Integer i = fromIdx; i < l.size(); i++) { out.add(l[i]); }
        return out;
    }
}
