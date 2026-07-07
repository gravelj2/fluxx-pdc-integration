# Ruby Method: "Get PDC Field Mapping"
# Model: GrantRequest
#
# Purpose:
#   Queries for the first MacModelTypeDynPDCApplicationForm1 record,
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

map_record = MacModelTypeDynPDCApplicationForm1.first

if map_record.nil?
  return ""
end

Base64.strict_encode64(map_record.dyn_invoke_for(:"Get Field Mapping JSON for PDC Data Explorer").to_json)