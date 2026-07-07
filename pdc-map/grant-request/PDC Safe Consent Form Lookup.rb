begin
    model.rd_tab_dyn_models("MacModelTypeDynPDCConsent")
rescue NoMethodError => e
    if e.message.include?("collect") && e.message.include?("nil:NilClass")
       []
    else
        raise
    end
end