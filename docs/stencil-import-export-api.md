# Fluxx Stencil Import/Export over HTTP

Findings from probing TRN (`https://macfound-trn.fluxx.io`) on 2026-09-04.
Goal: drive stencil deployment from a script instead of hand-pasting per
[deployment.md](deployment.md).

## Verdict

The admin Export/Import buttons are backed by ordinary HTTP endpoints that a
script can call. They are **not** part of the documented REST API (`/api/rest/v2/...`)
— they are session-authenticated app routes. That distinction drives the auth
design below.

## Export — proven working

    GET /stencil_export/{stencil_id}.json

- Returns `200`, `Content-Type: application/json`, plus a
  `Content-Disposition: attachment; filename="<model>-<stencil>.json"`.
- Body is a plain JSON bundle: `{"name": ..., "records": {"<Model>": [ ... ]}}`.
- Verified: stencil `26813` (Admin Tools) → 61,948 bytes.

### The id is a Stencil id, not a theme id

Confirmed by probe — only the stencil id resolves:

| URL | Result |
|---|---|
| `/stencil_export/26813.json` (stencil) | `200` |
| `/stencil_export/14369.json` (its theme) | `404` |
| `/stencil_export/2239.json` (theme) | `404` |
| `/stencil_export.json?model_theme_id=...` | `404` |
| `/stencil_export.json?model_type=...` | `404` |

There is **no** stencil index endpoint: `/stencils.json` and
`/machine_model_types.json` both return `500`. A single stencil does resolve:
`GET /stencils/{id}.json` → `{"stencil":{"id","model_type","model_theme_id","form_type","json",...}}`.

**Open item:** stencil-id discovery. Ids must currently be read off the admin UI
(the model-type card renders the Export link). For a script, either pin the ids in
a manifest, or find a listing route. This is the one unsolved piece.

## What the bundle contains

Record types in the Admin Tools export:

    MachineModelType, ModelAttribute, ModelAttributeValue, MachineState,
    ModelTheme, MachineWorkflow, MachineEvent, ModelDocument, Role, Stencil

This covers the two things that make manual deploys slow:

- **Workflow buttons** — `MachineEvent` carries `button_name`, `guard`,
  `on_transition`, `unsafe_guard`, `unsafe_on_transition`, `draft_guard`,
  `has_custom_ruby_code`, `to_state`. Button labels *and* their Ruby.
- **Field configuration** — `ModelAttribute` (`attribute_type`, `multi_allowed`,
  `include_in_export`, ...) and `ModelAttributeValue` (dropdown choices).
- **Layout** — `Stencil.json` holds the serialized form/list/show elements;
  Liquid blocks live inside it.
- **Lifecycle hooks** — `ModelTheme` carries `before_new_block`,
  `after_create_block`, and their `unsafe_`/`draft_` variants.

### Caveat: not yet proven that Ruby travels

The Admin Tools stencil has `has_custom_ruby_code: false` and every code field
`null`. So we have confirmed the bundle *has slots* for Ruby, not that a populated
export round-trips it. **Verify against a Ruby-bearing stencil before relying on
this.**

### Named methods are probably NOT covered

The record list has no `ModelMethod`-style type. The bulk of `pdc-map/*.rb` is
named methods, which likely still need the current per-method deploy. The bundle
looks like a win for workflow + fields + layout + hooks, not a total replacement.

## Import — contract identified, not yet exercised

    POST /stencil_import?authenticity_token=<token>

Two-step, because the CSRF token is minted into the modal HTML:

1. `GET /stencil_import` → returns a small HTML fragment containing
   `<a class="upload-file" data-extensions="json,txt"
    href="/stencil_import?authenticity_token=...">`.
2. Scrape `authenticity_token` from that href, then POST the bundle to it.

### Body is raw, not multipart

The uploader is plupload configured `multipart: !1` (i.e. `multipart: false`) in
`assets/main-*.js`. Fluxx streams the **raw file bytes** as the request body
rather than building a multipart form. Simpler to script than multipart —
send the JSON as the body.

Accepted extensions: `json,txt`. The error string ("There was an error parsing
the JSON file") confirms server-side JSON parsing.

## Auth for a real script

Both routes are session-based (cookie + Rails CSRF), not OAuth bearer. Options,
roughly in order of preference:

1. Check whether Fluxx exposes these under the documented REST API for token
   auth — not found so far, worth asking Fluxx support.
2. Programmatic login to `/user_sessions` to obtain a session cookie, then reuse
   it for both calls. Works, but stores admin credentials in the deploy runner.
3. Keep a human in the loop for the import step only.

Unresolved — decide before building.

## Risk note

Import applies a whole bundle. Whether it merges or overwrites records outside
the PDC scope is **not yet established**, and that matters more than the transport
details. Do not run an import against PROD until tested on TRN.

**DEV is off limits** — MacArthur does a full DEV→PROD copy with no ability to
cherry-pick, so config written to DEV escapes to PROD.

## TRN reference ids

| Model theme | id | Model type |
|---|---|---|
| PDC Consent | 24174 | `MacModelTypeDynPdcConsent` |
| PDC Integration Map | 22878 | `MacModelTypeDynPdcApplicationForm1` |
| PDC Mapped Field | 22879 | `MacModelTypeDynPdcMappedField1` |

Two notes:

- TRN spells these `...DynPdc...`; [deployment.md](deployment.md) references
  `MacModelTypeDynPDCConsent`. Confirm casing per environment.
- All three themes return **no form elements** in TRN
  (`/form_elements?admin=true&model_theme_id=24174` → empty). TRN's PDC config is
  effectively empty, so TRN is a clean import *target*, not an export source.
  A populated source export has to come from wherever PDC is actually built.
