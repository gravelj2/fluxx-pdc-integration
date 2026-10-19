# PDC deploy model

The PDC integration is installed, updated, checked and removed from one dynamic model
inside Fluxx: the **deploy model**. Admins work entirely from its form: buttons run the
actions, and each action's results show on the form. The code reads what "correct" means
from this public repo, so nothing has to be copied by hand once the deploy model exists.

The deploy model stays in place after install. To remove PDC completely, click
**Uninstall**, delete what it lists for deleting by hand, then delete the deploy model.

## What's here

| Path | What it is |
|---|---|
| `pdc-scope.json` | Hand-maintained. *What* PDC consists of: owned models, GrantRequest pieces, secrets, exclusions, stencil-element fingerprints. |
| `pdc-manifest.json` | Generated, never hand-edited. Every PDC component with its natural key, settings, repo path and sha256. Validation compares against this. |
| `pdc-install-bundle.json` | Generated with the manifest. The same components with their bodies inlined, so Install and Uninstall need one fetch. |
| `installer/` | The deploy model's methods. Only `theme/Before New.rb` is pasted by hand; the rest is installed from `deploy-model.json` by the bootstrap. |
| `tools/pdc_manifest.rb` | Local Ruby (no gems) that builds and checks the manifest. |

## One-time setup (needs an admin who can save custom Ruby)

1. **Create the deploy model**: any name (TRN uses `PDC Install Config`). Fluxx creates
   its theme, workflow and blank stencils automatically.
2. **Paste `installer/theme/Before New.rb`** into that theme's Before New block. Check
   the three settings at the top: `repo_url`, `repo_ref` (pin a release tag or commit SHA
   in production), and `button_role`, the exact name of the role that may click the
   deploy model's buttons in this Fluxx.
3. **Create the first record.** Before New downloads `PDC Bootstrap Deploy Model` and
   runs it. That builds the rest of the deploy model from `installer/deploy-model.json`:
   its fields, installer methods, states, buttons and form. What it did shows on the
   form as **Installer update**.
   - Only one deploy record may exist. A second one deletes itself; Fluxx shows an error
     page.
   - The bootstrap uses `model.class`, so the model's name doesn't matter.
4. Later, **Update Installer** re-runs the bootstrap against `repo_ref`, replacing the
   deploy model's own methods and form with the repo copy.

## Using it

