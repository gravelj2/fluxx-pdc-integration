# PDC Integration for Fluxx

OAuth2 PKCE integration with the Philanthropy Data Commons API, designed for Fluxx grant management forms.

## Quick Start

Add this to your Fluxx form HTML panel:

```html
<!-- Config (Liquid-templated) -->
<script>
var PDC_CONFIG = {
    clientId: '{{ organization.pdc_client_id }}',
    authEndpoint: 'https://auth.philanthropydatacommons.org/authorize',
    tokenEndpoint: 'https://auth.philanthropydatacommons.org/oauth/token',
    redirectUri: '{{ request.origin }}',
    apiBaseUrl: 'https://api.philanthropydatacommons.org',
    storagePrefix: 'pdc_{{ organization.id }}_'
};
</script>

<!-- Load modules -->
<link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/YOUR_ORG/pdc-integration@main/css/pdc-panel.css">
<script src="https://cdn.jsdelivr.net/gh/YOUR_ORG/pdc-integration@main/js/pdc-oauth-client.js"></script>
<script src="https://cdn.jsdelivr.net/gh/YOUR_ORG/pdc-integration@main/js/pdc-proposal-renderer.js"></script>
<script src="https://cdn.jsdelivr.net/gh/YOUR_ORG/pdc-integration@main/js/pdc-panel-controller.js"></script>
<script src="https://cdn.jsdelivr.net/gh/YOUR_ORG/pdc-integration@main/js/pdc-app.js"></script>

<!-- UI elements (see fluxx-form-template.html for full example) -->
```

## Architecture

| File | Purpose |
|------|---------|
| `pdc-oauth-client.js` | OAuth2 PKCE authentication (no UI dependencies) |
| `pdc-proposal-renderer.js` | Data rendering functions |
| `pdc-panel-controller.js` | Floating panel behavior (drag, minimize, search) |
| `pdc-app.js` | Application orchestration |
| `pdc-panel.css` | All styles (prefixed with `pdc-`) |

## Configuration

### Required PDC_CONFIG Properties

| Property | Description | Example |
|----------|-------------|---------|
| `clientId` | OAuth client ID from PDC | `"my-fluxx-client"` |
| `authEndpoint` | Authorization URL | `"https://auth.pdc.org/authorize"` |
| `tokenEndpoint` | Token exchange URL | `"https://auth.pdc.org/oauth/token"` |
| `redirectUri` | OAuth callback URL | `"https://fluxx.myorg.com"` |
| `apiBaseUrl` | PDC API base URL | `"https://api.pdc.org"` |

### Optional Properties

| Property | Default | Description |
|----------|---------|-------------|
| `storagePrefix` | `"pdc_"` | LocalStorage key prefix (namespace per org) |
| `scope` | `"openid profile roles"` | OAuth scopes to request |

## Element Selectors

The app looks for these `data-pdc` attributes:

```html
<!-- Auth UI -->
<div data-pdc="login-container">...</div>
<div data-pdc="authenticated-container">...</div>
<button data-pdc="login-btn">...</button>
<button data-pdc="logout-btn">...</button>
<button data-pdc="viewer-btn">...</button>
<span data-pdc="user-name"></span>
<span data-pdc="user-email"></span>

<!-- Panel -->
<div data-pdc="panel">...</div>
<div data-pdc="panel-header">...</div>
<div data-pdc="panel-body">...</div>
<input data-pdc="search-input">
<button data-pdc="minimize-btn">...</button>
<button data-pdc="close-btn">...</button>
```

## API Reference

### PDCOAuthClient

```javascript
var oauth = new PDCOAuthClient(config);

// Auth flow
oauth.loginWithPopup()           // Returns Promise<tokens>
oauth.logout()                   // Clears stored tokens
oauth.isAuthenticated()          // Returns boolean

// Token management
oauth.getValidAccessToken()      // Returns Promise<string> (auto-refreshes)
oauth.authenticatedFetch(url, options)  // Fetch with auth header

// User info
oauth.getUserInfo()              // Returns decoded ID token payload
```

### PDCRenderer

```javascript
PDCRenderer.renderEntries(data, containerEl);
PDCRenderer.renderVersions(containerEl, versions);
PDCRenderer.renderFieldValues(containerEl, fieldValues);
```

### PDCPanel

```javascript
PDCPanel.init({ panel, header, searchInput, itemContainer, minimizeBtn, closeBtn });

PDCPanel.show();
PDCPanel.hide();
PDCPanel.toggle();
PDCPanel.toggleMinimize();
PDCPanel.filterItems(query);
PDCPanel.resetPosition();
```

### PDCApp

```javascript
PDCApp.init(options);           // Initialize everything
PDCApp.loadProposals();         // Fetch and display proposals
PDCApp.isAuthenticated();       // Check auth status
PDCApp.getOAuthClient();        // Get OAuth client instance
```

## Fluxx Environment Notes

This code is designed for Fluxx's vendor-controlled environment:

- Uses `var` instead of `const`/`let` for cross-block compatibility
- All functions attached to `window` for global access
- CSS classes prefixed with `pdc-` to avoid conflicts
- Uses `data-pdc` attributes instead of IDs (Fluxx may rewrite IDs)
- Panels are moved to `document.body` to escape container clipping

## Versioning

Use jsDelivr's version pinning for stability:

```html
<!-- Pin to specific release -->
<script src="https://cdn.jsdelivr.net/gh/YOUR_ORG/pdc-integration@v1.0.0/js/pdc-app.js"></script>

<!-- Or pin to branch -->
<script src="https://cdn.jsdelivr.net/gh/YOUR_ORG/pdc-integration@main/js/pdc-app.js"></script>
```

## License

MIT