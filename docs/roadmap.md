# Deploy tooling roadmap

`deploy/pdcdeploy` is being built incrementally. This document lists what's
deliberately **not** in the current version, so scope stays visible instead of
implicit. Nothing here is rejected -- it's sequenced later. See
[deployment.md](deployment.md) for what's already deployed by hand and
[architecture.md](architecture.md) for the method dependency map the tool
reads against.

## Build order

Within the read-only comparison work, the sequencing is:

1. Named Ruby methods (`ModelMethod.unsafe_dyn_method`) for `GrantRequest` and
   the three tracked PDC dynamic models.
2. Lifecycle hooks. Confirmed against TRN on 2026-09-24: PDC's `AfterEnter -
   Granted` hook (per [architecture.md](architecture.md)) is **not**
   `ModelTheme.unsafe_before_new_block`/`unsafe_after_create_block` --
   `GrantRequest`'s 5 themes all use those two fields only for unrelated
   form-default-value scaffolding (e.g. setting `project_summary`). The real
   hook is **`MachineState.unsafe_after_enter`** on the `granted` state (id
   10 on TRN), delimited by `###PDC_CODE###`/`###END_PDC_CODE###` comments,
   calling `PDC Safe Consent Form Lookup` then the proposal-send method via
   `dyn_invoke_for`. `MachineEvent` (button-triggered transitions) does not
   carry PDC logic; it's a red herring for this hook. Also confirmed: `Role`
   is a trivial list (13 records, `id`/`name`/`roleable_type`) worth
   including in the inventory now for visibility, per the "Setting roles on
   workflow objects" item below -- listing it is in scope even though acting
   on it (assigning a role to a workflow event) is not.
3. Stencil layout comparison (`Stencil.json` element trees) -- last, since it
   was the first thing prototyped and the rest of the surface is better
   understood now.

## Deferred capabilities

- **Customization-aware skipping.** No detection of "this stencil
  element / workflow item / Ruby method looks hand-customized in Fluxx,
  don't flag it as drift." V1 reports every difference flatly; deciding
  whether a difference is intentional customization vs. real drift stays a
  human judgment call for now.
