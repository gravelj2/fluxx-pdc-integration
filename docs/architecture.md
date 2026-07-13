# Architecture & method dependency map

All Ruby files are Fluxx dynamic model methods or lifecycle hooks. A method's
file name is its Fluxx method name; cross-method calls use
`model.dyn_invoke_for(:"Method Name")`, so these names are load-bearing.

## Fluxx models involved

- `GrantRequest` — core Fluxx model
- `MacModelTypeDynPdcApplicationForm1` — "PDC Integration Map" (admin-configured)
- `MacModelTypeDynPdcMappedField1` — "PDC Mapped Field" (children of the map,
  reached via `reverse_pdc_mapping_field_MacModelTypeDynPdcMappedField1`)
- `MacModelTypeDynPDCConsent` — "PDC Consent" (one per grant, linked via
  `grant_or_request_id`)

> Note: capitalization of the dynamic model names is inconsistent in places
> (`Pdc` vs `PDC`, e.g. `MacModelTypeDynPDCMappedField1` inside
> `Set Fluxx Field Model Attribute Choices.rb` and
> `MacModelTypeDynPDCApplicationForm1` in `PDC_Get_PDC_Field_Mapping.rb`).
> These strings must match whatever the live Fluxx instance uses.

## Submission pipeline call graph

```
GrantRequest hooks
  AfterEnter - Granted ──► PDC Safe Consent Form Lookup
                       └─► Send Proposal to PDC        (deployed name of
                                                        "PDC Send Proposal to PDC.rb")
  PDC After Save - Create Consent If Empty
                       ──► PDC Safe Consent Form Lookup
                       └─► PDC Create Consent Form ──► PDC Get Last Consent Response
                                                   ├─► CurrentConsentLanguage   [consent model]
                                                   └─► CurrentConsentVersion    [consent model]

GrantRequest methods
  PDC Send Proposal to PDC ──► PDC Safe Consent Form Lookup
                           ├─► PDC Get Integration Mapping
                           ├─► PDC Get Proposal by ID from PDC
                           ├─► Get PDC Base URL            [on the map record]
                           ├─► Get Auth Token from PDC     [on the map record]
                           └─► reads MacModelTypeDynPdcMappedField1 children
  PDC_Get_Data_Preview_For_Proposal ──► PDC Get Integration Mapping
  PDC_Get_PDC_Field_Mapping ──► Get Field Mapping JSON for PDC Data Explorer
                                 [on the first map record — see TODO in file]

PDC Consent model
  Check If Consent Granted (on consent_type change) ──► Stamp Consent
  Stamp Consent ──► PDC_Get_Data_Preview_For_Proposal   [on the grant]
  Data Shared.liquid ──► PDC_Get_Data_Preview_For_Proposal

PDC Integration Map model — foundations used by nearly everything:
  Get PDC Base URL          (env detection via ClientConfiguration id 47)
  Get Auth Token from PDC   (client-credentials token, cached on the record)
    ├─► Get PDC Test Client Secret / Get PDC Prod Client Secret
    └─► (client IDs currently inline / in Get PDC * Client ID methods)
  Setup/sync methods:
    Set Opportunity Dropdown Values ──► Get Opportunities from PDC
    Set Application Dropdown Values ──► Get Applications from PDC
    Set PDC Field Model Attribute Choices        (GET /baseFields)
    Set Fluxx Field Model Attribute Choices      (introspects GrantRequest/Organization)
    Update Field Mapping from Selected Application ──► Get Application Form by Id from PDC
    Set Sort Order Of Mapped Fields ──► SortMappedFieldsbyFieldPosition
  Actions:
    Create Application In PDC   (POST /applicationForms)
    Create Proposals in PDC     (POST /proposals, via Relationship to GrantRequest)
    Get Funder from PDC         (GET /funders/{short_code})
    Get Grant Requests Related  (Base64 JSON of linked grants)
  UI:
    Show Mapped Fields.html ──► SortMappedFieldsbyFieldPosition
```

## Data Explorer load order & dependencies

```
1. portal-style.html      CSS for blocks 4 & 5
2. fluxxCardAPI.html      exposes window.fluxxAPI / fluxxFieldUtils / DropTargetManager
3. oauth.html             exposes window.OAuthClient (PKCE popup flow)
4. pdc-stencil-container  markup + Liquid; embeds Base64 mapping from
                          model.PDC_Get_PDC_Field_Mapping; sets window._pdcStructureReady
5. floating-panel.html    behavior; requires 2, 3, 4; initializes via img-onload
oauth-callback.html       popup redirect target; postMessages code/state to opener
```

Elements are resolved by `data-original-id` (not `id`) because Fluxx injects a
fresh copy of the stencil per card; block 5 scopes lookups to the active card.

## Known issues carried over from the offline copy

These were deliberately **not** fixed during the repo migration (contents were
kept byte-identical to what is deployed/tested):

- `pdc-integration-map/Get Funder from PDC.rb` — typo `model.fundefunder_short_code`;
  the method will raise when invoked.
- `grant-request/PDC_Get_PDC_Field_Mapping.rb` — uses `.first` map record;
  selection logic TODO is documented in the file header.
- `data-explorer/5. floating-panel.html` — proposals endpoint hardcoded to the
  **sandbox** API while `3. oauth.html` points at **production** auth.
- `pdc-integration-map/Get PDC Base URL.rb` — environment detection depends on
  `ClientConfiguration` record id 47 existing and on the dashboard title
  containing `[` in non-production.
- `pdc-consent/CurrentConsentLanguage.rb` — links to a preprod Fluxx URL
  (`macfound-dev.preprod.fluxxlabs.com/...`).
- `pdc-map` production credentials intentionally unconfigured:
  `Get Auth Token from PDC.rb` raises for prod; both client-secret methods
  return `"Not Configured"`.
