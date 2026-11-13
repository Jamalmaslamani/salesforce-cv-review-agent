/**
 * Turns uploaded files (ContentDocuments) into Candidate__c records with a Candidate Card.
 *
 * Flow per request:  read file -> extract text -> build card (LLM or rules) -> detect duplicates
 *                    -> upsert by Source_Document_Id__c -> link file to candidate -> audit log.
 * Each file is isolated: one bad CV never blocks the others (partial success is reported per file).
 * All extraction/callouts happen before any DML (Apex callout-after-DML rule).
 *
 * Scale note: this runs synchronously for up to MAX_FILES files. For bulk loads the same
 * service would be invoked from a Queueable per file (see README "What I'd do next").
 */
public with sharing class CvIngestionService {
    public static final Integer MAX_FILES = 10;

    public class FileResult {
        @AuraEnabled public String fileName;
        @AuraEnabled public Id candidateId;
        @AuraEnabled public String candidateName;
        @AuraEnabled public String status;   // Extracted | Needs Review | Failed
        @AuraEnabled public String message;
    }

    private class Pending {
        ContentVersion version;
        CandidateCard card;
        String rawText;
        Candidate__c record;
        FileResult result;
        Long startedMs;
    }

    public static List<FileResult> ingest(List<Id> contentDocumentIds) {
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) {
            throw new IngestionException('No files were provided.');
        }
        if (contentDocumentIds.size() > MAX_FILES) {
            throw new IngestionException('Please upload at most ' + MAX_FILES + ' CVs at a time.');
        }
        // Metadata first (no blobs) - respects the user's access to the files.
        List<ContentVersion> versions = [
            SELECT Id, ContentDocumentId, Title, FileExtension, PathOnClient, ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId IN :contentDocumentIds AND IsLatest = true
            WITH USER_MODE
        ];
        LlmProvider llm = LlmProviderFactory.get();
        List<Pending> work = new List<Pending>();

        // ---- Phase 1: extraction (may call out; no DML allowed here)
        for (ContentVersion v : versions) {
            Pending p = new Pending();
            p.version = v;
            p.startedMs = System.currentTimeMillis();
            p.result = new FileResult();
            p.result.fileName = fileName(v);
            work.add(p);
            try {
                Blob data = [SELECT VersionData FROM ContentVersion WHERE Id = :v.Id WITH USER_MODE].VersionData;
                buildCard(p, data, llm);
            } catch (Exception e) {
                p.result.status = 'Failed';
                p.result.message = e instanceof CvTextExtractor.ExtractionException ? e.getMessage() : 'Unexpected error: ' + e.getMessage();
                AgentLogger.error('INGEST', null, p.result.fileName, e);
            }
        }

        // ---- Phase 2: duplicate detection (same email, different file)
        flagDuplicates(work);

        // ---- Phase 3: persist
        List<Pending> toSave = new List<Pending>();
        List<Candidate__c> records = new List<Candidate__c>();
        for (Pending p : work) {
            if (p.record != null) {
                p.record.Card_JSON__c = serialize(p.card);
                toSave.add(p); records.add(p.record);
            }
        }
        if (!records.isEmpty()) {
            List<Database.UpsertResult> results = Database.upsert(records, Candidate__c.Source_Document_Id__c, false, AccessLevel.USER_MODE);
            List<ContentDocumentLink> links = new List<ContentDocumentLink>();
            for (Integer i = 0; i < results.size(); i++) {
                Pending p = toSave[i];
                if (results[i].isSuccess()) {
                    p.result.candidateId = results[i].getId();
                    if (results[i].isCreated()) {
                        links.add(new ContentDocumentLink(ContentDocumentId = p.version.ContentDocumentId, LinkedEntityId = results[i].getId(), ShareType = 'V'));
                    }
                    AgentLogger.log('INGEST', p.result.status == 'Extracted' ? AgentLogger.SUCCESS : AgentLogger.WARNING, p.result.candidateId,
                        p.result.fileName, p.result.message, System.currentTimeMillis() - p.startedMs);
                } else {
                    p.result.status = 'Failed';
                    p.result.message = 'Could not save candidate: ' + results[i].getErrors()[0].getMessage();
                    AgentLogger.log('INGEST', AgentLogger.ERROR, null, p.result.fileName, p.result.message, null);
                }
            }
            if (!links.isEmpty()) { Database.insert(links, false); }
        }
        AgentLogger.flush();

        List<FileResult> out = new List<FileResult>();
        for (Pending p : work) { out.add(p.result); }
        return out;
    }

    private static void buildCard(Pending p, Blob data, LlmProvider llm) {
        String name = fileName(p.version);
        CvTextExtractor.Result ext;
        List<String> notes = new List<String>();
        try {
            ext = CvTextExtractor.extract(data, name);
        } catch (CvTextExtractor.ExtractionException e) {
            throw e;
        }
        notes.addAll(ext.warnings);

        CandidateCard card;
        if (llm != null) {
            try {
                card = LlmCvExtractor.extract(llm, ext.text, ext.format == 'pdf' ? data : null);
            } catch (Exception e) {
                AgentLogger.error('INGEST_LLM', null, name, e);
                notes.add('AI extraction failed; fell back to the rule-based parser.');
            }
        }
        if (card == null) {
            card = new HeuristicCvParser().parse(ext.text);
        }
        p.card = card;
        p.rawText = ext.text;

        Boolean needsReview = (ext.needsReview && llm == null) || card.name == null || card.name.status == CandidateCard.MISSING;
        for (CandidateCard.Issue i : card.issues) {
            if (i.severity == 'HIGH' && i.type != CandidateCard.CONFLICT) { needsReview = true; }
        }
        p.result.status = needsReview ? 'Needs Review' : 'Extracted';
        p.result.candidateName = CandidateCard.valueOf(card.name) ?? p.version.Title;
        String issueSummary = card.countIssues(CandidateCard.MISSING) + ' missing, ' + card.countIssues(CandidateCard.CONFLICT) +
            ' conflicting, ' + card.countIssues(CandidateCard.INFERRED) + ' inferred.';
        notes.add(issueSummary);
        p.result.message = String.join(notes, ' ');
        p.record = toRecord(p, needsReview);
    }

    private static Candidate__c toRecord(Pending p, Boolean needsReview) {
        CandidateCard card = p.card;
        List<String> skills = new List<String>();
        for (CandidateCard.Skill s : card.skills) { skills.add(s.name); }
        return new Candidate__c(
            Name = p.result.candidateName.left(80),
            Email__c = CandidateCard.valueOf(card.email),
            Phone__c = CandidateCard.valueOf(card.phone)?.left(40),
            Location__c = CandidateCard.valueOf(card.location)?.left(255),
            Headline__c = CandidateCard.valueOf(card.headline)?.left(255),
            Total_Years_Experience__c = toDecimal(card.totalYearsExperience),
            Claimed_Years_Experience__c = toDecimal(card.claimedYearsExperience),
            Skills__c = String.join(skills, '; ').left(32768),
            Raw_Text__c = p.rawText?.left(131072),
            Extraction_Status__c = needsReview ? 'Needs Review' : 'Extracted',
            Extraction_Method__c = card.extractionMethod,
            Extraction_Message__c = p.result.message?.left(32768),
            Data_Completeness__c = card.completeness,
            Missing_Count__c = card.countIssues(CandidateCard.MISSING),
            Conflict_Count__c = card.countIssues(CandidateCard.CONFLICT),
            Inferred_Count__c = card.countIssues(CandidateCard.INFERRED),
            Source_Document_Id__c = p.version.ContentDocumentId,
            Source_File_Name__c = p.result.fileName.left(255),
            Extracted_At__c = System.now()
        );
    }

    /** Same email on a different source file = possible duplicate application. Flagged, not merged. */
    private static void flagDuplicates(List<Pending> work) {
        Map<String, Pending> byEmail = new Map<String, Pending>();
        Set<Id> docIds = new Set<Id>();
        for (Pending p : work) {
            if (p.record == null) { continue; }
            docIds.add(p.version.ContentDocumentId);
            if (p.record.Email__c != null) {
                String key = p.record.Email__c.toLowerCase();
                if (byEmail.containsKey(key)) {
                    addDuplicateIssue(p, byEmail.get(key).result.fileName);
                } else {
                    byEmail.put(key, p);
                }
            }
        }
        if (byEmail.isEmpty()) { return; }
        for (Candidate__c existing : [
            SELECT Id, Email__c, Source_File_Name__c FROM Candidate__c
            WHERE Email__c IN :byEmail.keySet() AND Source_Document_Id__c NOT IN :docIds
            WITH USER_MODE LIMIT 200
        ]) {
            Pending p = byEmail.get(existing.Email__c.toLowerCase());
            if (p != null) { addDuplicateIssue(p, existing.Source_File_Name__c); }
        }
    }

    private static void addDuplicateIssue(Pending p, String otherFile) {
        p.card.addIssue('AMBIGUOUS', 'duplicate', 'Another CV (' + otherFile + ') has the same email address - possible duplicate application.', p.record.Email__c, 'MEDIUM');
        p.result.message += ' Possible duplicate of ' + otherFile + '.';
        p.record.Extraction_Message__c = p.result.message.left(32768);
    }

    private static Decimal toDecimal(CandidateCard.CardField f) {
        if (f == null || f.status == CandidateCard.MISSING || String.isBlank(f.value)) { return null; }
        try { return Decimal.valueOf(f.value); } catch (Exception e) { return null; }
    }

    private static String serialize(CandidateCard card) {
        String pretty = card.toJson();
        return pretty.length() <= 131072 ? pretty : JSON.serialize(card, true);
    }

    private static String fileName(ContentVersion v) {
        if (String.isNotBlank(v.PathOnClient)) {
            String n = v.PathOnClient;
            if (n.contains('/')) { n = n.substringAfterLast('/'); }
            if (n.contains('\\')) { n = n.substringAfterLast('\\'); }
            return n;
        }
        return v.Title + (String.isBlank(v.FileExtension) ? '' : '.' + v.FileExtension);
    }

    public class IngestionException extends Exception {}
}
