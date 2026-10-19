# PDC Restore Previous
#
# The Restore Previous button on the deploy model. Puts every PDC component
# back the way previous_configuration recorded it (the snapshot Install,
# Uninstall or an earlier Restore took before changing anything):
#   - a component that existed then gets its code and settings back, and is
#     un-deleted if it was soft-deleted since (same id, so saved answers and
#     links keep working); one that was hard-deleted is recreated
#   - a component that didn't exist then is soft-deleted
#   - forms that held PDC elements get their saved JSON back
#   - buttons get their target, from-states and roles back
# Needs no repo access. Restore takes its own snapshot first, so clicking it
# again undoes the restore. Results go to restore_results.

require 'json'
require 'time'

lib = model.dyn_invoke_for(:"PDC Installer Lib") unless defined?(lib) && lib
save_now = defined?(pdc_one_off) && pdc_one_off ? true : false

previous = (lib[:read_snapshot].call(model, 'previous_configuration') rescue nil)
targets = previous ? previous['records'].map { |r| r.slice('table', 'key', 'find', 'secret', 'cols_only', 'only_cols') } : []

restore = lambda do |log|
  raise 'There is no previous configuration to restore yet' if previous.nil?
  now = Time.now
  # Records in dependency order, so fields exist before their options and
  # states before the buttons that point at them.
  previous['records'].each do |r|
    key = r['key']
    klass = lib[:snapshot_class].call(r['table'])
    cols = r['cols'] || {}

    if r['table'] == 'Stencil'
      st = Stencil.find_by(id: r['find']['id'])
      if st.nil? || r['id'].nil?
        log['review: form not found'] << key
      elsif st['json'].to_s == cols['json'].to_s
        log['ok'] << key
      else
        st['json'] = cols['json']
        st.save!
        log['restored form'] << key
      end
      next
    end

    if r['cols_only']
      rec = lib[:snapshot_find].call(r, true)
      if rec.nil? || r['id'].nil?
        log['review: not found'] << key
        next
      end
      changed = cols.reject { |c, v| rec[c] == v }.keys
      if changed.empty?
        log['ok'] << key
      else
        changed.each { |c| rec[c] = cols[c] }
        rec.save!
        log['restored'] << "#{key} [#{changed.join(', ')}]"
      end
      next
    end

    live = lib[:snapshot_find].call(r, true)
    if r['id'].nil?
      # Didn't exist before
      if live
        live.deleted_at = now
        live.save!
        log['removed (was not there before)'] << key
      else
        log['ok'] << key
      end
      next
    end

    rec = klass.find_by(id: r['id'])
    changed = []
    if rec.nil?
      if r['deleted']
        log['ok'] << key
        next
      end
      if r['secret']
        log['review: secret method was hard-deleted; re-enter it by hand'] << key
        next
      end
      scope = lib[:snapshot_scope].call(r)
      if scope.nil?
        log['review: could not recreate, its field or workflow is missing'] << key
        next
      end
      attrs = scope.where_values_hash.merge(cols)
      rec = klass.new(attrs)
      rec.save!
      changed = ['recreated']
      log['recreated'] << key
    else
      if live && live.id != rec.id && !r['deleted']
        live.deleted_at = now
        live.save!
        log['removed (duplicate of the restored one)'] << "#{key} (id #{live.id})"
      end
      changed = cols.reject { |c, v| rec[c] == v }.keys
      was_deleted = rec.deleted_at.present?
      changed << (r['deleted'] ? 'deleted' : 'un-deleted') if was_deleted != (r['deleted'] ? true : false)
      if changed.empty?
        log['ok'] << key unless r['table'] == 'MachineEvent'
      else
        cols.each { |c, v| rec[c] = v }
        rec.deleted_at = r['deleted'] ? (rec.deleted_at || Time.parse(r['deleted_at'])) : nil
        rec.save!
        log['restored'] << "#{key} [#{changed.join(', ')}]"
      end
    end

    # Buttons: target, from-states and roles, by state name
    next unless r['table'] == 'MachineEvent' && r['links'] && !r['deleted']
    mt = r['find']['model_type']
    # The same state row if it still exists (deleted or not), else by name
    sid = lambda do |name, id|
      id && MachineState.where(id: id).exists? ? id : MachineState.where(model_type: mt, name: name, deleted_at: nil).first&.id
    end
    links = r['links']
    fixed = []
    to_id = sid.call(links['to_state'], links['to_state_id'])
    if to_id && rec.to_state_id != to_id
      rec.to_state_id = to_id
      rec.save!
      fixed << 'target'
    end
    want_from = links['from'].map { |name, order, id| [sid.call(name, id), order] }.reject { |id, _| id.nil? }.sort
    have_from = MachineEventFromState.where(machine_event_id: rec.id).map { |f| [f.from_state_id, f.button_order] }.sort
    if have_from != want_from
      MachineEventFromState.where(machine_event_id: rec.id).destroy_all
      want_from.each { |id, order| MachineEventFromState.create!(machine_event_id: rec.id, from_state_id: id, button_order: order) }
      fixed << 'from-states'
    end
    have_roles = MachineEventRole.where(machine_event_id: rec.id).pluck(:role_id).sort
    if have_roles != links['roles']
      MachineEventRole.where(machine_event_id: rec.id).destroy_all
      links['roles'].each { |rid| MachineEventRole.create!(machine_event_id: rec.id, role_id: rid) }
      fixed << 'roles'
    end
    fixed.empty? ? (log['ok'] << key if changed.empty?) : log['restored'] << "#{key} [#{fixed.join(', ')}]"
  end

  { 'mode' => "back to #{previous['label']} (#{previous['taken_at']})" }
end

lib[:run_with_snapshots].call(model, 'Restore Previous', 'restore_results', targets, save_now, restore)
