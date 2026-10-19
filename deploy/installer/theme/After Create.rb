# PDC deploy model: After Create
#
# Written into the deploy model theme's After Create block by PDC Bootstrap
# Deploy Model; edit it here, not in Fluxx. Before New set the deploy model up
# when the first New form opened, but the buttons need the Installer Role the
# admin picks on that form (a required field). Once the record is saved, this
# runs the bootstrap again; it finds everything else in place and creates the
# buttons with that role.

if ModelMethod.where(model_type: model.class.name, name: 'PDC Bootstrap Deploy Model', deleted_at: nil).exists?
  model.instance_variable_set(:@pdc_bootstrap, { 'phase' => 'after_create' })
  model.dyn_invoke_for(:"PDC Bootstrap Deploy Model")
end
