/**
 * PDC Panel Controller
 * Handles floating panel behavior: drag, minimize, close, search filtering.
 * No data knowledge - just UI behavior.
 */
(function(global) {
    'use strict';

    var PDCPanel = {
        panel: null,
        header: null,
        searchInput: null,
        itemContainer: null,
        isDragging: false,
        dragState: {}
    };

    // =========================================================================
    // Initialization
    // =========================================================================

    /**
     * Initialize the panel controller
     * @param {Object} elements - Object containing DOM element references
     * @param {HTMLElement} elements.panel - The floating panel element
     * @param {HTMLElement} elements.header - The draggable header element
     * @param {HTMLElement} [elements.searchInput] - Optional search input
     * @param {HTMLElement} [elements.itemContainer] - Container for searchable items
     * @param {HTMLElement} [elements.minimizeBtn] - Minimize button
     * @param {HTMLElement} [elements.closeBtn] - Close button
     */
    PDCPanel.init = function(elements) {
        if (!elements.panel || !elements.header) {
            console.error('PDCPanel: panel and header elements are required');
            return;
        }

        this.panel = elements.panel;
        this.header = elements.header;
        this.searchInput = elements.searchInput || null;
        this.itemContainer = elements.itemContainer || null;

        this._setupDrag();

        if (elements.minimizeBtn) {
            this._setupMinimize(elements.minimizeBtn);
        }

        if (elements.closeBtn) {
            this._setupClose(elements.closeBtn);
        }

        if (this.searchInput && this.itemContainer) {
            this._setupSearch();
        }

        console.log('PDCPanel: Initialized');
    };

    // =========================================================================
    // Drag Functionality
    // =========================================================================

    PDCPanel._setupDrag = function() {
        var self = this;

        this.header.addEventListener('mousedown', function(e) {
            // Don't start drag if clicking a button
            if (e.target.tagName === 'BUTTON') return;

            self.isDragging = true;
            self.dragState = {
                startX: e.clientX,
                startY: e.clientY,
                startLeft: self.panel.getBoundingClientRect().left,
                startTop: self.panel.getBoundingClientRect().top
            };

            document.body.style.userSelect = 'none';
            self.panel.style.transition = 'none';
        });

        document.addEventListener('mousemove', function(e) {
            if (!self.isDragging) return;

            var dx = e.clientX - self.dragState.startX;
            var dy = e.clientY - self.dragState.startY;

            self.panel.style.left = (self.dragState.startLeft + dx) + 'px';
            self.panel.style.top = (self.dragState.startTop + dy) + 'px';
            self.panel.style.right = 'auto';
        });

        document.addEventListener('mouseup', function() {
            if (self.isDragging) {
                self.isDragging = false;
                document.body.style.userSelect = '';
                self.panel.style.transition = '';
            }
        });
    };

    // =========================================================================
    // Minimize / Close
    // =========================================================================

    PDCPanel._setupMinimize = function(btn) {
        var self = this;
        btn.addEventListener('click', function() {
            self.toggleMinimize();
        });
    };

    PDCPanel._setupClose = function(btn) {
        var self = this;
        btn.addEventListener('click', function() {
            self.hide();
        });
    };

    PDCPanel.toggleMinimize = function() {
        if (this.panel) {
            this.panel.classList.toggle('minimized');
        }
    };

    PDCPanel.minimize = function() {
        if (this.panel) {
            this.panel.classList.add('minimized');
        }
    };

    PDCPanel.restore = function() {
        if (this.panel) {
            this.panel.classList.remove('minimized');
        }
    };

    PDCPanel.isMinimized = function() {
        return this.panel && this.panel.classList.contains('minimized');
    };

    // =========================================================================
    // Show / Hide
    // =========================================================================

    PDCPanel.show = function() {
        if (this.panel) {
            // Move to body if not already there (vendor DOM rewriting workaround)
            if (this.panel.parentElement !== document.body) {
                document.body.appendChild(this.panel);
            }
            this.panel.classList.remove('hidden');
        }
    };

    PDCPanel.hide = function() {
        if (this.panel) {
            this.panel.classList.add('hidden');
        }
    };

    PDCPanel.toggle = function() {
        if (this.panel) {
            if (this.panel.classList.contains('hidden')) {
                this.show();
            } else {
                this.hide();
            }
        }
    };

    PDCPanel.isVisible = function() {
        return this.panel && !this.panel.classList.contains('hidden');
    };

    // =========================================================================
    // Search / Filter
    // =========================================================================

    PDCPanel._setupSearch = function() {
        var self = this;

        this.searchInput.addEventListener('input', function(e) {
            self.filterItems(e.target.value);
        });
    };

    PDCPanel.filterItems = function(query) {
        if (!this.itemContainer) return;

        var normalizedQuery = (query || '').toLowerCase().trim();
        var items = this.itemContainer.querySelectorAll('.pdc-entry-item');

        items.forEach(function(item) {
            var searchText = item.dataset.searchText || '';
            if (!normalizedQuery || searchText.indexOf(normalizedQuery) !== -1) {
                item.classList.remove('hidden');
            } else {
                item.classList.add('hidden');
            }
        });
    };

    PDCPanel.clearSearch = function() {
        if (this.searchInput) {
            this.searchInput.value = '';
            this.filterItems('');
        }
    };

    // =========================================================================
    // Position Reset
    // =========================================================================

    PDCPanel.resetPosition = function() {
        if (this.panel) {
            this.panel.style.top = '50px';
            this.panel.style.right = '50px';
            this.panel.style.left = 'auto';
        }
    };

    // =========================================================================
    // Export
    // =========================================================================

    global.PDCPanel = PDCPanel;

})(typeof window !== 'undefined' ? window : this);