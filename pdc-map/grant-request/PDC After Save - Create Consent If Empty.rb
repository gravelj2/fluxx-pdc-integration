# If program_organzation is set and the consent form has not been created, create it.
# This can't be on "before_new" or "after_create" because we couldn't default consent from previous forms.

if !model.program_organization.blank? && model.dyn_invoke_for(:"PDC Safe Consent Form Lookup").blank?
  model.dyn_invoke_for(:"PDC Create Consent Form")
end