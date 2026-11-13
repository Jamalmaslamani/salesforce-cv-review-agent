@IsTest
public class TestDataFactory {
    /** Same content as the sample CVs shipped in the static resource. */
    public static String SARA = String.join(new List<String>{
            'Sara Haddad',
            'Senior Salesforce Developer',
            'sara.haddad@example.com | +961 70 123 456 | Beirut, Lebanon',
            '',
            'SUMMARY',
            'Salesforce developer with 8 years of experience building scalable Apex and LWC solutions for B2B SaaS clients.',
            '',
            'EXPERIENCE',
            'Senior Salesforce Developer | Nimbus Cloud Solutions | Mar 2021 - Present',
            '- Led the design of an event-driven order sync using Platform Events and REST APIs.',
            '- Built 30+ Lightning Web Components for the sales console.',
            '- Introduced CI/CD with Git and scratch orgs, cutting release time by 40%.',
            '- Prototyped an Agentforce agent for case triage.',
            'Salesforce Developer | BrightPath Consulting | Jun 2018 - Feb 2021',
            '- Developed Apex triggers, batch jobs and SOQL-optimised services for 12 client orgs.',
            '- Automated onboarding with Salesforce Flow.',
            '',
            'EDUCATION',
            'BSc Computer Science | American University of Beirut | 2018',
            '',
            'SKILLS',
            'Apex, LWC, SOQL, Salesforce Flow, REST APIs, Platform Events, Git, CI/CD, Agentforce',
            '',
            'CERTIFICATIONS',
            'Salesforce Platform Developer I (2019)',
            'Salesforce Platform Developer II (2022)',
            'Salesforce Agentforce Specialist (2025)'
        }, '\n');
    public static String OMAR = String.join(new List<String>{
            'Omar Khalil',
            'Full Stack Developer',
            'omar.khalil@example.com | +962 79 555 0101 | Amman, Jordan',
            '',
            'SUMMARY',
            'Full stack engineer with 12+ years of experience across web platforms and CRM integrations.',
            '',
            'EXPERIENCE',
            'Full Stack Developer | Zenith Apps | Jan 2022 - Present',
            '- Built Lightning Web Components for a client\'s Salesforce org and connected them to a Node.js backend.',
            '- Designed PostgreSQL schemas for a multi-tenant SaaS product.',
            'Frontend Developer | PixelForge | Jun 2019 - Mar 2022',
            '- Delivered React and TypeScript single-page apps for e-commerce clients.',
            'Junior Web Developer | CodeNest | 2018 - 2019',
            '- Maintained PHP and jQuery websites.',
            '',
            'EDUCATION',
            'BEng Software Engineering | University of Jordan',
            '',
            'SKILLS',
            'JavaScript, React, Node.js, TypeScript, PostgreSQL, Salesforce Administration',
            '',
            'Contact: omar.k.dev@gmail.com'
        }, '\n');
    public static String LINA = String.join(new List<String>{
            'Lina Mansour',
            'Salesforce Administrator',
            'Amman, Jordan',
            '',
            'SUMMARY',
            'Detail-oriented Salesforce administrator focused on automation and reporting.',
            '',
            'EXPERIENCE',
            'Salesforce Administrator | Orbit Retail Group | Present',
            '- Maintain users, profiles and permission sets for 250 users.',
            '- Built Salesforce Flow automations replacing legacy workflow rules.',
            '- Create Reports and Dashboards for regional sales managers.',
            'CRM Intern | Orbit Retail Group | Jun 2023 - Dec 2023',
            '- Cleaned and imported 40,000 records using Data Loader.',
            '',
            'EDUCATION',
            'BA Business Information Systems | Princess Sumaya University for Technology',
            '',
            'SKILLS',
            'Salesforce Flow, Reports and Dashboards, Data Loader, Excel',
            '',
            'CERTIFICATIONS',
            'Salesforce Certified Administrator (2024)'
        }, '\n');
    public static String DANIEL = String.join(new List<String>{
            'Daniel Reyes',
            'Salesforce Technical Architect',
            'daniel.reyes@example.com | +1 415 555 0199 | Austin, USA',
            '',
            'SUMMARY',
            'Technical architect with over 12 years of experience designing enterprise Salesforce and Java platforms.',
            '',
            'EXPERIENCE',
            'Salesforce Technical Architect | Vertex Global | Aug 2020 - Present',
            '- Own the integration architecture for 3 Salesforce orgs using MuleSoft and REST APIs.',
            '- Mentored a team of 8 developers on Apex design patterns and code review.',
            'Lead Salesforce Developer | Harbor Systems | Jan 2015 - Dec 2018',
            '- Built Apex services, SOQL-heavy batch jobs and Visualforce pages.',
            '- Migrated Aura components to LWC.',
            'Java Developer | Sunline Tech | Jul 2012 - Dec 2014',
            '- Developed Java Spring microservices.',
            '',
            'EDUCATION',
            'MSc Software Engineering | University of Texas at Austin | 2012',
            '',
            'SKILLS',
            'Apex, LWC, SOQL, Integration Architecture, MuleSoft, Java, Data Modeling',
            '',
            'CERTIFICATIONS',
            'Salesforce Application Architect (2021)',
            'Salesforce Platform Developer II (2016)',
            'Salesforce Platform Developer II (2019)'
        }, '\n');
    public static String PRIYA = String.join(new List<String>{
            'Priya Nair',
            'Data Analyst',
            'priya.nair@example.com | +44 7700 900123 | London, UK',
            '',
            'SUMMARY',
            'Data analyst with 5 years of experience turning raw data into decisions.',
            '',
            'EXPERIENCE',
            'Data Analyst | Meridian Health | Feb 2021 - Present',
            '- Built CRM Analytics dashboards on top of Salesforce data for the sales team.',
            '- Automated reporting pipelines in Python and SQL.',
            'BI Intern | Quantica | Jun 2020 - Dec 2020',
            '- Produced Tableau reports for marketing.',
            '',
            'EDUCATION',
            'MSc Data Science | University of Edinburgh | 2020',
            '',
            'SKILLS',
            'SQL, Python, Tableau, Excel, Power BI'
        }, '\n');

