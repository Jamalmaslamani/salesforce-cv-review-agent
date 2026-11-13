import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

/** Visual language for data provenance, used everywhere in the agent UI. */
const STATUS = {
    FOUND: { icon: 'utility:success', variant: 'success', label: 'Found in CV' },
    INFERRED: { icon: 'utility:question_mark', variant: 'warning', label: 'Inferred - not stated directly' },
    MISSING: { icon: 'utility:ban', variant: 'error', label: 'Missing from CV' },
    CONFLICT: { icon: 'utility:warning', variant: 'error', label: 'Conflicting information' }
};
const SEVERITY_ORDER = { HIGH: 0, MEDIUM: 1, LOW: 2 };

export default class CandidateCard extends NavigationMixin(LightningElement) {
    @api candidate;
    @api selectable = false;
    @api selected = false;
    expanded = false;

    get card() {
        return this.candidate?.card || {};
    }

    get statusClass() {
        const s = this.candidate?.status;
        return 'slds-badge ' + (s === 'Extracted' ? 'slds-theme_success' : s === 'Failed' ? 'slds-theme_error' : 'slds-theme_warning');
    }

    get fields() {
        const c = this.card;
        const rows = [
            ['Email', c.email], ['Phone', c.phone], ['Location', c.location],
            ['Experience (computed)', c.totalYearsExperience, ' yrs'], ['Experience (claimed)', c.claimedYearsExperience, ' yrs']
        ];
        return rows
            .filter(([label, f]) => f || label !== 'Experience (claimed)')
            .map(([label, f, suffix]) => {
                const status = f?.status || 'MISSING';
                const meta = STATUS[status] || STATUS.MISSING;
                const value = f && f.value != null && status !== 'MISSING' ? f.value + (suffix || '') : 'Not stated';
                const tip = [meta.label, f?.note, f?.evidence ? 'Evidence: "' + f.evidence + '"' : null].filter(Boolean).join(' - ');
                return { key: label, label, value, icon: meta.icon, variant: meta.variant, tip, valueClass: status === 'MISSING' ? 'missing' : status === 'CONFLICT' ? 'conflict' : '' };
            });
    }

    get skills() {
        return (this.card.skills || []).map((s, i) => ({
            key: s.name + i,
            name: s.name + (s.status === 'INFERRED' ? ' ?' : ''),
            cls: 'skill ' + (s.status === 'INFERRED' ? 'skill-inferred' : 'skill-stated'),
            tip: (s.status === 'INFERRED' ? 'Inferred from: ' : '') + (s.evidence || '')
        }));
    }

    get experience() {
        return (this.card.experience || []).map((e, i) => ({
            key: 'e' + i,
            title: e.title || 'Untitled role',
            company: e.company,
            dates: (e.startDate || '?') + ' → ' + (e.isCurrent ? 'present' : e.endDate || '?') + (e.months ? ' (' + e.months + ' mo)' : ''),
            undated: !e.startDate
        }));
    }

    get education() {
        return (this.card.education || []).map((e, i) => ({
            key: 'ed' + i,
            text: [e.degree, e.institution].filter(Boolean).join(', ') + (e.year ? ' (' + e.year + ')' : ' (year not stated)')
        }));
    }

    get certifications() {
        return (this.card.certifications || []).map((c, i) => ({
            key: 'c' + i,
            text: c.name + (c.year ? ' (' + c.year + ')' : ''),
            conflict: c.status === 'CONFLICT'
        }));
    }

    get issues() {
        return [...(this.card.issues || [])]
            .filter((i) => !(i.type === 'INFERRED' && i.field === 'skills'))
            .sort((a, b) => (SEVERITY_ORDER[a.severity] ?? 3) - (SEVERITY_ORDER[b.severity] ?? 3))
            .map((i, idx) => ({
                key: 'i' + idx,
                label: i.type,
                message: i.message,
                cls: 'issue sev-' + (i.severity || 'LOW').toLowerCase()
            }));
    }

    get counts() {
        const all = this.card.issues || [];
        const n = (t) => all.filter((i) => i.type === t).length;
        return { missing: n('MISSING'), conflict: n('CONFLICT'), inferred: n('INFERRED'), ambiguous: n('AMBIGUOUS') };
    }

    get hasIssues() { return this.issues.length > 0; }
    get hasCerts() { return this.certifications.length > 0; }
    get hasEducation() { return this.education.length > 0; }
    get completenessLabel() { return (this.card.completeness ?? 0) + '% complete'; }
    get headline() { return this.card.headline?.value || 'No headline in CV'; }
    get toggleLabel() { return this.expanded ? 'Hide details' : 'Show details'; }
    get toggleIcon() { return this.expanded ? 'utility:chevronup' : 'utility:chevrondown'; }

    toggle() { this.expanded = !this.expanded; }

    handleSelect(event) {
        this.dispatchEvent(new CustomEvent('select', { detail: { id: this.candidate.id, selected: event.target.checked } }));
    }

    openRecord() {
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: this.candidate.id, actionName: 'view' } });
    }
}
