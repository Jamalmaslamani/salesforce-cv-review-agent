import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import getCandidates from '@salesforce/apex/CvAgentController.getCandidates';
import processFiles from '@salesforce/apex/CvAgentController.processFiles';
import createSampleFiles from '@salesforce/apex/CvAgentController.createSampleFiles';
import ask from '@salesforce/apex/CvAgentController.ask';
import evaluate from '@salesforce/apex/CvAgentController.evaluate';
import bookmark from '@salesforce/apex/CvAgentController.bookmark';
import getAgentInfo from '@salesforce/apex/CvAgentController.getAgentInfo';

const EXAMPLE_QUESTIONS = [
    'Which candidates know LWC and Apex?',
    'Who has at least 8 years of experience?',
    'What are the risks with Omar?',
    'How can I contact Lina?',
    'Is Daniel certified?',
    'Who speaks Mandarin?'
];
const EXAMPLE_ROLE = {
    title: 'Senior Salesforce Developer',
    required: 'Apex, LWC, SOQL, REST APIs',
    nice: 'Agentforce, Platform Events, CI/CD',
    minYears: 5
};
const CONFIDENCE_THEME = { HIGH: 'slds-theme_success', MEDIUM: 'slds-theme_warning', LOW: 'slds-theme_warning', NONE: 'slds-theme_shade' };
const TIER_THEME = { 'Strong Match': 'slds-theme_success', 'Possible Match': 'slds-theme_warning', 'Weak Match': 'slds-theme_error' };

function errorMessage(error) {
    if (!error) return 'Unknown error';
    if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
    return error.body?.message || error.message || 'Unknown error';
}

export default class CvReviewAgent extends NavigationMixin(LightningElement) {
    candidates = [];
    selectedIds = new Set();
    fileResults = [];
    busy = false;
    busyLabel = '';
    filter = '';
    info;

    question = '';
    conversation = [];
    askScope = [];

    role = { ...EXAMPLE_ROLE };
    compareScope = [];
    evaluation;
    expandedEval = {};

    bookmarkTarget;
    bookmarkNotes = '';

    exampleQuestions = EXAMPLE_QUESTIONS.map((q) => ({ key: q, label: q }));
    acceptedFormats = ['.pdf', '.docx', '.doc', '.txt'];

    connectedCallback() {
        this.loadCandidates();
        getAgentInfo().then((i) => { this.info = i; }).catch(() => {});
    }

    // ------------------------------------------------------------ candidates
    async loadCandidates() {
        try {
            this.candidates = await getCandidates();
        } catch (e) {
            this.toast('Could not load candidates', errorMessage(e), 'error');
        }
    }

    get hasCandidates() { return this.candidates.length > 0; }
    get candidateCount() { return this.candidates.length; }
    get providerLabel() { return this.info ? 'AI provider: ' + this.info.provider + (this.info.provider === 'Mock' ? ' (deterministic rules, no data leaves Salesforce)' : '') : ''; }
    get scoringLabel() { return this.info ? 'Scoring ' + this.info.scoringVersion : ''; }

    get filteredCandidates() {
        const f = this.filter.trim().toLowerCase();
        return this.candidates
            .filter((c) => !f || (c.name + ' ' + (c.card?.skills || []).map((s) => s.name).join(' ') + ' ' + (c.card?.headline?.value || '')).toLowerCase().includes(f))
            .map((c) => ({ ...c, selected: this.selectedIds.has(c.id) }));
    }

    get candidateOptions() {
        return this.candidates.map((c) => ({ label: c.name, value: c.id }));
    }

    handleFilter(e) { this.filter = e.target.value; }

    async handleUploadFinished(event) {
        const ids = event.detail.files.map((f) => f.documentId);
        await this.ingest(ids);
    }

    async handleLoadSamples() {
        this.setBusy('Creating sample CV files...');
        try {
            const ids = await createSampleFiles();
            if (!ids.length) {
                this.toast('Samples already loaded', 'The five sample CVs are already in the system.', 'info');
                return;
            }
            await this.ingest(ids);
        } catch (e) {
            this.toast('Could not load samples', errorMessage(e), 'error');
        } finally {
            this.setBusy();
        }
    }

