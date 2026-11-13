/**
 * Loads the five synthetic CVs shipped in static resource CvAgentSampleCvs (a zip) as Salesforce
 * Files, so reviewers can try the agent in one click. Only creates the files; ingestion runs in a
 * separate request so that LLM callouts are not blocked by this transaction's DML.
 */
public with sharing class SampleDataService {
    public static final String RESOURCE = 'CvAgentSampleCvs';

    public static List<Id> createSampleFiles() {
        List<StaticResource> res = [SELECT Body FROM StaticResource WHERE Name = :RESOURCE LIMIT 1];
        if (res.isEmpty()) { throw new SampleException('Static resource ' + RESOURCE + ' is missing.'); }
        Set<String> already = new Set<String>();
        for (Candidate__c c : [SELECT Source_File_Name__c FROM Candidate__c WHERE Source_File_Name__c != null WITH USER_MODE LIMIT 2000]) {
            already.add(c.Source_File_Name__c);
        }
        Compression.ZipReader zip = new Compression.ZipReader(res[0].Body);
        List<ContentVersion> versions = new List<ContentVersion>();
        for (Compression.ZipEntry e : zip.getEntries()) {
            String name = e.getName();
            if (name.endsWith('/') || name.startsWith('__MACOSX')) { continue; }
            if (name.contains('/')) { name = name.substringAfterLast('/'); }
            if (already.contains(name)) { continue; }
            versions.add(new ContentVersion(Title = name.substringBeforeLast('.'), PathOnClient = name, VersionData = zip.extract(e)));
        }
        if (versions.isEmpty()) { return new List<Id>(); }
        Database.insert(versions, AccessLevel.USER_MODE);
        List<Id> docIds = new List<Id>();
        for (ContentVersion v : [SELECT ContentDocumentId FROM ContentVersion WHERE Id IN :versions WITH USER_MODE]) { docIds.add(v.ContentDocumentId); }
        return docIds;
    }

    public class SampleException extends Exception {}
}
