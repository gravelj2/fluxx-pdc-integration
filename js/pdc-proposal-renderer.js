(function(global) {
    'use strict';

    var FIELDS_PER_PAGE = 50;

    var PDCRenderer = {};

    // =========================================================================
    // Entry (Proposal) Rendering
    // =========================================================================

    /**
     * Render entries (proposals) into a container
     * @param {Object} data - API response with entries array
     * @param {HTMLElement} container - DOM element to render into
     */
    PDCRenderer.renderEntries = function(data, container) {
        if (!container) {
            console.error('PDCRenderer: Container element not provided');
            return;
        }

        container.innerHTML = '';

        if (!data || !data.entries || data.entries.length === 0) {
            container.innerHTML = '<div class="pdc-no-results">No entries found</div>';
            return;
        }

        var fragment = document.createDocumentFragment();

        data.entries.forEach(function(entry, index) {
            var entryEl = PDCRenderer._createEntryElement(entry, index);
            fragment.appendChild(entryEl);
        });

        container.appendChild(fragment);
    };

    PDCRenderer._createEntryElement = function(entry, index) {
        var entryEl = document.createElement('div');
        entryEl.className = 'pdc-entry-item';
        entryEl.dataset.index = index;

        var opportunityTitle = (entry.opportunity && entry.opportunity.title) || 'Untitled Opportunity';
        var funderName = (entry.opportunity && entry.opportunity.funder && entry.opportunity.funder.name) || 'Unknown Funder';
        var versionCount = (entry.versions && entry.versions.length) || 0;

        entryEl.dataset.searchText = (opportunityTitle + ' ' + funderName).toLowerCase();

        entryEl.innerHTML =
            '<div class="pdc-entry-header">' +
                '<span class="pdc-entry-toggle">▶</span>' +
                '<div class="pdc-entry-info">' +
                    '<div class="pdc-entry-title">' + PDCRenderer._escapeHtml(opportunityTitle) + '</div>' +
                    '<div class="pdc-entry-meta">' +
                        '<span>Funder: ' + PDCRenderer._escapeHtml(funderName) + '</span>' +
                        '<span>Versions: ' + versionCount + '</span>' +
                    '</div>' +
                '</div>' +
                '<span class="pdc-entry-id">#' + entry.id + '</span>' +
            '</div>' +
            '<div class="pdc-entry-content"></div>';

        // Attach click handler
        var header = entryEl.querySelector('.pdc-entry-header');
        header.addEventListener('click', function() {
            PDCRenderer._toggleEntry(entryEl, entry);
        });

        return entryEl;
    };

    PDCRenderer._toggleEntry = function(element, entry) {
        var wasExpanded = element.classList.contains('expanded');
        element.classList.toggle('expanded');

        if (!wasExpanded) {
            var content = element.querySelector('.pdc-entry-content');
            if (!content.dataset.loaded) {
                PDCRenderer.renderVersions(content, entry.versions || []);
                content.dataset.loaded = 'true';
            }
        }
    };

    // =========================================================================
    // Version Rendering
    // =========================================================================

    /**
     * Render versions into a container
     * @param {HTMLElement} container - DOM element to render into
     * @param {Array} versions - Array of version objects
     */
    PDCRenderer.renderVersions = function(container, versions) {
        if (!container) {
            console.error('PDCRenderer: Container element not provided');
            return;
        }

        container.innerHTML = '';

        if (!versions || versions.length === 0) {
            container.innerHTML = '<div class="pdc-no-results">No versions available</div>';
            return;
        }

        var fragment = document.createDocumentFragment();

        versions.forEach(function(version, idx) {
            var versionEl = PDCRenderer._createVersionElement(version, idx);
            fragment.appendChild(versionEl);
        });

        container.appendChild(fragment);
    };

    PDCRenderer._createVersionElement = function(version, idx) {
        var versionEl = document.createElement('div');
        versionEl.className = 'pdc-version-section';

        var sourceLabel = (version.source && version.source.label) || 'Unknown Source';
        var fieldCount = (version.fieldValues && version.fieldValues.length) || 0;
        var versionNum = version.version || idx + 1;

        versionEl.innerHTML =
            '<div class="pdc-version-header">' +
                '<span class="pdc-version-label">' + PDCRenderer._escapeHtml(sourceLabel) + '</span>' +
                '<span class="pdc-version-meta">v' + versionNum + ' | ' + fieldCount + ' fields</span>' +
            '</div>' +
            '<div class="pdc-version-content"></div>';

        var header = versionEl.querySelector('.pdc-version-header');
        header.addEventListener('click', function() {
            PDCRenderer._toggleVersion(versionEl, version);
        });

        return versionEl;
    };

    PDCRenderer._toggleVersion = function(element, version) {
        var wasExpanded = element.classList.contains('expanded');
        element.classList.toggle('expanded');

        if (!wasExpanded) {
            var content = element.querySelector('.pdc-version-content');
            if (!content.dataset.loaded) {
                PDCRenderer.renderFieldValues(content, version.fieldValues || []);
                content.dataset.loaded = 'true';
            }
        }
    };

    // =========================================================================
    // Field Value Rendering (with pagination)
    // =========================================================================

    /**
     * Render field values into a container (with lazy loading)
     * @param {HTMLElement} container - DOM element to render into
     * @param {Array} fieldValues - Array of field value objects
     */
    PDCRenderer.renderFieldValues = function(container, fieldValues) {
        if (!container) {
            console.error('PDCRenderer: Container element not provided');
            return;
        }

        container.innerHTML = '';

        if (!fieldValues || fieldValues.length === 0) {
            container.innerHTML = '<div class="pdc-no-results">No field values</div>';
            return;
        }

        // Sort by position
        var sorted = fieldValues.slice().sort(function(a, b) {
            var posA = (a.applicationFormField && a.applicationFormField.position) || a.position || 999;
            var posB = (b.applicationFormField && b.applicationFormField.position) || b.position || 999;
            return posA - posB;
        });

        // Create closure for pagination state
        var state = {
            loaded: 0,
            sorted: sorted,
            container: container
        };

        PDCRenderer._loadMoreFields(state);
    };

    PDCRenderer._loadMoreFields = function(state) {
        var end = Math.min(state.loaded + FIELDS_PER_PAGE, state.sorted.length);
        var fragment = document.createDocumentFragment();

        for (var i = state.loaded; i < end; i++) {
            var fieldEl = PDCRenderer._createFieldElement(state.sorted[i]);
            fragment.appendChild(fieldEl);
        }

        // Remove existing load-more button before appending
        var existingBtn = state.container.querySelector('.pdc-load-more');
        if (existingBtn) {
            existingBtn.remove();
        }

        state.container.appendChild(fragment);
        state.loaded = end;

        // Add load-more button if needed
        if (state.loaded < state.sorted.length) {
            var remaining = state.sorted.length - state.loaded;
            var btn = document.createElement('div');
            btn.className = 'pdc-load-more';
            btn.textContent = 'Load more (' + remaining + ' remaining)';
            btn.addEventListener('click', function() {
                PDCRenderer._loadMoreFields(state);
            });
            state.container.appendChild(btn);
        }
    };

    PDCRenderer._createFieldElement = function(fv) {
        var field = fv.applicationFormField || {};
        var label = field.label || 'Unknown Field';
        var instructions = field.instructions || '';
        var position = field.position || fv.position || '-';
        var value = fv.value || '';

        var fieldEl = document.createElement('div');
        fieldEl.className = 'pdc-field-item';

        var isLongText = value.length > 200;
        var valueClass = 'pdc-field-value';
        if (!value) {
            valueClass += ' empty';
        } else if (isLongText) {
            valueClass += ' truncated';
        }

        var html =
            '<div class="pdc-field-label">' +
                PDCRenderer._escapeHtml(label) +
                ' <span class="pdc-field-position">#' + position + '</span>' +
            '</div>';

        if (instructions) {
            html += '<div class="pdc-field-instructions">' + PDCRenderer._escapeHtml(instructions) + '</div>';
        }

        html += '<div class="' + valueClass + '">' + PDCRenderer._escapeHtml(value || '(no response)') + '</div>';

        if (isLongText) {
            html += '<span class="pdc-text-toggle">Show more</span>';
        }

        fieldEl.innerHTML = html;

        // Attach toggle handler for long text
        if (isLongText) {
            var toggle = fieldEl.querySelector('.pdc-text-toggle');
            var valueEl = fieldEl.querySelector('.pdc-field-value');
            toggle.addEventListener('click', function() {
                valueEl.classList.toggle('expanded-text');
                toggle.textContent = valueEl.classList.contains('expanded-text') ? 'Show less' : 'Show more';
            });
        }

        return fieldEl;
    };

    // =========================================================================
    // Utilities
    // =========================================================================

    PDCRenderer._escapeHtml = function(str) {
        if (!str) return '';
        var div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    };

    // =========================================================================
    // Export
    // =========================================================================

    global.PDCRenderer = PDCRenderer;

})(typeof window !== 'undefined' ? window : this);