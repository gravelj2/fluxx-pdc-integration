# PDC Mapped Field (`MacModelTypeDynPdcMappedField1`)

Child records of the PDC Integration Map (`MacModelTypeDynPdcApplicationForm1`).
Each record maps one PDC base field (`pdc_field`, a PDC short code) to one Fluxx
field (`fluxx_field`, a packed descriptor like `Organization (core): Name [string]`),
plus `pdc_field_position` and `pdc_application_field_instructions`.

This model currently has **no methods of its own** — it is created, sorted,
updated, and deleted entirely by methods on the Integration Map model
(see `../pdc-integration-map/`, e.g. `Update Field Mapping from Selected
Application.rb`, `Set Sort Order Of Mapped Fields.rb`, `Delete Field Mappings
on this Form.rb`) and read by `GrantRequest` methods when sending proposals.

The folder exists so that any future methods on this model have an obvious home.
