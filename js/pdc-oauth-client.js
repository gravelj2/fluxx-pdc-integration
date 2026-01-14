/**
 * PDC OAuth Client
 * Standalone OAuth2 PKCE client for PDC authentication.
 * 
 * Expects window.PDC_CONFIG to be defined with:
 *   - clientId
 *   - authEndpoint (authorization URL)
 *   - tokenEndpoint
 *   - redirectUri
 *   - storagePrefix (optional, defaults to 'pdc_')
 */
(function(global) {
    'use strict';

    var DEFAULT_CONFIG = {
        scope: 'openid profile roles',
        popupWidth: 500,
        popupHeight: 700,
        storagePrefix: 'pdc_'
    };

    /**
     * PDCOAuthClient Constructor
     * @param {Object} config - Override default configuration
     */
    var PDCOAuthClient = function(config) {
        var baseConfig = global.PDC_CONFIG || {};
        
        this.config = {
            clientId: config.clientId || baseConfig.clientId,
            authEndpoint: config.authEndpoint || baseConfig.authEndpoint,
            tokenEndpoint: config.tokenEndpoint || baseConfig.tokenEndpoint,
            redirectUri: config.redirectUri || baseConfig.redirectUri || global.location.origin,
            scope: config.scope || baseConfig.scope || DEFAULT_CONFIG.scope,
            popupWidth: config.popupWidth || DEFAULT_CONFIG.popupWidth,
            popupHeight: config.popupHeight || DEFAULT_CONFIG.popupHeight,
            storagePrefix: config.storagePrefix || baseConfig.storagePrefix || DEFAULT_CONFIG.storagePrefix
        };

        // Storage keys (namespaced)
        this.keys = {
            tokens: this.config.storagePrefix + 'oauth_tokens',
            state: this.config.storagePrefix + 'oauth_state',
            codeVerifier: this.config.storagePrefix + 'oauth_code_verifier'
        };

        this.popupWindow = null;
        this.popupCheckInterval = null;

        // Validate required config
        if (!this.config.clientId) {
            console.error('PDCOAuthClient: clientId is required');
        }
        if (!this.config.authEndpoint) {
            console.error('PDCOAuthClient: authEndpoint is required');
        }
        if (!this.config.tokenEndpoint) {
            console.error('PDCOAuthClient: tokenEndpoint is required');
        }
    };

    // =========================================================================
    // Crypto Utilities
    // =========================================================================

    PDCOAuthClient.prototype.generateRandomString = function(length) {
        var array = new Uint8Array(length);
        crypto.getRandomValues(array);
        return Array.from(array, byte => byte.toString(16).padStart(2, '0')).join('');
    };

    PDCOAuthClient.prototype.generatePKCE = function() {
        var self = this;
        var codeVerifier = this.generateRandomString(32);
        var encoder = new TextEncoder();
        var data = encoder.encode(codeVerifier);

        return crypto.subtle.digest('SHA-256', data).then(function(digest) {
            var bytes = new Uint8Array(digest);
            var binary = '';
            for (var i = 0; i < bytes.length; i++) {
                binary += String.fromCharCode(bytes[i]);
            }
            var codeChallenge = btoa(binary)
                .replace(/\+/g, '-')
                .replace(/\//g, '_')
                .replace(/=+$/, '');

            return {
                codeVerifier: codeVerifier,
                codeChallenge: codeChallenge
            };
        });
    };

    // =========================================================================
    // Token Management
    // =========================================================================

    PDCOAuthClient.prototype.saveTokens = function(tokens) {
        var tokenData = {
            accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token,
            expiresAt: Date.now() + (tokens.expires_in * 1000),
            idToken: tokens.id_token,
            tokenType: tokens.token_type || 'Bearer'
        };
        try {
            localStorage.setItem(this.keys.tokens, JSON.stringify(tokenData));
            console.log('PDCOAuthClient: Tokens saved');
        } catch (e) {
            console.error('PDCOAuthClient: Failed to save tokens', e);
        }
    };

    PDCOAuthClient.prototype.getTokens = function() {
        try {
            var data = localStorage.getItem(this.keys.tokens);
            return data ? JSON.parse(data) : null;
        } catch (e) {
            console.error('PDCOAuthClient: Failed to retrieve tokens', e);
            return null;
        }
    };

    PDCOAuthClient.prototype.clearTokens = function() {
        localStorage.removeItem(this.keys.tokens);
        sessionStorage.removeItem(this.keys.state);
        sessionStorage.removeItem(this.keys.codeVerifier);
    };

    PDCOAuthClient.prototype.isAuthenticated = function() {
        try {
            var tokenData = this.getTokens();
            if (!tokenData) {
                return false;
            }
            // Check expiration with 30-second buffer
            var bufferMs = 30 * 1000;
            return Date.now() < (tokenData.expiresAt - bufferMs);
        } catch (e) {
            console.error('PDCOAuthClient: Error checking auth status', e);
            return false;
        }
    };

    PDCOAuthClient.prototype.decodeJWT = function(token) {
        try {
            var base64Url = token.split('.')[1];
            var base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
            var jsonPayload = decodeURIComponent(
                atob(base64).split('').map(function(c) {
                    return '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2);
                }).join('')
            );
            return JSON.parse(jsonPayload);
        } catch (e) {
            console.error('PDCOAuthClient: Failed to decode JWT', e);
            return null;
        }
    };

    PDCOAuthClient.prototype.getUserInfo = function() {
        var tokens = this.getTokens();
        if (!tokens || !tokens.idToken) {
            return null;
        }
        return this.decodeJWT(tokens.idToken);
    };

    // =========================================================================
    // Token Refresh
    // =========================================================================

    PDCOAuthClient.prototype.refreshAccessToken = function() {
        var self = this;
        var tokenData = this.getTokens();

        if (!tokenData || !tokenData.refreshToken) {
            return Promise.reject(new Error('No refresh token available'));
        }

        var body = new URLSearchParams({
            grant_type: 'refresh_token',
            refresh_token: tokenData.refreshToken,
            client_id: this.config.clientId
        });

        return fetch(this.config.tokenEndpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body.toString()
        }).then(function(response) {
            if (!response.ok) {
                self.clearTokens();
                throw new Error('Session expired. Please log in again.');
            }
            return response.json();
        }).then(function(tokens) {
            self.saveTokens(tokens);
            return tokens;
        });
    };

    PDCOAuthClient.prototype.getValidAccessToken = function() {
        var self = this;
        var tokenData = this.getTokens();

        if (!tokenData) {
            return Promise.reject(new Error('Not authenticated'));
        }

        // Check if token needs refresh (30-second buffer)
        var bufferMs = 30 * 1000;
        if (Date.now() >= tokenData.expiresAt - bufferMs) {
            console.log('PDCOAuthClient: Token expiring, refreshing...');
            return this.refreshAccessToken().then(function() {
                return self.getTokens().accessToken;
            });
        }

        return Promise.resolve(tokenData.accessToken);
    };

    // =========================================================================
    // Popup Authentication Flow
    // =========================================================================

    PDCOAuthClient.prototype.openPopup = function(url) {
        var left = window.screenX + (window.outerWidth - this.config.popupWidth) / 2;
        var top = window.screenY + (window.outerHeight - this.config.popupHeight) / 2;

        var features = 'width=' + this.config.popupWidth +
            ',height=' + this.config.popupHeight +
            ',left=' + left +
            ',top=' + top +
            ',toolbar=no,menubar=no,location=no,status=no';

        var popup = window.open(url, 'pdc_oauth_popup', features);

        if (!popup) {
            throw new Error('Failed to open popup. Please allow popups for this site.');
        }

        return popup;
    };

    PDCOAuthClient.prototype.loginWithPopup = function() {
        var self = this;

        return new Promise(function(resolve, reject) {
            self.generatePKCE().then(function(pkce) {
                var state = self.generateRandomString(16);

                // Store for validation
                sessionStorage.setItem(self.keys.state, state);
                sessionStorage.setItem(self.keys.codeVerifier, pkce.codeVerifier);

                var params = new URLSearchParams({
                    response_type: 'code',
                    client_id: self.config.clientId,
                    redirect_uri: self.config.redirectUri,
                    scope: self.config.scope,
                    state: state,
                    code_challenge: pkce.codeChallenge,
                    code_challenge_method: 'S256'
                });

                var authUrl = self.config.authEndpoint + '?' + params.toString();

                try {
                    self.popupWindow = self.openPopup(authUrl);
                } catch (e) {
                    self.cleanup();
                    reject(e);
                    return;
                }

                // Listen for callback message from popup
                var messageHandler = function(event) {
                    if (event.origin !== window.location.origin) {
                        return;
                    }
                    if (!event.data || event.data.type !== 'oauth_callback') {
                        return;
                    }

                    // Clean up listener and interval
                    window.removeEventListener('message', messageHandler);
                    if (self.popupCheckInterval) {
                        clearInterval(self.popupCheckInterval);
                        self.popupCheckInterval = null;
                    }

                    if (self.popupWindow) {
                        self.popupWindow.close();
                    }

                    if (event.data.error) {
                        self.cleanup();
                        reject(new Error('OAuth error: ' + event.data.error));
                        return;
                    }

                    // Handle the callback data
                    self.handleCallback(event.data)
                        .then(resolve)
                        .catch(reject);
                };

                window.addEventListener('message', messageHandler);

                // Check if popup was closed manually
                self.popupCheckInterval = setInterval(function() {
                    if (self.popupWindow && self.popupWindow.closed) {
                        clearInterval(self.popupCheckInterval);
                        self.popupCheckInterval = null;
                        window.removeEventListener('message', messageHandler);
                        self.cleanup();
                        reject(new Error('Authentication cancelled by user'));
                    }
                }, 500);

            }).catch(function(e) {
                self.cleanup();
                reject(e);
            });
        });
    };

    PDCOAuthClient.prototype.handleCallback = function(data) {
        var self = this;

        if (data.error) {
            return Promise.reject(new Error('OAuth error: ' + data.error + ' - ' + (data.error_description || '')));
        }

        if (!data.code) {
            return Promise.reject(new Error('No authorization code received'));
        }

        // Validate state
        var storedState = sessionStorage.getItem(this.keys.state);
        if (!data.state || data.state !== storedState) {
            return Promise.reject(new Error('State mismatch - possible CSRF attack'));
        }

        var codeVerifier = sessionStorage.getItem(this.keys.codeVerifier);
        if (!codeVerifier) {
            return Promise.reject(new Error('Code verifier not found'));
        }

        // Exchange code for tokens
        return this.exchangeCodeForTokens(data.code, codeVerifier)
            .then(function(tokens) {
                // Clean up session storage
                sessionStorage.removeItem(self.keys.state);
                sessionStorage.removeItem(self.keys.codeVerifier);
                
                self.saveTokens(tokens);
                return tokens;
            });
    };

    PDCOAuthClient.prototype.exchangeCodeForTokens = function(code, codeVerifier) {
        var body = new URLSearchParams({
            grant_type: 'authorization_code',
            code: code,
            redirect_uri: this.config.redirectUri,
            client_id: this.config.clientId,
            code_verifier: codeVerifier
        });

        return fetch(this.config.tokenEndpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body.toString()
        }).then(function(response) {
            if (!response.ok) {
                return response.json().catch(function() {
                    return {};
                }).then(function(data) {
                    throw new Error('Token exchange failed: ' + (data.error || response.status));
                });
            }
            return response.json();
        });
    };

    PDCOAuthClient.prototype.cleanup = function() {
        sessionStorage.removeItem(this.keys.state);
        sessionStorage.removeItem(this.keys.codeVerifier);
        if (this.popupCheckInterval) {
            clearInterval(this.popupCheckInterval);
            this.popupCheckInterval = null;
        }
    };

    // =========================================================================
    // Authenticated Requests
    // =========================================================================

    PDCOAuthClient.prototype.authenticatedFetch = function(url, options) {
        var self = this;
        options = options || {};

        var makeRequest = function(token, tokenType) {
            var headers = Object.assign({}, options.headers || {}, {
                'Authorization': tokenType + ' ' + token
            });
            return fetch(url, Object.assign({}, options, { headers: headers }));
        };

        return this.getValidAccessToken().then(function(token) {
            var tokenData = self.getTokens();
            return makeRequest(token, tokenData.tokenType || 'Bearer');
        }).then(function(response) {
            // If 401, try refresh and retry once
            if (response.status === 401) {
                console.log('PDCOAuthClient: Got 401, attempting refresh...');
                return self.refreshAccessToken().then(function() {
                    var tokenData = self.getTokens();
                    return makeRequest(tokenData.accessToken, tokenData.tokenType);
                });
            }
            return response;
        });
    };

    // =========================================================================
    // Logout
    // =========================================================================

    PDCOAuthClient.prototype.logout = function() {
        this.clearTokens();
        console.log('PDCOAuthClient: Logged out');
    };

    // =========================================================================
    // Export
    // =========================================================================

    global.PDCOAuthClient = PDCOAuthClient;

})(typeof window !== 'undefined' ? window : this);