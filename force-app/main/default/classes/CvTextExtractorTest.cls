@IsTest
private class CvTextExtractorTest {
    @IsTest
    static void readsUncompressedPdf() {
        CvTextExtractor.Result r = CvTextExtractor.extract(
            TestDataFactory.simplePdf(new List<String>{ 'Jane Roe', 'Engineer (Apex)', 'SKILLS', 'Apex, SOQL, LWC, Platform Events, REST APIs, Git' }), 'jane.pdf');
        Assert.areEqual('pdf', r.format);
        Assert.isTrue(r.text.contains('Jane Roe'), r.text);
        Assert.isTrue(r.text.contains('Engineer (Apex)'), 'escaped parentheses decoded: ' + r.text);
        Assert.isFalse(r.needsReview);
    }

    @IsTest
    static void compressedPdfIsFlaggedForReview() {
        String pdf = '%PDF-1.4\n4 0 obj << /Length 10 /Filter /FlateDecode >>\nstream\nxxxxxxxxxx\nendstream\nendobj\n%%EOF';
        CvTextExtractor.Result r = CvTextExtractor.extract(Blob.valueOf(pdf), 'scan.pdf');
        Assert.isTrue(r.needsReview);
        Assert.isTrue(String.join(r.warnings, ' ').contains('compressed'));
    }

    @IsTest
    static void readsDocx() {
        CvTextExtractor.Result r = CvTextExtractor.extract(
            TestDataFactory.simpleDocx(new List<String>{ 'Jane Roe', 'R&D Engineer', 'Built things with Apex and Lightning Web Components for many years.' }), 'jane.docx');
        Assert.isTrue(r.text.contains('R&D Engineer'), r.text);
        Assert.isTrue(r.text.contains('\n'), 'paragraphs become lines');
    }

    @IsTest
    static void rejectsUnsupportedAndBrokenFiles() {
        List<String> names = new List<String>{ 'cv.doc', 'cv.png', 'cv.pdf', 'cv.docx' };
        List<Blob> bodies = new List<Blob>{ Blob.valueOf('x'), Blob.valueOf('x'), Blob.valueOf('not a pdf'), Blob.valueOf('not a zip') };
        for (Integer i = 0; i < names.size(); i++) {
            try {
                CvTextExtractor.extract(bodies[i], names[i]);
                Assert.fail('Expected failure for ' + names[i]);
            } catch (CvTextExtractor.ExtractionException e) {
                Assert.isTrue(String.isNotBlank(e.getMessage()));
            }
        }
        try {
            CvTextExtractor.extract(null, 'empty.pdf');
            Assert.fail('Expected failure for empty file');
        } catch (CvTextExtractor.ExtractionException e) {
            Assert.isTrue(e.getMessage().contains('empty'));
        }
    }

    @IsTest
    static void shortTextNeedsReview() {
        CvTextExtractor.Result r = CvTextExtractor.extract(Blob.valueOf('Hi'), 'tiny.txt');
        Assert.isTrue(r.needsReview);
    }
}