- **Consent *logic* changes.** Consent-related fields/stencil layout are in
  scope for comparison (see [architecture.md](architecture.md)'s `PDC
  Consent` model) -- PDC Consent is actually expected to be one of the first
  candidates for stencil *injection* once that exists. What's deferred is
  building any special-cased handling of consent business logic itself.
- **Sending data at a workflow state other than Granted.** The tool doesn't
  need to reason about alternate trigger states yet.
- **Setting roles on workflow objects.** Deferred, but the underlying
  capability -- looking up the roles available in a given instance (`Role`
  REST model type) so a person can pick the right one when configuring a
  `MachineEvent` -- is planned. See "Write operations" below.
- **Stencil injection.** Writing new elements into a `Stencil.json` element
  tree -- specifically, injecting the 6 grant-form elements and the Generic
  Template element (see the open `GenericTemplate` question in
  [stencil-import-export-api.md](stencil-import-export-api.md)) -- is
  planned but not built. Comparison (read-only) ships first; injection
  (write) comes after.
- **Hardcoded Generic Template/stencil ids as a class of problem.** Two
  known instances so far: the oauth-callback stencil id (resolved via the
  UserProfile -> DashboardTemplate -> stencil discovery chain in
  `generic_templates.py`, since that id is genuinely instance-specific) and
  `CurrentConsentLanguage.rb`'s Q&A link, `/show/generic_templates/44210`
  (confirmed the same id across MacArthur's environments as of 2026-09-24,
  but not guaranteed to stay that way, and not portable to a different
  Fluxx org at all). A future version of the inventory/comparison tool
  should treat "a Ruby/HTML body contains a hardcoded `generic_templates/N`
  reference" as its own flagged category -- surfaced for a new deployer to
  confirm or re-derive, the same way `deployment.md`'s environment checklist
  already asks a human to confirm `ClientConfiguration` id 47.
- **Bootstrapping the first Integration Map.** Creating a brand-new `PDC
  Integration Map` record from scratch isn't handled -- the tool assumes at
  least one already exists to compare against.
- **Creating or removing the PDC dynamic model types themselves**
  (`MacModelTypeDynPdcApplicationForm1` and friends). Schema/model-type
  management is out of bounds; the tool only ever reads and, eventually,
  writes to existing configuration on existing model types.

## Theme selection (future)

`GrantRequest` has 5 themes on TRN (Grant Request, Grant Request - Fellows,
Impact Investments, X-Grants, General Operations), each with its own
`MachineWorkflow`. **Corrected understanding as of 2026-09-24** (an earlier
version of this note was wrong): themes do NOT each get their own copy of
the PDC `after_enter` hook. On TRN, 4 of the 5 themes' workflows (Grant
Request, Grant Request - Fellows, X-Grants, General Operations -- all but
Impact Investments) have a "Granted"/"Award Grant" `MachineEvent` whose
`to_state_id` points at the exact same `MachineState` row (id 10,
`granted`). `MachineState` has no theme-scoping column, and `MachineEvent`
confirmed empty on `unsafe_on_transition` for both events checked -- there
is no REST-visible mechanism for one theme to run different Ruby than
another on that shared state. **One `unsafe_after_enter` body serves every
theme whose workflow reaches it.** (This was confirmed the hard way: TRN's
shared body still has the `dyn_invoke_for(:"Send Proposal to PDC")` name-typo
bug noted earlier in this doc, fixed in DEV but not yet reflected on TRN --
proving there's exactly one body, not a correct one for some themes and a
stale one for others.)

This changes what "theme selection" means for future write/injection work:
it is not "write different content per theme" (there's nowhere to put
theme-specific content on a shared state) -- it's **"decide whether a given
install/update should touch the shared hook at all, based on which
theme(s) it's meant to affect."** A write that's scoped to "General
Operations only" but lands on a state also reached by "Grant Request" and
"X-Grants" affects all of them simultaneously, whether intended or not.

Implications for future write/injection work:

- **A user must be able to select which theme(s) an install/update is
  intended for**, and the tool should surface when that selection implies
  touching a hook that other, unselected themes also rely on -- so the
  blast radius is visible before a write happens, not discovered after.
- **Default selection should be "wherever PDC work already exists."** The
  inventory step (scanning every theme's workflow for events that reach a
  state with existing PDC invocations) is what makes this possible -- it's
  the detection mechanism the default selection would read from. See
  `deploy/pdcdeploy/themes.py` (`find_theme_pdc_status`) for the current
  read-only version of this detection.
- **When a theme has no PDC work yet, or the existing footprint is
  ambiguous** (e.g. some but not all of a model's themes reach the hooked
  state), the tool should prompt the user rather than guess.
- This generalizes beyond `GrantRequest`: any model type with multiple
  themes needs the same "which theme(s), and who else shares what I'm
  about to touch" question before a write.

## Stencil element identification (decided; not yet built)

Stencils are the other shared-surface case (alongside the `after_enter`
hook): `GrantRequest` has 51 stencils on TRN, one per theme, and only 2
matter for PDC (theme 2239 "Grant Request" -> stencil 45712; theme 13948
"General Operations" -> stencil 26253, matching the two live-PDC themes from
"Theme selection" above). Each of those stencils holds many elements we
don't own -- the Data Explorer is 6 separate blocks (per
[deployment.md](deployment.md)) that would need to be located as 6 separate
elements inside each stencil, without disturbing anything else there.

**Why not use the element's `uid`:** every element has a `uid`, but it's
generated per-instance at creation time -- confirmed on TRN (2026-09-25):
the GenericTemplate stencil holding oauth-callback.html has a `uid` that is
clearly random per-deployment, not something the repo could predict or pin
ahead of a fresh install into a different Fluxx org. A `uid`-based lookup
only works after the fact, on the instance that created it -- useless for
"is this the right element" across organizations, and fragile even within
one org if an element is ever deleted and recreated (new `uid`, same
intent).

**Decision: an HTML-comment marker embedded in the element's own content**,
e.g. `<!-- PDC:ELEMENT id=oauth-callback -->` as the first line, with no
version/hash in the marker -- just a stable id. Proven live against TRN
(2026-09-25): wrote a modified copy of stencil 2686 (the GenericTemplate
holding oauth-callback.html) with the marker prepended to the target
element's `config.text`, read it back, and the marker survived completely
intact (`strip_html=0` on that element, confirmed no comment-stripping);
then restored the original content and verified an exact byte-for-byte
match against a pre-write backup. This is the mechanism a future write/
comparison implementation should build on: locate "our" element within any
stencil by searching each element's content for the marker substring,
independent of `uid`, position, or which other elements surround it.

**Why no version in the marker:** considered and rejected. A version number
or content hash embedded in the marker would drift the moment someone edits
the element by hand in the Fluxx GUI -- exactly the scenario this project
needs to tolerate (see "Customization-aware skipping" above, and the user's
own framing: stencils are "easily modified in the GUI and someone may come
up with a better layout eventually"). Git already answers "what version is
this" for free (`git log` on the marked repo file); duplicating that into
the deployed artifact would just create a second, weaker source of truth
that can silently lie. Keep the marker doing exactly one job: stable
identity, nothing else.

**Still not built:** no markers have actually been added to the 6 Data
Explorer block files or oauth-callback.html yet, and no comparison logic
exists for either GrantRequest stencil (45712, 26253) or the GenericTemplate
stencil (2686) beyond the plain-text comparison for oauth-callback.html
implemented in this phase (see `compare.py`/`stencils.py`). Building the
actual marker-based extraction (locate element by marker inside a
`Stencil.json` element array, diff its content the same way
`compare_shared` does for hook text) is the next piece of real work here.

## Write operations (future)

Once comparison surfaces drift, the natural next step is applying fixes
rather than only reporting them. That means write operations against Fluxx:

- Creating/updating `MachineEvent` and `MachineState` records (workflow
  events and states).
- Injecting stencil elements (see above).
- Setting roles on workflow events, once role lookup exists.

Write operations need their own test coverage before relying on them --
specifically tests that verify the tool can actually create a workflow event
or state against a live instance, not just that comparison logic is correct.
TRN (`macfound-trn.fluxx.io`) is the only instance safe to write against; see
[stencil-import-export-api.md](stencil-import-export-api.md)'s note that DEV
is off limits because MacArthur does a one-way DEV→PROD copy.
