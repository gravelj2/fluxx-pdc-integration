# PDC Bootstrap Deploy Model
#
# Builds (or refreshes) the deploy model itself from deploy/installer/
# deploy-model.json in the repo: its attributes, snapshot document type,
# installer methods, states, workflow buttons, and its form (stencil/layout.json overwrites the stencil
# Fluxx created). Runs on whatever model type it's attached to
# (model.class), so the deploy model's name doesn't matter.
#
# Called by the pasted Before New on the first record, and later by the
# "Update Installer" button. Safe to re-run: missing pieces are created, and
# changed method/state bodies and the form are replaced with the repo copy
# (all of it lives in the repo, so nothing here needs a backup).
#
# It never touches previous_configuration / current_configuration: those
# hold snapshots of the PDC configuration itself, for Restore Previous.
# Returns, and stores in installer_results, what it did.

require 'json'
require 'net/http'
require 'uri'
require 'cgi'
require 'time'
require 'securerandom'

mt = model.class.name
log = []

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

# Can this user save custom Ruby? Tested by doing it inside a savepoint that
# is always rolled back, so it works whatever Fluxx calls the permission.
# (requires_new: inside a save, a plain nested transaction can't roll back.)
ruby_denied =
  begin
    ActiveRecord::Base.transaction(requires_new: true) do
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

    # Document type for configuration snapshots (Install, Uninstall and
    # Restore Previous save each snapshot as a text document of this type)
    dt_name = spec['snapshot_document_type']
    if ModelDocumentType.where(model_type: mt, name: dt_name).where('retired IS NULL OR retired = ?', false).exists?
      log << "document type #{dt_name}: exists"
    else
      ModelDocumentType.create!(model_type: mt, name: dt_name, doc_label: 'default', permission_name: 'read_only',
                                model_theme_id: ModelTheme.where(model_type: mt, deleted_at: nil).order(:id).first&.id)
      log << "document type #{dt_name}: created"
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
    # Role from Before New on the first run; on Update Installer, the role the
    # existing buttons use; else deploy-model.json's default
    role_name = handoff['button_role']
    role = role_name.present? ? Role.where(name: role_name, deleted_at: nil).first : nil
    role ||= Role.where(id: MachineEventRole.where(machine_event_id: MachineEvent.where(machine_workflow_id: workflow.id, deleted_at: nil).select(:id)).select(:role_id)).first
    role ||= Role.where(name: spec['button_role'], deleted_at: nil).first
    if role.nil?
      log << "button role '#{role_name || spec['button_role']}': not found (no one can use the buttons; set button_role in Before New to a role in this Fluxx, or add a role to each button in the workflow editor)"
    end
    filter = JSON.generate([
      { 'name' => 'advanced_query', 'value' => JSON.generate('group_type' => 'and', 'conditions' => [], 'relationship_filter_model_type' => mt) },
      { 'name' => 'advanced_sort', 'value' => '[]' },
      { 'name' => 'type', 'value' => 'MachineModel' },
      { 'name' => 'filter_type', 'value' => 'MachineModel' }
    ])
    spec['events'].each_with_index do |e, i|
      existing = MachineEvent.where(machine_workflow_id: workflow.id, button_name: e['button_name'], deleted_at: nil).first
      if existing
        if role && !MachineEventRole.where(machine_event_id: existing.id).exists?
          MachineEventRole.create!(machine_event_id: existing.id, role_id: role.id)
          log << "button #{e['button_name']}: role added"
        else
          log << "button #{e['button_name']}: exists"
        end
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

    # 5. The deploy model's own form: overwrite the stencil Fluxx created with
    # the repo layout. This is the only installer step that edits it; the other
    # methods just write field values the layout renders.
    layout = JSON.parse(fetch.call(spec['stencil_layout']))
    attr_types = ModelAttribute.where(model_type: mt, deleted_at: nil).pluck(:name, :attribute_type).to_h
    visibility = lambda do
      { 'visible_show' => true, 'visible_form' => true, 'advanced_filter' => '1',
        'advanced_query' => JSON.generate('group_type' => 'and', 'conditions' => [], 'relationship_filter_model_type' => mt),
        'advanced_sort' => '[]' }
    end
    build = nil
    build = lambda do |el|
      if el['group']
        { 'element_type' => 'group', 'name' => 'group', 'label' => el['group'],
          'config' => { 'label' => el['group'], 'collapsible' => el['collapsible'] ? '1' : '0', 'default_open' => '0',
                        'disable_lazy_load' => '0', 'hide_label' => '0', 'reveal_if_type' => 'show', 'show_in_toc' => '0' },
          'visibility' => visibility.call,
          'styling' => { 'alignment' => 'left', 'border_radius' => '7', 'padding_top' => '7', 'padding_bottom' => '7',
                         'padding_left' => '7', 'padding_right' => '7', 'border_top_enabled' => true,
                         'border_bottom_enabled' => true, 'border_left_enabled' => true, 'border_right_enabled' => true },
          'uid' => SecureRandom.uuid, 'elements' => el['elements'].map { |c| build.call(c) } }
      elsif el['raw']
        # An element copied as Fluxx stores it (e.g. a documents list): fresh
        # uids, and filters pointed at this model type
        fresh = nil
        fresh = lambda do |node|
          case node
          when Hash
            node.each_with_object({}) do |(k, v), h|
              h[k] = if k == 'uid' then SecureRandom.uuid
                     elsif k == 'advanced_query' && v.is_a?(String) then v.gsub(/"relationship_filter_model_type":"[^"]*"/, %("relationship_filter_model_type":"#{mt}"))
                     else fresh.call(v)
                     end
            end
          when Array then node.map { |v| fresh.call(v) }
          else node
          end
        end
        fresh.call(el['raw'])
      elsif el['field']
        raise "layout field #{el['field']} is not an attribute on #{mt}" unless attr_types.key?(el['field'])
        config = { 'label' => el['label'], 'required' => '0' }
        config['show_as_radio_buttons'] = '0' if attr_types[el['field']] == 'multi_value'
        config.merge!('allow_rich_text' => '0', 'trackable' => '0', 'trackable_workflow' => '0') if attr_types[el['field']] == 'text'
        vis = visibility.call
        vis['lock_field'] = true if el['lock']
        { 'element_type' => 'attribute', 'name' => el['field'], 'label' => el['label'], 'config' => config,
          'visibility' => vis, 'styling' => { 'alignment' => 'left' }, 'uid' => SecureRandom.uuid }
      else
        { 'element_type' => 'text', 'name' => 'text',
          'config' => { 'text' => fetch.call(el['text_path']), 'strip_html' => '0', 'allow_script' => '0' },
          'visibility' => visibility.call, 'styling' => { 'alignment' => 'left' }, 'uid' => SecureRandom.uuid }
      end
    end
    new_doc = { 'elements' => layout['elements'].map { |el| build.call(el) } }
    without_uids = nil
    without_uids = lambda do |node|
      case node
      when Hash then node.reject { |k, _| k == 'uid' }.transform_values { |v| without_uids.call(v) }
      when Array then node.map { |v| without_uids.call(v) }
      else node
      end
    end
    form_types = lambda { |st| st.form_type.is_a?(Array) ? st.form_type.map(&:to_s) : st.form_type.to_s.split(/[,\s]+/) }
    stencils = Stencil.where(model_type: mt, deleted_at: nil).to_a
    target = stencils.select { |st| form_types.call(st).include?('form') }.max_by { |st| [st.compiled ? 1 : 0, st.updated_at.to_i] }
    if target.nil?
      log << "stencil: none found for #{mt} (#{stencils.size} without a form type); create the form in the GUI and click Update Installer"
    else
      old_doc = (JSON.parse(target['json'].to_s) rescue nil)
      if old_doc && without_uids.call(old_doc) == without_uids.call(new_doc)
        log << "stencil #{target.id}: up to date"
      else
        target['json'] = JSON.generate(new_doc)
        target.save!
        log << "stencil #{target.id}: overwritten with the repo layout"
      end
      others = stencils.map(&:id) - [target.id]
      log << "stencil: left other #{mt} stencils alone (#{others.join(', ')})" unless others.empty?
    end

    # 6. Record values and the instance-specific dropdowns
    model.repo_url = repo_url if model.respond_to?(:repo_url=) && model.repo_url.blank?
    model.repo_ref = repo_ref if model.respond_to?(:repo_ref=) && model.repo_ref.blank?
    log << model.dyn_invoke_for(:"PDC Populate Options").to_s

    { 'ok' => true }
  rescue => e
    { 'ok' => false, 'error' => "#{e.class}: #{e.message}" }
  end

# Results in the same shape as the other actions, for the form
entries = log.map do |line|
  key, status = line.to_s.split(/: (?=[^:]*\z)/, 2)
  status = case status
           when 'exists', 'up to date' then 'ok'
           when 'created' then 'created'
           when nil then (key = line.to_s; 'note')
           else status =~ /updated|overwritten/ ? 'overwrote' : status
           end
  { 'status' => status, 'key' => key }
end
record =
  begin
    model.dyn_invoke_for(:"PDC Installer Lib")[:results_record].call(
      'Installer update', "from #{repo_ref}", entries, result['error'] ? { 'error' => result['error'] } : {})
  rescue => e
    { 'title' => 'Installer update', 'mode' => "from #{repo_ref}", 'ran_at' => Time.now.utc.iso8601,
      'error' => [result['error'], "#{e.class}: #{e.message}"].compact.join(' / '),
      'groups' => [{ 'label' => 'log', 'tone' => 'info', 'items' => log.map { |l| { 'key' => l.to_s } } }] }
  end
model.installer_results = JSON.generate(record) if model.respond_to?(:installer_results=)
JSON.generate(record)
