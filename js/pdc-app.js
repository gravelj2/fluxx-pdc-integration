/**
 * PDC Application
 * Orchestrates OAuth, Panel, and Renderer modules.
 * Expects window.PDC_CONFIG to be defined.
 */
(function(global) {
    'use strict';

    var PDCApp = {
        oauth: null,
        initialized: false,
        elements: {},
        config: {}
    };

    // =========================================================================
    // Default Configuration
    // =========================================================================

    var DEFAULT_SELECTORS = {
        // Auth UI
        loginContainer: '[data-pdc="login-container"]',
        authenticatedContainer: '[data-pdc="authenticated-container"]',
        loginBtn: '[data-pdc="login-btn"]',
        logoutBtn: '[data-pdc="logout-btn"]',
        viewerBtn: '[data-pdc="viewer-btn"]',
        userName: '[data-pdc="user-name"]',
        userEmail: '[data-pdc="user-email"]',
        // Panel
        panel: '[data-pdc="panel"]',
        panelHeader: '[data-pdc="panel-header"]',
        panelBody: '[data-pdc="panel-body"]',
        searchInput: '[data-pdc="search-input"]',
        minimizeBtn: '[data-pdc="minimize-btn"]',
        closeBtn: '[data-pdc="close-btn"]'
    };

    // =========================================================================
    // Initialization
    // =========================================================================

    /**
     * Initialize the PDC application
     * @param {Object} [options] - Optional configuration overrides
     * @param {Object} [options.selectors] - Override default selectors
     * @param {string} [options.apiBaseUrl] - Override API base URL
     */
    PDCApp.init = function(options) {
        if (this.initialized) {
            console.warn('PDCApp: Already initialized');
            return;
        }

        options = options || {};
        var baseConfig = global.PDC_CONFIG || {};

        // Merge configuration
        this.config = {
            apiBaseUrl: options.apiBaseUrl || baseConfig.apiBaseUrl || 'https://api.philanthropydatacommons.org',
            selectors: Object.assign({}, DEFAULT_SELECTORS, options.selectors || {})
        };

        // Check for required modules
        if (!global.PDCOAuthClient) {
            console.error('PDCApp: PDCOAuthClient not loaded');
            return;
        }
        if (!global.PDCRenderer) {
            console.error('PDCApp: PDCRenderer not loaded');
            return;
        }
        if (!global.PDCPanel) {
            console.error('PDCApp: PDCPanel not loaded');
            return;
        }

        // Initialize OAuth client
        this.oauth = new global.PDCOAuthClient(baseConfig);

        // Cache DOM elements
        this._cacheElements();

        // Initialize panel if elements exist
        this._initPanel();

        // Bind event handlers
        this._bindEvents();

        // Update UI based on auth state
        this._updateAuthUI();

        this.initialized = true;
        console.log('PDCApp: Initialized');
    };

    PDCApp._cacheElements = function() {
        var selectors = this.config.selectors;
        var elements = this.elements;

        Object.keys(selectors).forEach(function(key) {
            elements[key] = document.querySelector(selectors[key]);
        });
    };

    PDCApp._initPanel = function() {
        var el = this.elements;

        if (el.panel && el.panelHeader) {
            global.PDCPanel.init({
                panel: el.panel,
                header: el.panelHeader,
                searchInput: el.searchInput,
                itemContainer: el.panelBody,
                minimizeBtn: el.minimizeBtn,
                closeBtn: el.closeBtn
            });
        }
    };

    // =========================================================================
    // Event Binding
    // =========================================================================

    PDCApp._bindEvents = function() {
        var self = this;
        var el = this.elements;

        // Login button
        if (el.loginBtn) {
            el.loginBtn.addEventListener('click', function() {
                self._handleLogin();
            });
        }

        // Logout button
        if (el.logoutBtn) {
            el.logoutBtn.addEventListener('click', function() {
                self._handleLogout();
            });
        }

        // Viewer button
        if (el.viewerBtn) {
            el.viewerBtn.addEventListener('click', function() {
                self._handleViewerLaunch();
            });
        }
    };

    // =========================================================================
    // Auth Handlers
    // =========================================================================

    PDCApp._handleLogin = function() {
        var self = this;
        var btn = this.elements.loginBtn;

        if (btn) {
            btn.disabled = true;
            btn.textContent = 'Connecting...';
        }

        this.oauth.loginWithPopup()
            .then(function() {
                console.log('PDCApp: Login successful');
                self._updateAuthUI();
            })
            .catch(function(error) {
                console.error('PDCApp: Login failed', error);
                alert('Authentication failed: ' + error.message);
            })
            .finally(function() {
                if (btn) {
                    btn.disabled = false;
                    btn.textContent = 'Connect to PDC';
                }
            });
    };

    PDCApp._handleLogout = function() {
        this.oauth.logout();
        this._updateAuthUI();
        
        // Hide panel if visible
        if (global.PDCPanel.isVisible()) {
            global.PDCPanel.hide();
        }
        
        console.log('PDCApp: Logged out');
    };

    PDCApp._handleViewerLaunch = function() {
        var self = this;
        var btn = this.elements.viewerBtn;

        if (btn) {
            btn.disabled = true;
            btn.textContent = 'Retrieving Proposals...';
        }

        this.loadProposals()
            .catch(function(error) {
                console.error('PDCApp: Failed to load proposals', error);
                alert('Failed to load proposals: ' + error.message);
            })
            .finally(function() {
                if (btn) {
                    btn.disabled = false;
                    btn.textContent = 'Launch PDC Proposals Viewer';
                }
            });
    };

    // =========================================================================
    // UI Updates
    // =========================================================================

    PDCApp._updateAuthUI = function() {
        var isAuth = this.oauth.isAuthenticated();
        var el = this.elements;

        // Toggle containers
        if (el.loginContainer) {
            el.loginContainer.classList.toggle('hidden', isAuth);
        }
        if (el.authenticatedContainer) {
            el.authenticatedContainer.classList.toggle('hidden', !isAuth);
        }

        // Update user info
        if (isAuth) {
            var userInfo = this.oauth.getUserInfo();
            
            if (el.userName && userInfo) {
                el.userName.textContent = userInfo.name || userInfo.preferred_username || 'User';
            }
            
            if (el.userEmail) {
                if (userInfo && userInfo.email) {
                    el.userEmail.textContent = userInfo.email;
                    el.userEmail.style.display = 'block';
                } else {
                    el.userEmail.style.display = 'none';
                }
            }
        }
    };

    // =========================================================================
    // Data Loading
    // =========================================================================

    /**
     * Load proposals from the PDC API and display in panel
     * @returns {Promise}
     */
    PDCApp.loadProposals = function() {
        var self = this;
        var url = this.config.apiBaseUrl + '/proposals';

        return this.oauth.authenticatedFetch(url, {
            method: 'GET',
            headers: { 'Content-Type': 'application/json' }
        })
        .then(function(response) {
            if (!response.ok) {
                throw new Error('Failed to load proposals: ' + response.status);
            }
            return response.json();
        })
        .then(function(data) {
            console.log('PDCApp: Loaded', (data.entries || []).length, 'proposals');
            
            // Show panel
            global.PDCPanel.show();
            
            // Render data
            if (self.elements.panelBody) {
                global.PDCRenderer.renderEntries(data, self.elements.panelBody);
            }
            
            return data;
        });
    };

    // =========================================================================
    // Public Methods
    // =========================================================================

    /**
     * Check if user is authenticated
     * @returns {boolean}
     */
    PDCApp.isAuthenticated = function() {
        return this.oauth && this.oauth.isAuthenticated();
    };

    /**
     * Get the OAuth client instance
     * @returns {PDCOAuthClient}
     */
    PDCApp.getOAuthClient = function() {
        return this.oauth;
    };

    /**
     * Manually refresh the auth UI
     */
    PDCApp.refreshAuthUI = function() {
        this._updateAuthUI();
    };

    global.PDCApp = PDCApp;

})(typeof window !== 'undefined' ? window : this);