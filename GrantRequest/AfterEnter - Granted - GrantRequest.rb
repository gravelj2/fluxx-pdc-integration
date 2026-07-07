# Automatically un-set the NIC flag on all unapproved (non-progress) reports

model.request_reports.each do |rpt|

	if rpt.nic_flag == true		

		rpt.nic_flag = nil

		rpt.save(validate: false)

	end

end

if model.grant_approved_date.blank?

model.grant_approved_date = Time.now.utc.in_time_zone("Central Time (US & Canada)").to_date

end
###PDC_CODE###
pdc_consent_form = model.dyn_invoke_for(:"PDC Safe Consent Form Lookup")
if pdc_consent_form.present?
    model.dyn_invoke_for(:"Send Proposal to PDC")
end
###END_PDC_CODE###