# PDC Install
#
# The Install button on the deploy model. Brings every PDC component in line
# with deploy/pdc-install-bundle.json at this record's repo_url / repo_ref:
# installs what's missing, restores what was soft-deleted (keeping its id, so
# saved answers and buttons pointing at it keep working) and overwrites
# anything PDC owns that differs. That makes it both the installer and the
# updater: point repo_ref at another release and click Install.
#
# Never removes anything. Methods, states or buttons it doesn't recognize are
# left alone: whoever built them owns them. While any PDC model is missing,
# only the existing PDC models are touched (GrantRequest's PDC hooks need
# all of them).
#
#   fields    restore/create fields and static dropdown options; a field
#             whose type or settings differ is only reported (changing a field
#             under existing data is unsafe)
#   methods   restore/create/overwrite (secret methods are never written)
#   themes    Before New / After Create code
#   states    restore/create/overwrite settings and hooks
#   buttons   restore/create/overwrite target, from-states, guard, filter;
#             a button with no role gets the PDC Event Role chosen here (else
#             the role the workflow's other buttons use); with neither, a
#             missing button isn't created
#   granted   the ###PDC_CODE### block in GrantRequest's granted hook
#   elements  the text and settings of PDC stencil elements already on a
#             form (missing elements are reported; Install doesn't add or
#             move elements yet)
#
# Validate shows what Install will change. Before changing anything, the
# whole PDC configuration is saved to previous_configuration; Restore
# Previous puts it back. Results go to install_results.

require 'json'
require 'time'
require 'cgi'

lib = model.dyn_invoke_for(:"PDC Installer Lib") unless defined?(lib) && lib
# A pasted test script embeds the bundle and sets pdc_one_off.
bundle = (defined?(pdc_bundle) && pdc_bundle) || lib[:fetch_repo_json].call(model, 'deploy/pdc-install-bundle.json')
save_now = defined?(pdc_one_off) && pdc_one_off ? true : false

