# PDC Bootstrap Deploy Model
#
# Builds (or refreshes) the deploy model itself from deploy/installer/
# deploy-model.json in the repo: its attributes, installer methods, states,
# and workflow buttons. Runs on whatever model type it's attached to
# (model.class), so the deploy model's name doesn't matter.
#
# Called by the pasted Before New on the first record, and later by the
# "Update Installer" button. Safe to re-run: missing pieces are created,
# changed method/state bodies are replaced, and every replaced body is first
# saved to previous_configuration (Fluxx hard-deletes, so there is no undo).
#
# Returns (and stores in current_configuration) a JSON log of what it did.

require 'json'
require 'net/http'
require 'uri'
require 'cgi'
require 'time'

mt = model.class.name
log = []
replaced = {}

# Repo location: handed over by Before New on the first run, else the record's fields.
handoff = model.instance_variable_get(:@pdc_bootstrap) || {}
repo_url = handoff['repo_url'] || (model.respond_to?(:repo_url) ? model.repo_url : nil)
repo_ref = handoff['repo_ref'] || (model.respond_to?(:repo_ref) ? model.repo_ref : nil)
repo_ref = 'main' if repo_ref.blank?

fetch = lambda do |path|
  m = repo_url.to_s.strip.match(%r{github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?/?\z})
  raise "repo_url must be a github.com repository URL, got #{repo_url.inspect}" unless m
  encoded = path.split('/').map { |p| CGI.escape(p).gsub('+', '%20') }.join('/')
  uri = URI.parse("https://raw.githubusercontent.com/#{m[1]}/#{m[2]}/#{repo_ref}/#{encoded}")
  resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    http.request(Net::HTTP::Get.new(uri))
  end
  raise "Could not fetch #{path} at '#{repo_ref}' (HTTP #{resp.code})" unless resp.code == '200'
  resp.body.to_s.dup.force_encoding('UTF-8')
end

same = lambda do |a, b|
  norm = lambda { |t| t.to_s.gsub("\r\n", "\n").split("\n").map(&:rstrip).join("\n").strip }
  norm.call(a) == norm.call(b)
end

# Can this user save custom Ruby? Tested by doing it inside a transaction that
# is always rolled back, so it works whatever Fluxx calls the permission.
ruby_denied =
  begin
    ActiveRecord::Base.transaction do
      ModelMethod.create!(model_type: mt, method_type: 'method', name: 'PDC Permission Probe', unsafe_dyn_method: "'ok'")
      raise ActiveRecord::Rollback
    end
    nil
  rescue => e
    "#{e.class}: #{e.message}"
  end

