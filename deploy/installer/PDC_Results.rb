# PDC_Results
#
# The latest validate / install / cleanup results saved on this deploy model,
# for the Liquid results block (deploy/installer/stencil/Results.liquid):
#
#   {% assign pdc = model.PDC_Results %}{% for section in pdc.sections %}...
#
# Each section has title, mode, ran_at, summary [{label, count, tone}],
# groups [{label, tone, items [{kind, key, detail}]}], and optionally
# error, warnings and backup. Underscored name so Liquid can call it.

require 'json'

sections = %w[validate_results install_results cleanup_results].map do |field|
  raw = model.respond_to?(field) ? model.public_send(field).to_s : ''
  next nil if raw.strip.empty?
  begin
    JSON.parse(raw)
  rescue JSON::ParserError
    { 'title' => field, 'error' => 'These results could not be read.' }
  end
end.compact

{ 'sections' => sections }
