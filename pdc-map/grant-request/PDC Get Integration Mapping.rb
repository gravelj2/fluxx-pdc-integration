  # Try to find existing by checking all records by matching the integration name to the model theme.
MacModelTypeDynPdcApplicationForm1.where(
    state: 'active')
    .find { |record| record.get_dyn_value(:name) == model.model_theme.name }