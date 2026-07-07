# Find all consent forms related to the current model using consent.grant_or_request_id.id == model.id
# since grant_or_request_id is a virtual attribute, we filter in Ruby after fetching all relevant records
related_consent_forms = []
grants_on_org = GrantRequest.where(program_organization_id: model.program_organization.id).sort_by { | request | request.created_at }.reverse

grants_on_org.each do | request | 
    related_consent_forms << request.dyn_invoke_for("PDC Safe Consent Form Lookup")
end

latest_consent = related_consent_forms.compact.first
if latest_consent != nil 
    latest_consent.last.consent_type
else
    nil
end