    /** "Present" in the fixtures resolves to this date so year maths is stable. */
    public static final Date AS_OF = Date.newInstance(2026, 11, 12);

    public static User createAgentUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(10);
        User u = new User(
            Alias = 'cvagt', Email = 'cvagent' + unique + '@example.com', EmailEncodingKey = 'UTF-8',
            LastName = 'Recruiter', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York', Username = 'cvagent' + unique + '@example.com.test'
        );
        insert u;
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'CV_Review_Agent_User' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    public static User agentUser() {
        return [SELECT Id FROM User WHERE Alias = 'cvagt' AND LastName = 'Recruiter' ORDER BY CreatedDate DESC LIMIT 1];
    }

    /** Creates a Salesforce File and returns its ContentDocumentId. */
    public static Id createFile(String fileName, Blob body) {
        ContentVersion v = new ContentVersion(Title = fileName.substringBeforeLast('.'), PathOnClient = fileName, VersionData = body);
        insert v;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :v.Id].ContentDocumentId;
    }

    /** Ingests the five fixture CVs as .txt files and returns candidate ids by first name. */
    public static Map<String, Id> ingestAll() {
        List<Id> docs = new List<Id>{
            createFile('Sara_Haddad_CV.txt', Blob.valueOf(SARA)),
            createFile('Omar_Khalil_CV.txt', Blob.valueOf(OMAR)),
            createFile('Lina_Mansour_CV.txt', Blob.valueOf(LINA)),
            createFile('Daniel_Reyes_CV.txt', Blob.valueOf(DANIEL)),
            createFile('Priya_Nair_CV.txt', Blob.valueOf(PRIYA))
        };
        CvIngestionService.ingest(docs);
        Map<String, Id> byFirst = new Map<String, Id>();
        for (Candidate__c c : [SELECT Id, Name FROM Candidate__c]) { byFirst.put(c.Name.substringBefore(' '), c.Id); }
        return byFirst;
    }

    /** Minimal, valid single-page PDF with an uncompressed content stream. */
    public static Blob simplePdf(List<String> lines) {
        String stream = '';
        Integer y = 800;
        for (String l : lines) {
            stream += 'BT /F1 10 Tf 1 0 0 1 50 ' + y + ' Tm (' + l.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)') + ') Tj ET\n';
            y -= 14;
        }
        String pdf = '%PDF-1.3\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n' +
            '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n' +
            '3 0 obj << /Type /Page /Parent 2 0 R /Contents 4 0 R >> endobj\n' +
            '4 0 obj << /Length ' + stream.length() + ' >>\nstream\n' + stream + 'endstream\nendobj\n%%EOF';
        return Blob.valueOf(pdf);
    }

    /** Minimal DOCX (zip with word/document.xml). */
    public static Blob simpleDocx(List<String> paragraphs) {
        String body = '';
        for (String p : paragraphs) { body += '<w:p><w:r><w:t>' + p.escapeXml() + '</w:t></w:r></w:p>'; }
        String xml = '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + body + '</w:body></w:document>';
        Compression.ZipWriter w = new Compression.ZipWriter();
        w.addEntry('word/document.xml', Blob.valueOf(xml));
        return w.getArchive();
    }

    /** Stub LLM: returns a canned response, or throws when response is null. */
    public class StubLlm implements LlmProvider {
        public String response;
        public LlmRequest lastRequest;
        public StubLlm(String response) { this.response = response; }
        public String complete(LlmRequest req) {
            lastRequest = req;
            if (response == null) { throw new CalloutException('Simulated provider outage'); }
            return response;
        }
    }
}