result =
  begin
    if ruby_denied
      raise "#{User.find_current_user rescue 'This user'} cannot save custom Ruby in Fluxx, which the PDC " \
            "installer needs. Ask a Fluxx admin with Ruby access to run this. (Fluxx said: #{ruby_denied})"
    end
    spec = JSON.parse(fetch.call('deploy/installer/deploy-model.json'))

    # 1. Attributes
    spec['attributes'].each do |a|
      if ModelAttribute.where(model_type: mt, name: a['name'], deleted_at: nil).exists?
        log << "attribute #{a['name']}: exists"
      else
        ModelAttribute.create!(model_type: mt, name: a['name'], description: a['description'],
                               attribute_type: a['attribute_type'], multi_allowed: false)
        log << "attribute #{a['name']}: created"
      end
    end

    # 2. Installer methods (bodies fetched from the repo)
    spec['methods'].each do |m|
      body = fetch.call(m['path'])
      mm = ModelMethod.where(model_type: mt, name: m['name'], deleted_at: nil).first
      if mm.nil?
        ModelMethod.create!(model_type: mt, method_type: m['method_type'] || 'method', name: m['name'], unsafe_dyn_method: body)
        log << "method #{m['name']}: created"
      elsif same.call(mm.unsafe_dyn_method, body)
        log << "method #{m['name']}: up to date"
      else
        replaced["method #{m['name']}"] = mm.unsafe_dyn_method
        mm.unsafe_dyn_method = body
        mm.save!
        log << "method #{m['name']}: updated"
      end
    end

    # 3. States (one per button; each hook keeps the previous state, then runs a method)
    states = {}
    spec['states'].each_with_index do |s, i|
      hook = s['invokes'] ? "#{spec['state_hook_prefix']}\nmodel.dyn_invoke_for(:\"#{s['invokes']}\")".strip : nil
      st = MachineState.where(model_type: mt, name: s['name'], deleted_at: nil).first
      if st.nil?
        st = MachineState.create!(model_type: mt, name: s['name'], description: s['description'],
                                  state_type: s['state_type'], state_order: i + 1, allowed_roles: '[]',
                                  unsafe_before_validation_enter: hook)
        log << "state #{s['name']}: created"
      elsif hook && !same.call(st.unsafe_before_validation_enter, hook)
        replaced["state #{s['name']}"] = st.unsafe_before_validation_enter
        st.unsafe_before_validation_enter = hook
        st.save!
        log << "state #{s['name']}: hook updated"
      else
        log << "state #{s['name']}: exists"
      end
      states[s['name']] = st
    end

    # 4. Workflow buttons on the auto-created workflow
    workflow = MachineWorkflow.where(model_type: mt, deleted_at: nil).first
    raise "No workflow for #{mt}; Fluxx normally creates one with the model" if workflow.nil?
    role = Role.where(name: spec['button_role'], deleted_at: nil).first
    log << "button role '#{spec['button_role']}' not found; buttons will have no role" if role.nil?
    filter = JSON.generate([
      { 'name' => 'advanced_query', 'value' => JSON.generate('group_type' => 'and', 'conditions' => [], 'relationship_filter_model_type' => mt) },
      { 'name' => 'advanced_sort', 'value' => '[]' },
      { 'name' => 'type', 'value' => 'MachineModel' },
      { 'name' => 'filter_type', 'value' => 'MachineModel' }
    ])
    spec['events'].each_with_index do |e, i|
      if MachineEvent.where(machine_workflow_id: workflow.id, button_name: e['button_name'], deleted_at: nil).exists?
        log << "button #{e['button_name']}: exists"
        next
      end
      ev = MachineEvent.create!(machine_workflow_id: workflow.id, button_name: e['button_name'],
                                to_state_id: states.fetch(e['to_state']).id, is_validation_suppressed: true,
                                guard_strategy: 'none', filter: filter)
      e['from_states'].each do |from|
        MachineEventFromState.create!(machine_event_id: ev.id, from_state_id: states.fetch(from).id, button_order: i + 1)
      end
      MachineEventRole.create!(machine_event_id: ev.id, role_id: role.id) if role
      log << "button #{e['button_name']}: created"
    end

    # 5. Record values and the instance-specific dropdowns
    model.repo_url = repo_url if model.respond_to?(:repo_url=) && model.repo_url.blank?
    model.repo_ref = repo_ref if model.respond_to?(:repo_ref=) && model.repo_ref.blank?
    log << model.dyn_invoke_for(:"PDC Populate Options").to_s

    { 'ok' => true }
  rescue => e
    { 'ok' => false, 'error' => "#{e.class}: #{e.message}" }
  end

unless replaced.empty?
  prior = {}
  begin
    prior = JSON.parse(model.previous_configuration.to_s) if model.respond_to?(:previous_configuration) && model.previous_configuration.present?
  rescue JSON::ParserError
    prior = { 'unparsed' => model.previous_configuration }
  end
  backups = prior['bootstrap_backups'].is_a?(Array) ? prior['bootstrap_backups'] : []
  backups << { 'at' => Time.now.utc.iso8601, 'replaced' => replaced }
  model.previous_configuration = JSON.pretty_generate(prior.merge('bootstrap_backups' => backups.last(5))) if model.respond_to?(:previous_configuration=)
end

report = JSON.pretty_generate(result.merge('ran_at' => Time.now.utc.iso8601, 'model_type' => mt,
                                           'repo_url' => repo_url, 'repo_ref' => repo_ref, 'log' => log))
model.current_configuration = report if model.respond_to?(:current_configuration=)
report