    async ingest(ids) {
        this.setBusy('Reading and structuring ' + ids.length + ' CV(s)...');
        try {
            const results = await processFiles({ contentDocumentIds: ids });
            this.fileResults = results.map((r, i) => ({
                ...r,
                key: 'r' + i,
                cls: 'slds-badge ' + (r.status === 'Extracted' ? 'slds-theme_success' : r.status === 'Failed' ? 'slds-theme_error' : 'slds-theme_warning')
            }));
            const failed = results.filter((r) => r.status === 'Failed').length;
            this.toast('CVs processed', (results.length - failed) + ' of ' + results.length + ' CV(s) structured' + (failed ? ', ' + failed + ' failed (see details)' : '.'), failed ? 'warning' : 'success');
            await this.loadCandidates();
        } catch (e) {
            this.toast('Processing failed', errorMessage(e), 'error');
        } finally {
            this.setBusy();
        }
    }

    get hasFileResults() { return this.fileResults.length > 0; }

    handleCardSelect(event) {
        const { id, selected } = event.detail;
        const next = new Set(this.selectedIds);
        if (selected) next.add(id); else next.delete(id);
        this.selectedIds = next;
        this.compareScope = [...next];
        this.askScope = [...next];
    }

    // ------------------------------------------------------------ ask
    handleQuestion(e) { this.question = e.target.value; }
    handleAskScope(e) { this.askScope = e.detail.value; }
    handleExample(e) { this.question = e.target.dataset.q; this.handleAsk(); }
    handleQuestionKey(e) { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); this.handleAsk(); } }

    async handleAsk() {
        const q = (this.question || '').trim();
        if (!q) return;
        this.setBusy('Searching the CVs...');
        try {
            const a = await ask({ question: q, candidateIds: this.askScope });
            const entry = {
                key: 'q' + Date.now(),
                question: q,
                answer: a.answer,
                confidence: a.confidence,
                confidenceClass: 'slds-badge ' + (CONFIDENCE_THEME[a.confidence] || ''),
                confidenceLabel: a.confidence === 'NONE' ? 'Not in the CVs' : a.confidence + ' confidence',
                mode: a.mode + ' · ' + a.candidatesConsidered + ' CV(s) searched',
                warnings: (a.warnings || []).map((w, i) => ({ key: 'w' + i, text: w })),
                citations: (a.citations || []).map((c, i) => ({ key: 'c' + i, who: c.candidateName, snippet: c.snippet })),
                hasCitations: (a.citations || []).length > 0,
                hasWarnings: (a.warnings || []).length > 0
            };
            this.conversation = [entry, ...this.conversation];
            this.question = '';
        } catch (e) {
            this.toast('Could not answer', errorMessage(e), 'error');
        } finally {
            this.setBusy();
        }
    }

    get hasConversation() { return this.conversation.length > 0; }

    // ------------------------------------------------------------ compare
    handleRoleField(e) {
        const field = e.target.dataset.field;
        this.role = { ...this.role, [field]: e.target.value };
    }
    handleCompareScope(e) { this.compareScope = e.detail.value; }
    handleExampleRole() { this.role = { ...EXAMPLE_ROLE }; }
    handleNoMatchRole() { this.role = { title: 'Salesforce Data Cloud Engineer', required: 'Data Cloud, Python, SQL', nice: 'Agentforce', minYears: 4 }; }

    get roleProfile() {
        const split = (s) => (s || '').split(',').map((x) => x.trim()).filter(Boolean);
        return {
            title: this.role.title,
            requiredSkills: split(this.role.required),
            niceToHaveSkills: split(this.role.nice),
            minYears: this.role.minYears === '' || this.role.minYears == null ? null : Number(this.role.minYears)
        };
    }

    async handleEvaluate() {
        this.setBusy('Scoring candidates...');
        try {
            const res = await evaluate({ roleJson: JSON.stringify(this.roleProfile), candidateIds: this.compareScope });
            this.evaluation = res;
            this.expandedEval = {};
        } catch (e) {
            this.toast('Could not evaluate', errorMessage(e), 'error');
        } finally {
            this.setBusy();
        }
    }

    get hasEvaluation() { return !!this.evaluation; }
    get recommendationClass() {
        return 'slds-box slds-m-bottom_small recommendation ' + (this.evaluation?.noStrongMatch ? 'rec-warning' : 'rec-success');
    }
    get recommendationIcon() { return this.evaluation?.noStrongMatch ? 'utility:warning' : 'utility:like'; }
    get tradeOffs() { return (this.evaluation?.tradeOffs || []).map((t, i) => ({ key: 't' + i, text: t })); }
    get hasTradeOffs() { return this.tradeOffs.length > 0; }
    get weightsLabel() {
        if (!this.info?.weights) return '';
        return Object.entries(this.info.weights).map(([k, v]) => k + ' ' + Math.round(v * 100) + '%').join(' · ');
    }

    get rankedEvaluations() {
        if (!this.evaluation) return [];
        const recommended = new Set(this.evaluation.recommendedIds || []);
        return this.evaluation.evaluations.map((e) => ({
            ...e,
            key: e.candidateId,
            tierClass: 'slds-badge ' + (TIER_THEME[e.tier] || ''),
            barStyle: 'width:' + Math.max(2, Math.min(100, e.score)) + '%',
            barClass: 'bar ' + (e.tier === 'Strong Match' ? 'bar-strong' : e.tier === 'Possible Match' ? 'bar-possible' : 'bar-weak'),
            recommended: recommended.has(e.candidateId),
            expanded: !!this.expandedEval[e.candidateId],
            toggleLabel: this.expandedEval[e.candidateId] ? 'Hide reasoning' : 'Why this score?',
            breakdown: e.breakdown.map((b, i) => ({ ...b, key: 'b' + i, pts: b.points + ' / ' + b.maxPoints })),
            strengthList: e.strengths.map((s, i) => ({ key: 's' + i, text: s })),
            concernList: e.concerns.map((s, i) => ({ key: 'c' + i, text: s })),
            focusList: e.interviewFocus.map((s, i) => ({ key: 'f' + i, text: s })),
            hasStrengths: e.strengths.length > 0,
            hasConcerns: e.concerns.length > 0,
            hasFocus: e.interviewFocus.length > 0
        }));
    }

    toggleEval(e) {
        const id = e.target.dataset.id;
        this.expandedEval = { ...this.expandedEval, [id]: !this.expandedEval[id] };
    }

    // ------------------------------------------------------------ bookmark
    openBookmark(e) {
        const id = e.target.dataset.id;
        this.bookmarkTarget = this.evaluation.evaluations.find((x) => x.candidateId === id);
        this.bookmarkNotes = '';
    }
    closeBookmark() { this.bookmarkTarget = null; }
    handleNotes(e) { this.bookmarkNotes = e.target.value; }
    get showBookmark() { return !!this.bookmarkTarget; }

    async saveBookmark() {
        const ev = this.bookmarkTarget;
        this.setBusy('Saving bookmark...');
        try {
            const id = await bookmark({
                candidateId: ev.candidateId,
                evaluationJson: JSON.stringify(ev),
                roleJson: JSON.stringify(this.roleProfile),
                notes: this.bookmarkNotes,
                comparedCount: this.evaluation.evaluations.length,
                scoringVersion: this.evaluation.scoringVersion,
                correlationId: this.evaluation.correlationId
            });
            this.bookmarkTarget = null;
            const url = await this[NavigationMixin.GenerateUrl]({ type: 'standard__recordPage', attributes: { recordId: id, actionName: 'view' } });
            this.dispatchEvent(new ShowToastEvent({
                title: 'Candidate bookmarked',
                message: '{0} saved for "' + this.role.title + '". {1}',
                messageData: [ev.candidateName, { url, label: 'Open bookmark' }],
                variant: 'success'
            }));
        } catch (e) {
            this.toast('Could not bookmark', errorMessage(e), 'error');
        } finally {
            this.setBusy();
        }
    }

    // ------------------------------------------------------------ utils
    setBusy(label) { this.busy = !!label; this.busyLabel = label || ''; }
    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
}
