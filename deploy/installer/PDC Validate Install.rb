# PDC Validate Install
#
# Compares this instance against deploy/pdc-manifest.json at the deploy
# model's repo_url / repo_ref and reports, per component:
#   MATCH             found, checksums and settings agree
#   DIFFERS           found, but a checksum or setting differs (detail lists which)
#   MISSING           nothing with that name/key exists
#   EXTRA             a live PDC record the manifest doesn't know about
#   SKIPPED_SECRET    secret method; existence checked, body never compared
#   MARKER_NOT_FOUND  shared hook exists but has no ###PDC_CODE### block
#   MISSING_ROLE / ROLE_DIFFERS  event has no role / not the pdc_event_role chosen here
#   UNMARKED          PDC stencil element found by fingerprint, no PDC:ELEMENT marker yet
#   AMBIGUOUS         an element's fingerprints match more than one PDC element; needs a human
#   DUPLICATE         the same PDC element appears more than once in one stencil
#
# Writes the report to validation_report / last_validated_at when those
# fields exist, and returns it. Read-only otherwise.

require 'json'
require 'time'

lib = model.dyn_invoke_for(:"PDC Installer Lib")
report =
  begin
    manifest = lib[:fetch_repo_json].call(model, 'deploy/pdc-manifest.json')
    # Validate with the scope the manifest was built from, so fingerprints
    # and exclusions always agree with the hashes.
    live = lib[:collect].call(manifest['scope'], false)
    rows = lib[:validate].call(manifest, live, model)
    lib[:summarize].call(
      rows,
      'validated_at' => Time.now.utc.iso8601,
      'repo_url' => model.repo_url,
      'ref' => lib[:repo_ref].call(model),
      'manifest_source' => manifest['source'],
      'event_role' => lib[:selected_role_name].call(model),
      'warnings' => Array(live['warnings'])
    )
  rescue => e
    { 'validated_at' => Time.now.utc.iso8601, 'error' => "#{e.class}: #{e.message}" }
  end

text = JSON.pretty_generate(report)
model.validation_report = text if model.respond_to?(:validation_report=)
model.last_validated_at = Time.now if model.respond_to?(:last_validated_at=)
text