1. Open the deploy record that setup created. `repo_url`/`repo_ref` should be filled in
   (if they're blank, enter them; the installer also remembers them in a `PDC Repo
   Settings` method) and the dropdowns loaded; Refresh Lists reloads the dropdowns later.
2. Pick the three instance-specific choices. Names differ per org, so nothing is guessed:
   - `pdc_event_role`: the role that may click the PDC Integration Map's buttons (TRN: Admin)
   - `pdc_grantee_profile`: grantees, who view and update their own PDC Consent records (TRN: Grantee)
   - `pdc_staff_profile`: staff allowed to edit the PDC fields the Consent form restricts (TRN: Employee with Permissions Plus)
3. Click a button:

   | Button | What it does |
   |---|---|
   | **Validate** | Read-only. Compares this instance with the repo at `repo_ref`, so it previews what Install would change. |
   | **Install** | Installs and updates. Installs what's missing, restores what was soft-deleted (same id, so saved answers keep working), and overwrites anything PDC owns that differs from the repo. To move to another release, change `repo_ref` and click Install. Never removes anything: methods, states or buttons PDC didn't ship belong to whoever built them. |
   | **Uninstall** | Removes what PDC owns (soft-deleted where Fluxx allows) and lists anything it isn't sure about, plus the PDC models themselves, for someone to review and delete by hand. |
   | **Restore Previous** | Puts every PDC component back the way it was before the last Install, Uninstall or Restore. Clicking it twice undoes the restore. |
   | **Refresh Lists** | Reloads the role and profile dropdowns. |
   | **Update Installer** | Updates the deploy model itself from the repo. |

   Validate statuses:

   | Status | Meaning |
   |---|---|
   | `MATCH` | Present, and its checksum and settings agree with the repo |
   | `DIFFERS` | Present, but `detail` lists the checksum or setting that differs |
   | `MISSING` | No record with that name/key |
   | `EXTRA` | A live PDC record the manifest doesn't list (e.g. a leftover test method) |
   | `SKIPPED_SECRET` | Secret method: checked it exists, body never compared |
   | `MARKER_NOT_FOUND` | GrantRequest `granted` hook has no `###PDC_CODE###` block |
   | `MISSING_ROLE` / `ROLE_DIFFERS` | Integration Map button has no role, or not the chosen one |
   | `UNMARKED` | PDC stencil element recognized by fingerprint but lacking its `PDC:ELEMENT` marker (Install adds it) |
   | `UNMARKED_DIFFERS` | Same as `UNMARKED`, but the element's content also differs from the repo copy |
   | `CONFIG_DIFFERS` | A PDC stencil element has Allow JavaScript off, or strips HTML; its scripts won't run |
   | `PROFILE_DIFFERS` | Consent permissions or a stencil restriction use a different profile than the one chosen |
   | `AMBIGUOUS` | An element's fingerprints match more than one PDC element; needs a person to look |
   | `DUPLICATE` | The same PDC element appears more than once in one stencil |

Validation is read-only. The report keeps counts for everything, and detail for anything
that isn't `MATCH`.

## Results and snapshots on the form

Each action saves what it did to a text field on the deploy record, newest shown first:
`installer_results`, `validate_results`, `install_results`, `uninstall_results`,
`restore_results`. `PDC_Results` reads them and the Liquid block in
[installer/stencil/Results.liquid](installer/stencil/Results.liquid) renders when each
ran, a count per status, and the items under every status except MATCH/ok.

**Configuration snapshots.** Install, Uninstall and Restore Previous save a snapshot of
the whole PDC configuration before they change anything, and another after. That covers
fields and static options, methods, theme code, states, buttons (with from-states and
roles), the `granted` hook, and every form holding PDC elements or fields. Secret methods
are recorded only as existing or deleted, never their values.

Each snapshot is a text document of type **Snapshot** on the deploy record, named like
`PDC snapshot 2026-10-19 14:05:00 UTC before Install (main).json`. All of them are kept
(the GrantRequest forms make each one 1–3 MB). `previous_configuration` and
`current_configuration` hold just a pointer to the latest before and after documents, and
Restore Previous follows `previous_configuration`. If a snapshot doesn't read back
intact, the action stops with nothing changed. The snapshot documents belong to the deploy record and go with it if it's deleted, so
download the last snapshot first if you may need it.

What Install and Uninstall can't do yet:
- Install doesn't add or move PDC elements on forms. It reports a missing one, and
  after an Uninstall, **Restore Previous** is how to put them back. A run that changes
  nothing doesn't replace what Restore Previous goes back to, but any run that does
  change something does, so restore before running anything else.
- While any PDC model is missing, Install touches only the PDC models that exist:
  GrantRequest's PDC hooks call into all three, so they wait.
- Restore Previous leaves alone anything someone changed, created or re-linked after
  the last action, and lists it for review. Forms are compared whole: any edit to a form
  since then, PDC-related or not, means that form isn't restored.
- Install doesn't add a missing `###PDC_CODE###` block to the `granted` hook; it only
  updates one that's there.
- Neither creates or deletes models, profile permissions, or the models' own forms.

### The deploy model's form

The bootstrap (first record, and **Update Installer**) overwrites the deploy model's
form stencil with [installer/stencil/layout.json](installer/stencil/layout.json): the
settings fields and the results block. It isn't backed up; the layout lives in the repo.
Nothing else edits this stencil. Change the form by editing `layout.json` in the repo,
not in Fluxx, or the next Update Installer replaces your edits.

## Testing before a push

The buttons fetch from the repo. To try a change in Fluxx before pushing, build a
paste-in script that embeds what it needs, paste it into a temporary method on the
deploy model, and run it on the deploy record:

```bash
ruby deploy/tools/build_one_off_action.rb install    # also: validate, uninstall, restore
```

`build_one_off_layout.rb` does the same for the bootstrap's fields, document type and
form steps. Each script runs the same code as its button
and saves the record, so the results show on the form.

## Updating the manifest (maintainers)

The manifest is generated from a known-good instance, then the repo files become the
source of truth:

```bash
# 1. ruby deploy/tools/build_one_off_export.rb, paste DEV/one-off-export.rb into a temporary
#    method on the deploy model, run it, and save the PDCEXPORT1 line it returns, e.g. export.json
# 2. Write the bodies into the repo and regenerate the manifest:
ruby deploy/tools/pdc_manifest.rb unpack export.json
# 3. Review git diff, commit, push. Then Validate in Fluxx should be all MATCH.
```

After editing a body in the repo, run `ruby deploy/tools/pdc_manifest.rb rehash`, which
also rewrites `pdc-install-bundle.json`. `ruby deploy/tools/pdc_manifest.rb check` fails
on stale hashes, missing files, an out-of-date bundle, or a data-explorer file whose
marker/fingerprints don't identify it uniquely; run it before committing.

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
