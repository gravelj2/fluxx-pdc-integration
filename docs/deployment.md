# Deployment

Until the deployment script exists, everything is deployed manually through the
Fluxx admin UI. Contents must be copied **verbatim** — file contents here are
the source of truth for what is pasted into Fluxx.

## What goes where

| Repo path | Fluxx destination |
|---|---|
| `pdc-map/grant-request/*.rb` | Methods/hooks on `GrantRequest`. Files named `AfterEnter…` / `PDC After Save…` are lifecycle hooks; the rest are named methods (deployed method name = file name without `.rb`) |
| `pdc-map/pdc-integration-map/*.rb` | Methods/hooks on `MacModelTypeDynPdcApplicationForm1` (`Before New.rb` is the before-new hook) |
| `pdc-map/pdc-integration-map/Show Mapped Fields.html` | Liquid block on the Integration Map form |
| `pdc-map/pdc-consent/*.rb`, `Data Shared.liquid` | Methods / Liquid on `MacModelTypeDynPDCConsent` |
| `data-explorer/0…5 *.html` | Blocks on the grantee-facing form/stencil, in numeric order |
| `data-explorer/oauth-callback.html` | Page served at the OAuth redirect URI registered with PDC |

## Order matters

1. **Foundations first** on the Integration Map model: `Get PDC Base URL`,
   `Get PDC Test/Prod Client ID`, `Get PDC Test/Prod Client Secret`,
   `Get Auth Token from PDC` — everything else calls these.
2. **Dropdown/setup methods** next (`Set Opportunity Dropdown Values`,
   `Set Application Dropdown Values`, `Set PDC Field Model Attribute Choices`,
   `Set Fluxx Field Model Attribute Choices`), then run them once to populate
   `ModelAttributeValue` choices.
3. **Mapping + action methods**, then the consent model methods, then the
   GrantRequest methods/hooks (they call into all of the above by name).
4. **Data Explorer blocks 0–5 in order** — block 5 refuses to initialize until
   block 4's structure-ready signal fires, and it requires the globals from
   blocks 2 and 3.

## Environment & secrets checklist (before any production deploy)

- [ ] Enter real client secrets **only in Fluxx** (`Get PDC Test/Prod Client
      Secret` methods). The repo copies must keep returning `"Not Configured"`.
- [ ] Replace the temporary inline test client ID in
      `Get Auth Token from PDC.rb` with the secure-storage lookup (see comments
      in that file), and configure the production branch (currently `raise`).
- [ ] `5. floating-panel.html`: switch the proposals endpoint from
      `api.sandbox.philanthropydatacommons.org` to the correct environment.
- [ ] `3. oauth.html`: confirm client ID (`pdc-fluxx-macfound`) and auth
      endpoints match the target environment; register `oauth-callback.html`'s
      URL as the redirect URI with PDC.
- [ ] `Get PDC Base URL.rb`: confirm `ClientConfiguration` id 47 exists in the
      target instance (environment detection depends on it).
- [ ] `CurrentConsentLanguage.rb`: point the Q&A link at the right Fluxx
      instance (currently preprod).

## Notes for the future deployment script

- Deployment unit is (Fluxx model, method name, file body). A machine-readable
  manifest mapping repo paths → model + method name + type (method / hook /
  liquid block / stencil block) is the natural next step.
- Secrets should be injected at deploy time from a secret store, overriding the
  placeholder bodies of the two client-secret methods.
