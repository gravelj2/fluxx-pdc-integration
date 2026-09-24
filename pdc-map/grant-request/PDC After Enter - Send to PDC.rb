###PDC_CODE###
pdc_consent_form = model.dyn_invoke_for(:"PDC Safe Consent Form Lookup")
if pdc_consent_form.present? && pdc_consent_form.consent_type.match?(/Grant consent/i)
    model.dyn_invoke_for(:"PDC Send Proposal to PDC")
end
###END_PDC_CODE###
