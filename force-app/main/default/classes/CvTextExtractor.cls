/**
 * Converts an uploaded CV file into plain text, natively in Apex (no external service).
 *
 *  - DOCX : unzipped with Compression.ZipReader, text taken from word/document.xml.
 *  - PDF  : lightweight content-stream reader (Tj/TJ text operators in uncompressed streams).
 *           PDFs with compressed (FlateDecode) streams or scanned images cannot be read natively;
 *           they are flagged "Needs Review" instead of guessing. With the Anthropic provider
 *           enabled, PDFs are sent to the model as native document blocks instead (see LlmCvExtractor).
 *  - TXT  : read as-is.
 *  - DOC  : legacy binary Word is rejected with an actionable message.
 *
 * Trade-off: a production build would use a document-AI service (or the LLM) for all formats;
 * this keeps the prototype dependency-free and deterministic for testing.
 */
public with sharing class CvTextExtractor {
    public class ExtractionException extends Exception {}

    public static final Integer MAX_BYTES = 3 * 1024 * 1024;
    /** Native PDF parsing is CPU-bound in Apex; larger PDFs go to review / LLM. */
    public static final Integer MAX_NATIVE_PDF_BYTES = 750 * 1024;

    public class Result {
        @AuraEnabled public String text;
        @AuraEnabled public String format;
        @AuraEnabled public List<String> warnings = new List<String>();
        @AuraEnabled public Boolean needsReview = false;
    }

    public static Result extract(Blob body, String fileName) {
        Result r = new Result();
        r.format = extension(fileName);
        if (body == null || body.size() == 0) {
            throw new ExtractionException('The file "' + fileName + '" is empty.');
        }
        if (body.size() > MAX_BYTES) {
            throw new ExtractionException('The file "' + fileName + '" is larger than 3 MB; CVs are expected to be small documents.');
        }
        switch on r.format {
            when 'pdf' { r.text = extractPdf(body, r); }
            when 'docx' { r.text = extractDocx(body); }
            when 'txt' { r.text = body.toString(); }
            when 'doc' {
                throw new ExtractionException('Legacy .doc (Word 97-2003) files are not supported. Please save the CV as .docx or PDF.');
            }
            when else {
                throw new ExtractionException('Unsupported file type ".' + r.format + '". Supported: PDF, DOCX, TXT.');
            }
        }
        r.text = normalize(r.text);
        if (String.isBlank(r.text) || r.text.length() < 80) {
            r.needsReview = true;
            r.warnings.add('Very little text could be extracted. The file may be a scanned image or use compressed/encoded text.');
        }
        return r;
    }

    public static String extension(String fileName) {
        if (String.isBlank(fileName) || !fileName.contains('.')) { return ''; }
        return fileName.substringAfterLast('.').toLowerCase();
    }

    // ------------------------------------------------------------------ DOCX
    @TestVisible
    private static String extractDocx(Blob body) {
        try {
            Compression.ZipReader reader = new Compression.ZipReader(body);
            Compression.ZipEntry entry = reader.getEntry('word/document.xml');
            if (entry == null) {
                throw new ExtractionException('The DOCX file has no document body (word/document.xml missing).');
            }
            String xml = reader.extract(entry).toString();
            xml = xml.replace('</w:p>', '\n').replace('<w:tab/>', '\t').replace('<w:br/>', '\n');
            xml = xml.replaceAll('<[^>]+>', '');
            return xml.unescapeXml();
        } catch (ExtractionException e) {
            throw e;
        } catch (Exception e) {
            throw new ExtractionException('The DOCX file could not be opened (corrupted or not a real .docx).');
        }
    }

    // ------------------------------------------------------------------ PDF
    @TestVisible
    private static String extractPdf(Blob body, Result r) {
        if (body.size() > MAX_NATIVE_PDF_BYTES) {
            r.needsReview = true;
            r.warnings.add('PDF too large for native parsing; enable the LLM provider or upload a DOCX.');
            return '';
        }
        String raw = toLatin1(body);
        if (!raw.startsWith('%PDF')) {
            throw new ExtractionException('The file does not look like a valid PDF.');
        }
        List<String> lines = new List<String>();
        Integer compressedStreams = 0;
        Integer pos = 0;
        while (true) {
            Integer s = raw.indexOf('stream', pos);
            if (s < 0) { break; }
            if (s >= 3 && raw.substring(s - 3, s) == 'end') { pos = s + 6; continue; }
            Integer e = raw.indexOf('endstream', s + 6);
            if (e < 0) { break; }
            String dict = raw.substring(Math.max(0, s - 300), s);
            dict = dict.substring(dict.lastIndexOf('obj') >= 0 ? dict.lastIndexOf('obj') : 0);
            String content = raw.substring(s + 6, e);
            if (dict.contains('/Filter')) {
                compressedStreams++;
            } else if (content.contains('BT')) {
                lines.addAll(readTextObjects(content));
            }
            pos = e + 9;
        }
        if (lines.isEmpty() && compressedStreams > 0) {
            r.needsReview = true;
            r.warnings.add('This PDF uses compressed content streams, which cannot be decoded natively in Apex. ' +
                'Enable the LLM provider (native PDF support) or upload the CV as DOCX.');
        }
        return String.join(lines, '\n');
    }

    /** Reads string operands of text-showing operators inside BT ... ET blocks. One block = one line. */
    @TestVisible
    private static List<String> readTextObjects(String content) {
        List<String> out = new List<String>();
        Integer pos = 0;
        while (true) {
            Integer bt = content.indexOf('BT', pos);
            if (bt < 0) { break; }
            Integer et = content.indexOf('ET', bt + 2);
            if (et < 0) { et = content.length(); }
            String block = content.substring(bt + 2, et);
            String line = readStrings(block);
            if (String.isNotBlank(line)) { out.add(line); }
            pos = et + 2;
        }
        return out;
    }

    private static String readStrings(String block) {
        List<Integer> chars = new List<Integer>();
        Integer i = 0;
        Integer n = block.length();
        while (i < n) {
            Integer c = block.charAt(i);
            if (c == 40) { // '('
                Integer depth = 1;
                i++;
                while (i < n && depth > 0) {
                    Integer d = block.charAt(i);
                    if (d == 92 && i + 1 < n) { // backslash escape
                        Integer nx = block.charAt(i + 1);
                        if (nx >= 48 && nx <= 55) { // octal \ddd
                            Integer val = 0; Integer k = 0;
                            while (k < 3 && i + 1 < n && block.charAt(i + 1) >= 48 && block.charAt(i + 1) <= 55) {
                                val = val * 8 + (block.charAt(i + 1) - 48); i++; k++;
                            }
                            chars.add(winAnsi(val));
                            i++;
                            continue;
                        }
                        if (nx == 110) { chars.add(10); } else if (nx == 116) { chars.add(32); }
                        else if (nx != 114 && nx != 98 && nx != 102) { chars.add(nx); }
                        i += 2;
                        continue;
                    }
                    if (d == 40) { depth++; }
                    if (d == 41) { depth--; if (depth == 0) { break; } }
                    chars.add(winAnsi(d));
                    i++;
                }
            } else if (c == 84 && i + 1 < n && (block.charAt(i + 1) == 42 || block.charAt(i + 1) == 100 || block.charAt(i + 1) == 68)) {
                // T*, Td, TD = move to next line within the same text object
                if (!chars.isEmpty() && chars[chars.size() - 1] != 10) { chars.add(32); }
            }
            i++;
        }
        return chars.isEmpty() ? '' : String.fromCharArray(chars).trim();
    }

    /** Maps the few WinAnsi code points that differ from Latin-1 to sensible characters. */
    private static Integer winAnsi(Integer code) {
        switch on code {
            when 145, 146 { return 39; }      // curly single quotes -> '
            when 147, 148 { return 34; }      // curly double quotes -> "
            when 150, 151 { return 45; }      // en/em dash -> -
            when 149 { return 8226; }         // bullet
            when else { return code; }
        }
    }

    private static String toLatin1(Blob b) {
        String hex = EncodingUtil.convertToHex(b);
        Integer n = hex.length();
        List<Integer> codes = new List<Integer>();
        for (Integer i = 0; i < n; i += 2) {
            codes.add(hexVal(hex.charAt(i)) * 16 + hexVal(hex.charAt(i + 1)));
        }
        return String.fromCharArray(codes);
    }

    private static Integer hexVal(Integer c) {
        return c <= 57 ? c - 48 : c - 87; // '0'-'9' or 'a'-'f'
    }

    @TestVisible
    private static String normalize(String text) {
        if (text == null) { return ''; }
        String t = text.replace('\r\n', '\n').replace('\r', '\n').replace(' ', ' ');
        t = t.replaceAll('[ \\t]+\\n', '\n').replaceAll('\\n{3,}', '\n\n');
        return t.trim();
    }
}
