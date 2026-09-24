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
| `data-explorer/4r. pdc-stencil-readonly.html` | Read-only journey block — see "Read-only journey variant" below |
| `data-explorer/oauth-callback.html` | Page served at the OAuth redirect URI registered with PDC |

## Order matters

1. **Foundations first** on the Integration Map model: `Get PDC Base URL`,
   `Get PDC Client ID`, `Get PDC Client Secret`,
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

## Read-only journey variant

`data-explorer/4r. pdc-stencil-readonly.html` is a view-only twin of block 4. It
renders the same 4-step journey and keeps the live "Review and Manage Consent"
modal link, but drops every JS-driven element (account-gate dropdown,
login/logout controls, launch button, explorer panel, structure-ready signal).
Use it where the login/launch flow is unwanted.

- **Block set:** `1. portal-style.html` (CSS, reused as-is) + `4r. pdc-stencil-readonly.html`,
  plus `0. information.html` if an intro is wanted.
- **Do NOT deploy** blocks `2`, `3`, `5`, or `oauth-callback.html` with it — this
  variant runs **no custom JavaScript**. The consent link is native Fluxx
  (`to-modal` + `data-on-success="refreshCaller,close"`).
- The consent step still needs the `MacModelTypeDynPDCConsent` model deployed so
  the `dyn_related` Liquid resolves and the modal link works.

## Consent step states

Step 2 of the journey (both block `4` and block `4r`) resolves two independent
booleans server-side in Liquid. Both are documented at length in the comment above
the tags; the deploy-relevant behavior:

| Consent record | `consent_type` | Step 2 renders |
|---|---|---|
| exists | affirmative (non-blank, no "decline") | complete branch: green check, "Done", CTA |
| exists | contains "decline" | action branch: "Action needed", CTA |
| exists | blank (not yet answered) | action branch: "Action needed", CTA |
| **none** | — | action branch: explanatory text, **no CTA** |

The last row is **by design, not a bug**: grants created before 2026-07-01 have no
consent record, because `PDC After Save - Create Consent If Empty` only creates
them at or after that date. Previously the CTA rendered anyway and linked to
`/machine_models//edit` (empty id). If the button is reported missing on an older
grant, that is this rule working.

"Granted" is tested as *non-blank and not containing "decline"* rather than as an
exact match on the dropdown label, mirroring `PDC Send Proposal to PDC`. Rewording
the affirmative choice therefore does not break the journey; renaming the **decline**
choice to drop that word would. Keep "decline" in the negative option's label.

## Environment & secrets checklist (before any production deploy)

- [ ] Enter real client secrets **only in Fluxx** (`Get PDC Client
      Secret` methods). The repo copies must keep returning `"Not Configured"`.
- [ ] Replace the temporary inline test client ID in
      `Get Auth Token from PDC.rb` with the secure-storage lookup (see comments
      in that file), and configure the production branch (currently `raise`).
- [x] `5. floating-panel.html`: proposals endpoint points at production
      (`api.philanthropydatacommons.org`), matching the OAuth environment in
      `3. oauth.html`. Both browser-side layers now target production so the
      prod-issued token is used against the prod API.
- [ ] `3. oauth.html`: confirm client ID (`pdc-fluxx-macfound`) and auth
      endpoints match the target environment; register `oauth-callback.html`'s
      URL as the redirect URI with PDC.
- [ ] `Get PDC Base URL.rb`: confirm `ClientConfiguration` id 47 exists in the
      target instance (environment detection depends on it).
- [ ] `CurrentConsentLanguage.rb`: the Q&A link now uses a relative URL
      (`/show/generic_templates/44210`), so it resolves against whatever
      Fluxx instance actually serves the page -- the old hardcoded-preprod-
      domain bug is fixed. What's NOT yet verified: whether `44210` itself
      -- a `Stencil`/`GenericTemplate` id -- is the same id in every
      environment. Confirmed true across MacArthur's current environments
      as of 2026-09-24, but ids like this are environment-specific in
      general (see the OAuth-callback Generic Template discovery in
      docs/roadmap.md, where the id genuinely does vary per instance). A new
      deployer must confirm this id still resolves to the intended Q&A page
      before going live, and re-derive it if it doesn't.

## Notes for the future deployment script

- Deployment unit is (Fluxx model, method name, file body). A machine-readable
  manifest mapping repo paths → model + method name + type (method / hook /
  liquid block / stencil block) is the natural next step.
- Secrets should be injected at deploy time from a secret store, overriding the
  placeholder bodies of the two client-secret methods.
