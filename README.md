# PDC Integration for Fluxx

OAuth2 PKCE integration with the Philanthropy Data Commons API, designed for Fluxx grant management system.

## Architecture

| File | Purpose |
|------|---------|
| `pdc-oauth-client.js` | OAuth2 PKCE authentication (no UI dependencies) |
| `pdc-proposal-renderer.js` | Data rendering functions |
| `pdc-panel-controller.js` | Floating panel behavior (drag, minimize, search) |
| `pdc-app.js` | Application orchestration |
| `pdc-panel.css` | All styles (prefixed with `pdc-`) |