install = lambda do |log|
  scope = bundle['scope']
  markers = scope['markers']
  required_config = scope['element_required_config'] || {}

  # Install doesn't create the PDC models (or their themes and workflows)
  # yet. Anything on a PDC model that doesn't exist is skipped, never created
  # as an orphan, and the model is reported.
  owned = scope['owned_model_types'].keys
  present = MachineModelType.where(model_type: owned, deleted_at: nil).pluck(:model_type)
  missing_models = owned - present
  missing_models.each { |mt| log['model missing (create it first; its pieces were skipped)'] << mt }
  on_missing_model = lambda { |item| owned.include?(item['model_type']) && !present.include?(item['model_type']) }
  b = bundle.dup
  %w[attributes methods themes states events].each { |k| b[k] = bundle[k].reject { |x| on_missing_model.call(x) } }
  # GrantRequest's PDC hooks call into the PDC models (e.g. creating a Consent
  # record on save), so they would break GrantRequest saves without them. With
  # any PDC model missing, nothing outside the PDC models is touched.
  unless missing_models.empty?
    gr_type = scope['grant_request']['model_type']
    %w[attributes methods].each do |k|
      held = b[k].select { |x| x['model_type'] == gr_type }
      held.each { |x| log['waits for the PDC models'] << x['key'] }
      b[k] = b[k] - held
    end
    b['shared_slices'].each { |x| log['waits for the PDC models'] << x['key'] }
    b['shared_slices'] = []
    b['stencil_elements'] = []
  end

  # Columns whose value differs from what's wanted. Code compares normalized
  # text, so whitespace-only drift doesn't count.
  diffs = lambda do |rec, desired|
    desired.select do |col, val|
      col.start_with?('unsafe_') ? lib[:sha].call(rec[col]) != lib[:sha].call(val) : rec[col] != val
    end.keys
  end
  reconcile = lambda do |key, rec, desired, extra_changes = [], apply_extra = nil|
    changed = diffs.call(rec, desired)
    if changed.empty? && extra_changes.empty?
      log['ok'] << key
      next
    end
    changed.each { |c| rec[c] = desired[c] }
    rec.save! unless changed.empty?
    apply_extra.call if apply_extra
    log['overwrote'] << "#{key} [#{(changed + extra_changes).join(', ')}]"
  end
  # Live record, else bring back the latest soft-deleted one, else a new one.
  revive = lambda do |rel, attrs|
    gone = rel.where.not(deleted_at: nil).order(deleted_at: :desc).first
    rec = gone || rel.klass.new(attrs)
    rec.deleted_at = nil if gone
    [rec, gone ? 'restored' : 'created']
  end

  # Fields and static dropdown options
  b['attributes'].each do |a|
    rel = ModelAttribute.where(model_type: a['model_type'], name: a['name'])
    live = rel.where(deleted_at: nil).first
    want = { 'description' => a['description'], 'attribute_type' => a['attribute_type'],
             'multi_allowed' => a['multi_allowed'], 'value_model_type' => a['value_model_type'] }
    if live.nil?
      live, how = revive.call(rel, model_type: a['model_type'], name: a['name'])
      want.each { |c, v| live[c] = v }
      live.save!
      log["#{how} field"] << a['key']
    else
      changed = want.reject { |c, v| c == 'multi_allowed' ? lib[:truthy].call(live[c]) == (v ? true : false) : live[c] == v }.keys
      changed.empty? ? log['ok'] << a['key'] : log['field differs (change by hand)'] << "#{a['key']} [#{changed.join(', ')}]"
    end
    next unless a['options'].is_a?(Array)
    a['options'].each do |o|
      key = "#{a['key']} = #{o['value']}"
      rel = ModelAttributeValue.where(model_attribute_id: live.id, value: o['value'])
      want = { 'description' => o['description'], 'display_order' => o['display_order'], 'retired' => o['retired'] }
      if (opt = rel.where(deleted_at: nil).first)
        reconcile.call(key, opt, want)
        next
      end
      opt, how = revive.call(rel, model_attribute_id: live.id, value: o['value'])
      want.each { |c, v| opt[c] = v }
      opt.save!
      log["#{how} option"] << key
    end
  end

  # Methods. Secret methods are never written; a soft-deleted one is only
  # un-deleted (its value stays as it was).
  b['methods'].each do |m|
    rel = ModelMethod.where(model_type: m['model_type'], name: m['name'])
    if m['secret']
      next log['ok'] << m['key'] if rel.where(deleted_at: nil).exists?
      gone = rel.where.not(deleted_at: nil).order(deleted_at: :desc).first
      next log['secret method missing (enter it by hand)'] << m['key'] if gone.nil?
      gone.deleted_at = nil
      gone.save!
      log['restored'] << m['key']
      next
    end
    want = { 'method_type' => m['method_type'], 'unsafe_dyn_method' => m['body'] }
    if (live = rel.where(deleted_at: nil).first)
      reconcile.call(m['key'], live, want)
      next
    end
    rec, how = revive.call(rel, model_type: m['model_type'], name: m['name'])
    want.each { |c, v| rec[c] = v }
    rec.save!
    log[how] << m['key']
  end

  # Theme hooks (the themes themselves come with the models)
  b['themes'].each do |t|
    rec = ModelTheme.where(model_type: t['model_type'], name: t['name'], deleted_at: nil).first
    if rec.nil?
      log['theme missing (create the model first)'] << t['key']
      next
    end
    reconcile.call(t['key'], rec, 'unsafe_before_new_block' => t['before_new'], 'unsafe_after_create_block' => t['after_create'])
  end

  # States
  b['states'].each do |s|
    rel = MachineState.where(model_type: s['model_type'], name: s['name'])
    want = { 'description' => s['description'], 'state_type' => s['state_type'], 'state_order' => s['state_order'],
             'allowed_roles' => s['allowed_roles'], 'unsafe_before_validation_enter' => s['before_validation_enter'],
             'unsafe_after_enter' => s['after_enter'] }
    if (live = rel.where(deleted_at: nil).first)
      reconcile.call(s['key'], live, want)
      next
    end
    rec, how = revive.call(rel, model_type: s['model_type'], name: s['name'])
    want.each { |c, v| rec[c] = v }
    rec.save!
    log[how] << s['key']
  end

  # Buttons
  state_id = lambda { |mt, name| MachineState.where(model_type: mt, name: name, deleted_at: nil).first&.id }
  pick_role = lambda do |wf|
    named = lib[:selected_role_name].call(model)
    role = named && Role.where(name: named, deleted_at: nil).first
    role || begin
      ids = MachineEventRole.where(machine_event_id: MachineEvent.where(machine_workflow_id: wf.id, deleted_at: nil).pluck(:id)).pluck(:role_id)
      common = ids.group_by { |i| i }.max_by { |_, v| v.size }
      common && Role.find_by(id: common.first)
    end
  end
  b['events'].each do |e|
    theme = ModelTheme.where(model_type: e['model_type'], name: e['theme'], deleted_at: nil).first
    wf = theme && MachineWorkflow.where(model_theme_id: theme.id, deleted_at: nil).first
    if wf.nil?
      log['workflow missing (create the model first)'] << e['key']
      next
    end
    to_id = state_id.call(e['model_type'], e['to_state'])
    want_from = e['from_states'].map { |name, order| [state_id.call(e['model_type'], name), order] }
    if to_id.nil? || want_from.any? { |id, _| id.nil? }
      log['skipped, a state it needs is missing'] << e['key']
      next
    end
    want_from = want_from.sort
    want = { 'to_state_id' => to_id, 'is_validation_suppressed' => e['is_validation_suppressed'],
             'guard_strategy' => e['guard_strategy'], 'filter' => e['filter'], 'unsafe_guard' => e['guard'] }
    set_links = lambda do |ev|
      have = MachineEventFromState.where(machine_event_id: ev.id).map { |f| [f.from_state_id, f.button_order] }.sort
      if have != want_from
        MachineEventFromState.where(machine_event_id: ev.id).destroy_all
        want_from.each { |id, order| MachineEventFromState.create!(machine_event_id: ev.id, from_state_id: id, button_order: order) }
      end
      if MachineEventRole.where(machine_event_id: ev.id).empty? && (role = pick_role.call(wf))
        MachineEventRole.create!(machine_event_id: ev.id, role_id: role.id)
      end
    end
    rel = MachineEvent.where(machine_workflow_id: wf.id, button_name: e['button_name'])
    if (live = rel.where(deleted_at: nil).first)
      have = MachineEventFromState.where(machine_event_id: live.id).map { |f| [f.from_state_id, f.button_order] }.sort
      extra = []
      extra << 'from_states' if have != want_from
      if MachineEventRole.where(machine_event_id: live.id).empty?
        pick_role.call(wf) ? extra << 'role' : log['button has no role (choose PDC Event Role, then Install again)'] << e['key']
      end
      reconcile.call(e['key'], live, want, extra, -> { set_links.call(live) })
      next
    end
    # A button nobody can click isn't created; choose the role first.
    if pick_role.call(wf).nil?
      log['button not created: no role (choose PDC Event Role, then Install again)'] << e['key']
      next
    end
    rec, how = revive.call(rel, machine_workflow_id: wf.id, button_name: e['button_name'])
    ActiveRecord::Base.transaction(requires_new: true) do
      want.each { |c, v| rec[c] = v }
      rec.save!
      set_links.call(rec)
    end
    log[how] << e['key']
  end

  # The PDC block inside GrantRequest's shared state hooks (only replaced
  # when its markers are there; the rest of the hook isn't PDC's)
  b['shared_slices'].each do |x|
    st = MachineState.where(model_type: x['model_type'], name: x['state'], deleted_at: nil).first
    slice = st && lib[:code_slice].call(st[x['field']], markers)
    want = lib[:code_slice].call(x['body'], markers) || x['body']
    if slice.nil?
      log['PDC block not found (add by hand)'] << x['key']
    elsif lib[:sha].call(slice) == lib[:sha].call(want)
      log['ok'] << x['key']
    else
      st[x['field']] = st[x['field']].sub(slice) { want }
      st.save!
      log['overwrote'] << x['key']
    end
  end

  # PDC stencil elements already on forms: replace text and settings in place
  specs = b['stencil_elements']
  located = lib[:locate_elements].call(scope, false)
  # The same string as it appears inside stored JSON: plain, or with < > &
  # escaped the way Rails' to_json writes them.
  encodings = lambda do |str|
    plain = JSON.generate(str)[1..-2]
    [plain, plain.gsub('&', '\u0026').gsub('<', '\u003c').gsub('>', '\u003e')].uniq
  end
  specs.each { |s| log['element missing from every form (add by hand)'] << s['id'] if Array(located[s['id']]).empty? }
  by_stencil = Hash.new { |h, k| h[k] = [] }
  located.each { |id, locs| locs.each { |l| by_stencil[l['stencil_id']] << l.merge('id' => id) } }
  by_stencil.each do |stencil_id, locs|
    st = Stencil.find(stencil_id)
    raw = st['json'].to_s
    doc = JSON.parse(raw)
    changes = []
    locs.group_by { |l| l['id'] }.each do |id, here|
      where = "#{id} @ stencil #{stencil_id} (#{st.name.to_s.strip})"
      if here.size > 1 || here.any? { |l| Array(l['also_matches']).any? }
        log['duplicate or ambiguous (fix by hand)'] << where
        next
      end
      spec = specs.find { |s| s['id'] == id }
      node = here.first['trail'].inject(doc) { |n, i| n['elements'][i] }
      text = lib[:element_text].call(node)
      if here.first['via'] == 'fingerprint' && ![lib[:sha].call(text), lib[:sha].call(CGI.unescapeHTML(text))].include?(spec['unmarked_sha256'])
        log['unmarked and edited (left alone; review, then replace by hand)'] << where
        next
      end
      text_ok = lib[:sha].call(text) == lib[:sha].call(spec['text'])
      bad = lib[:element_config_problems].call(node, required_config)
      if text_ok && bad.empty?
        log['ok'] << where
        next
      end
      changes << { 'node' => node, 'old' => text, 'new' => spec['text'], 'settings' => bad.any?,
                   'where' => "#{where} [#{[text_ok ? nil : 'text', *bad].compact.join(', ')}]" }
    end
    next if changes.empty?
    # Swap only each element's text inside the stored JSON when that's
    # unambiguous; otherwise (or to change settings) rewrite the document.
    new_raw = changes.any? { |c| c['settings'] } ? nil : raw.dup
    changes.each do |c|
      break if new_raw.nil?
      pair = encodings.call(c['old']).zip(encodings.call(c['new'])).find { |o, _| new_raw.scan(o).size == 1 }
      new_raw = pair && new_raw.sub(pair[0]) { pair[1] }
    end
    if new_raw.nil?
      changes.each do |c|
        cfg = c['node']['config']
        cfg['text'] = c['new']
        required_config.each { |k, want| cfg[k] = want ? true : '0' unless lib[:truthy].call(cfg[k]) == want }
      end
      new_raw = JSON.generate(doc, ascii_only: true)
    end
    check = lib[:stencil_elements].call(new_raw).map { |e| lib[:element_text].call(e['element']) }
    missing = changes.reject { |c| check.include?(c['new']) }
    raise "stencil #{stencil_id}: verification failed for #{missing.map { |c| c['where'] }.join('; ')}; nothing saved" if missing.any?
    lib[:write_stencil].call(st, new_raw)
    changes.each { |c| log['wrote element'] << c['where'] }
  end

  { 'mode' => "from #{lib[:repo_label].call(model)}" }
end

lib[:run_with_snapshots].call(model, 'Install', 'install_results', lib[:snapshot_targets].call(bundle), save_now, install)
