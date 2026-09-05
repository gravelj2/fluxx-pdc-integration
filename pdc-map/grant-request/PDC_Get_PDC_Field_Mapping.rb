# Ruby Method: "Get PDC Field Mapping"
# Model: GrantRequest
#
# Purpose:
#   Queries for the first MacModelTypeDynPdcApplicationForm1 record,
#   invokes "Get Field Mapping JSON for PDC Data Explorer" on it,
#   and returns the Base64-encoded JSON result.
#
#   This indirection exists because there is no direct relationship
#   between a grant and the PDC integration map. The grant's method
#   resolves the map at render time (when the stencil loads), not
#   at save time.
#
# TODO:
#   Replace .first with selection logic that picks the correct map
#   based on the grant's application form, program, or other context.
#   Possible approaches:
#     - Match on application_form_id if the map stores one
#     - Match on program area or funding opportunity
#     - Accept a parameter from Liquid (if supported)
#
# Output:
#   Base64-encoded JSON string (same contract as the underlying method).
#   Returns empty string if no map record exists.
#
# Invoked from Liquid as:
#   {% assign mapping_data = model."Get PDC Field Mapping" %}

# ---- Method body ----

map_record = MacModelTypeDynPdcApplicationForm1.first

# NOTE: this body is a Fluxx dynamic model method, not a real Ruby method, so a
# top-level `return` raises LocalJumpError ("unexpected return") and corrupts the
# rendered stencil (the error string is injected as HTML). Use a conditional
# expression as the method's return value instead of an early `return`.
if map_record.nil?
  ""
else
  Base64.strict_encode64(map_record.dyn_invoke_for(:"Get Field Mapping JSON for PDC Data Explorer").to_json)
end
