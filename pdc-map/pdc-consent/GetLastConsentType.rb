org = model.grant_or_request_id.program_organization
lastGrantByOrg = org.grant_requests.where('id <> ?', model.grant_or_request_id.id).order(created_at: :desc).first
if lastGrantByOrg.present?
    model.respond_to(:reverse_pdc_mapping_field_MacModelTypeDynPDCConsent) ? model.reverse_pdc_mapping_field_MacModelTypeDynPDCConsent : nil
end