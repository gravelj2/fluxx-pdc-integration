# PDC deploy model

The PDC integration is installed, checked and (later) removed by Ruby methods on one
dynamic model inside Fluxx: the **deploy model**. The code reads what "correct" means
from this public repo, so nothing has to be copied by hand once the deploy model exists.

The deploy model stays in place after install. It's the console for validating and
repairing PDC. To remove PDC completely, an admin runs the uninstall method (coming
next) and then deletes the deploy model in the GUI.

## What's here

| Path | What it is |
|---|---|
| `pdc-scope.json` | Hand-maintained. *What* PDC consists of: owned models, GrantRequest pieces, secrets, exclusions, stencil-element fingerprints. |
| `pdc-manifest.json` | Generated, never hand-edited. Every PDC component with its natural key, settings, repo path and sha256. Validation compares against this. |
| `installer/` | The deploy model's methods. Only `theme/Before New.rb` is pasted by hand; the rest is installed from `deploy-model.json` by the bootstrap. |
| `tools/pdc_manifest.rb` | Local Ruby (no gems) that builds and checks the manifest. |

## One-time setup (needs an admin who can save custom Ruby)

1. **Create the deploy model**: any name (TRN uses `PDC Install Config`). Fluxx creates
   its theme, workflow and blank stencils automatically.
2. **Paste `installer/theme/Before New.rb`** into that theme's Before New block. Set
   `repo_url` / `repo_ref` at the top; pin a release tag or commit SHA in production.
3. **Create the first record.** Before New downloads `PDC Bootstrap Deploy Model` and
   runs it. That builds the rest of the deploy model from `installer/deploy-model.json`:
   its attributes, installer methods, states and the Validate / Refresh Lists /
   Update Installer buttons. The log lands in `current_configuration`.
   - Only one deploy record may exist. A second one deletes itself; Fluxx shows an error
     page.
   - The bootstrap uses `model.class`, so the model's name doesn't matter.
4. Later, **Update Installer** re-runs the bootstrap against `repo_ref`. Any method or
   state body it replaces is saved to `previous_configuration` first, because Fluxx
   hard-deletes and there is no undo.

The stencil isn't generated yet; lay out the fields by hand for now.

## Using it

1. Create a deploy record. Before New fills in `repo_url`/`repo_ref` and the role list.
2. Pick the three instance-specific choices. Names differ per org, so nothing is guessed:
   - `pdc_event_role`: the role that may click the PDC Integration Map's buttons (TRN: Admin)
   - `pdc_grantee_profile`: grantees, who view and update their own PDC Consent records (TRN: Grantee)
   - `pdc_staff_profile`: staff allowed to edit the PDC fields the Consent form restricts (TRN: Employee with Permissions Plus)
3. Click **Validate**. The report lands in `validation_report`:

   | Status | Meaning |
   |---|---|
   | `MATCH` | Present, and its checksum and settings agree with the repo |
   | `DIFFERS` | Present, but `detail` lists the checksum or setting that differs |
   | `MISSING` | No record with that name/key |
   | `EXTRA` | A live PDC record the manifest doesn't list (e.g. a leftover test method) |
   | `SKIPPED_SECRET` | Secret method: checked it exists, body never compared |
   | `MARKER_NOT_FOUND` | GrantRequest `granted` hook has no `###PDC_CODE###` block |
   | `MISSING_ROLE` / `ROLE_DIFFERS` | Integration Map button has no role, or not the chosen one |
   | `UNMARKED` | PDC stencil element recognized by fingerprint but lacking its `PDC:ELEMENT` marker (fixed by the upcoming "Adopt markers" step) |
   | `UNMARKED_DIFFERS` | Same as `UNMARKED`, but the element's content also differs from the repo copy |
   | `CONFIG_DIFFERS` | A PDC stencil element has Allow JavaScript off, or strips HTML; its scripts won't run |
   | `PROFILE_DIFFERS` | Consent permissions or a stencil restriction use a different profile than the one chosen |
   | `AMBIGUOUS` | An element's fingerprints match more than one PDC element; needs a person to look |
   | `DUPLICATE` | The same PDC element appears more than once in one stencil |

Validation is read-only. The report keeps counts for everything, and detail for anything
that isn't `MATCH`.

## Updating the manifest (maintainers)

The manifest is generated from a known-good instance, then the repo files become the
source of truth:

```bash
# 1. In Fluxx, run PDC_Export_Components on the deploy record and save its output, e.g. export.json
# 2. Write the bodies into the repo and regenerate the manifest:
ruby deploy/tools/pdc_manifest.rb unpack export.json
# 3. Review git diff, commit, push. Then Validate in Fluxx should be all MATCH.
```

After editing a body in the repo, run `ruby deploy/tools/pdc_manifest.rb rehash`.
`ruby deploy/tools/pdc_manifest.rb check` fails on stale hashes, missing files, or a
data-explorer file whose marker/fingerprints don't identify it uniquely; run it before
committing.

Repo files remain authoritative for data-explorer stencil elements (they carry the
markers), so `unpack` never overwrites `data-explorer/`. Secret method bodies are never
exported.

## Scope rules

- **Owned** (`owned_model_types`): compared whole: models, attributes, static dropdown
  options, methods, theme hooks, states, events (minus roles, which are chosen per
  instance), and the main form stencil.
- **Shared** (GrantRequest, GenericTemplate): only `PDC`-prefixed methods, the
  `pdc_account_exists` / `pdc_proposal_id` attributes, the `###PDC_CODE###` slice of the
  `granted` hook, and marked/fingerprinted stencil elements.
- **Dropdowns filled at runtime** (`runtime_option_attributes`): the attribute must exist;
  its options aren't compared.
- `ModelAttributeChoice` holds per-record values and is never read or written.
