# If consent was granted, then stamp the record with the data at the time of consent. 
if model.changes.include(:consent_type)
    model.dyn_invoke_for(:"Stamp Consent")
end