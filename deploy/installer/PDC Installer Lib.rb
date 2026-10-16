# PDC Installer Lib
#
# Shared helpers for the PDC deploy model's installer methods. Returns a Hash
# of lambdas, so every installer method starts with:
#
#   lib = model.dyn_invoke_for(:"PDC Installer Lib")
#
# READ-ONLY: nothing in here writes to Fluxx.
#
# The normalize/hash rules below MUST stay identical to the ones in
# deploy/tools/pdc_manifest.rb, or every body will report DIFFERS.

require 'json'
require 'digest'
require 'net/http'
require 'uri'
require 'cgi'
require 'time'
require 'zlib'
require 'base64'

lib = {}

# ---------------------------------------------------------------------------
# Normalizing and hashing
# ---------------------------------------------------------------------------

# CRLF vs LF and trailing whitespace are not meaningful drift for Ruby pasted
# through Fluxx's admin textareas. Blank counts as absent.
lib[:normalize] = lambda do |text|
  next nil if text.nil?
  out = text.to_s.gsub("\r\n", "\n").split("\n").map(&:rstrip).join("\n").strip
  out.empty? ? nil : out
end

lib[:sha] = lambda do |text|
  norm = lib[:normalize].call(text)
  norm && Digest::SHA256.hexdigest(norm)
end

# Stencil JSON is compared structurally: keys sorted, per-instance keys
# (scope "stencil_volatile_keys", e.g. element uids) dropped, and profile
# restrictions (scope "stencil_profile_keys") masked, because profile ids differ
# per instance. The admin's pdc_staff_profile choice is checked separately.
canon = nil
canon = lambda do |obj, volatile, masked|
  case obj
  when Hash
    obj.keys.sort.each_with_object({}) do |k, h|
      next if volatile.include?(k)
      h[k] = masked.include?(k) && !obj[k].nil? ? '<profile>' : canon.call(obj[k], volatile, masked)
    end
  when Array
    obj.map { |v| canon.call(v, volatile, masked) }
  else
    obj
  end
end

lib[:canonical_stencil] = lambda do |raw, volatile, masked = []|
  next nil if raw.nil? || raw.to_s.strip.empty?
  canon.call(JSON.parse(raw.to_s), volatile, masked)
end

# ascii_only: Fluxx's JSON escapes non-ASCII (e.g. \u2713) and plain Ruby
# doesn't, so force the escaped form on both sides.
lib[:stencil_sha] = lambda do |raw, volatile, masked = []|
  c = lib[:canonical_stencil].call(raw, volatile, masked)
  c && Digest::SHA256.hexdigest(JSON.generate(c, ascii_only: true))
end

# Every value of the profile-restriction keys in a stencil, e.g. ["974"].
profile_values = nil
profile_values = lambda do |obj, keys|
  case obj
  when Hash then obj.flat_map { |k, v| keys.include?(k) ? Array(v).map(&:to_s) : profile_values.call(v, keys) }
  when Array then obj.flat_map { |v| profile_values.call(v, keys) }
  else []
  end
end
lib[:stencil_profiles] = lambda do |raw, keys|
  doc = (JSON.parse(raw.to_s) rescue nil)
  doc ? profile_values.call(doc, keys).reject(&:empty?).uniq : []
end

# The ###PDC_CODE###...###END_PDC_CODE### slice of a shared hook, markers
# included. nil when the markers aren't there.
lib[:code_slice] = lambda do |text, markers|
  src = text.to_s
  from = src.index(markers['code_start'])
  to = src.index(markers['code_end'])
  next nil if from.nil? || to.nil? || to < from
  src[from...(to + markers['code_end'].length)]
end

# ---------------------------------------------------------------------------
# Reading the public repo
# ---------------------------------------------------------------------------

lib[:repo_ref] = lambda do |deploy_model|
  ref = deploy_model.respond_to?(:repo_ref) ? deploy_model.repo_ref.to_s.strip : ''
  ref.empty? ? 'main' : ref
end

lib[:raw_url] = lambda do |repo_url, ref, path|
  m = repo_url.to_s.strip.match(%r{github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?/?\z})
  raise "repo_url must be a github.com repository URL, got #{repo_url.inspect}" unless m
  encoded = path.split('/').map { |p| CGI.escape(p).gsub('+', '%20') }.join('/')
  "https://raw.githubusercontent.com/#{m[1]}/#{m[2]}/#{ref}/#{encoded}"
end

lib[:fetch_repo_file] = lambda do |deploy_model, path|
  ref = lib[:repo_ref].call(deploy_model)
  uri = URI.parse(lib[:raw_url].call(deploy_model.repo_url, ref, path))
  resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    http.request(Net::HTTP::Get.new(uri))
  end
  unless resp.code == '200'
    raise "Could not fetch #{path} at ref '#{ref}' from #{deploy_model.repo_url} (HTTP #{resp.code}). Check repo_url and repo_ref."
  end
  resp.body.to_s.dup.force_encoding('UTF-8')
end

lib[:fetch_repo_json] = lambda do |deploy_model, path|
  JSON.parse(lib[:fetch_repo_file].call(deploy_model, path))
end

# ---------------------------------------------------------------------------
# Stencil element trees
# ---------------------------------------------------------------------------

# Flattens a stencil's element tree (groups nest their children under
# "elements"). Each entry keeps its index trail and its ancestor group labels.
flatten = nil
flatten = lambda do |elements, trail, parents|
  out = []
  Array(elements).each_with_index do |el, i|
    next unless el.is_a?(Hash)
    here = trail + [i]
    out << { 'element' => el, 'trail' => here, 'parents' => parents }
    if el['elements'].is_a?(Array)
      cfg = el['config'].is_a?(Hash) ? el['config'] : {}
      label = cfg['label'] || cfg['title'] || cfg['name'] || el['type']
      out.concat(flatten.call(el['elements'], here, parents + [label.to_s]))
    end
  end
  out
end

lib[:stencil_elements] = lambda do |raw_json|
  doc = begin
    JSON.parse(raw_json.to_s)
  rescue JSON::ParserError
    nil
  end
  doc.is_a?(Hash) ? flatten.call(doc['elements'], [], []) : []
end

# Element text as stored. TRN (2026-10-16) showed the database keeps it as
# typed (entities like &#10003; and "&amp;" inside JS survive), while older
# REST reads looked entity-encoded. So comparisons accept either the raw text
# or its HTML-decoded form.
lib[:element_text] = lambda do |el|
  cfg = el['config'].is_a?(Hash) ? el['config'] : {}
  cfg['text'].is_a?(String) ? cfg['text'] : nil
end

lib[:form_types] = lambda do |stencil|
  ft = stencil.form_type
  ft.is_a?(Array) ? ft.map(&:to_s) : ft.to_s.split(/[,\s]+/)
end

# Finds every PDC element in host stencils: first by its PDC:ELEMENT marker,
# otherwise by the scope's include/exclude fingerprints. Returns
# { element_id => [location, ...] }.
lib[:locate_elements] = lambda do |scope, include_text = false|
  specs = scope['stencil_elements']
  marker_re = Regexp.new(scope['markers']['element_regex'])
  hosts = specs.flat_map { |s| s['host_model_types'] }.uniq
  # Prefilter in SQL on plain tokens; text with < or quotes is stored escaped.
  tokens = ['PDC:ELEMENT'] + specs.flat_map { |s| s['include'] }.select { |t| t =~ /\A[\w-]+\z/ }.uniq
  conn = Stencil.connection
  like = tokens.map { |t| "json LIKE #{conn.quote('%' + t + '%')}" }.join(' OR ')

  found = Hash.new { |h, k| h[k] = [] }
  Stencil.where(model_type: hosts, deleted_at: nil).where(like).each do |st|
    lib[:stencil_elements].call(st['json']).each do |entry|
      text = lib[:element_text].call(entry['element'])
      next if text.nil?
      decoded = CGI.unescapeHTML(text)
      m = text.match(marker_re) || decoded.match(marker_re)
      ids =
        if m
          [m[1]]
        else
          specs.select do |s|
            s['host_model_types'].include?(st.model_type) &&
              [text, decoded].any? do |t|
                s['include'].all? { |f| t.include?(f) } && s['exclude'].none? { |f| t.include?(f) }
              end
          end.map { |s| s['id'] }
        end
      ids.each do |id|
        found[id] << {
          'stencil_id' => st.id,
          'stencil_name' => st.name,
          'model_type' => st.model_type,
          'model_theme_id' => st.model_theme_id,
          'enabled' => st.enabled ? true : false,
          'via' => m ? 'marker' : 'fingerprint',
          'also_matches' => ids - [id],
          'trail' => entry['trail'],
          'parent_groups' => entry['parents'],
          'sha256' => lib[:sha].call(text),
          'sha256_decoded' => lib[:sha].call(decoded)
        }.merge(include_text ? { 'text' => text } : {})
      end
    end
  end
  found
end

# ---------------------------------------------------------------------------
# Live snapshot
# ---------------------------------------------------------------------------

# Collects every in-scope PDC record in the same shape as
# deploy/pdc-manifest.json. Each code body becomes "<field>_sha256"; with
# include_bodies it also carries the normalized "<field>" text (for export).
lib[:collect] = lambda do |scope, include_bodies|
  volatile = scope['stencil_volatile_keys'] || []
  masked = scope['stencil_profile_keys'] || []
  owned = scope['owned_model_types'].keys
  gr = scope['grant_request']
  excluded = (scope['excluded_method_patterns'] || []).map { |p| Regexp.new(p) }
  secrets = scope['secret_methods'] || []
  runtime = scope['runtime_option_attributes'] || []
  live = Hash.new { |h, k| h[k] = [] }

  add_body = lambda do |entry, field, text|
    entry["#{field}_sha256"] = lib[:sha].call(text)
    entry[field] = lib[:normalize].call(text) if include_bodies && entry["#{field}_sha256"]
  end
  state_names = {}
  # A button can point at a soft-deleted state; name it so the button reports DIFFERS.
  state_name = lambda do |id|
    state_names[id] ||=
      if (s = MachineState.find_by(id: id)).nil? then "missing-state-#{id}"
      elsif s.respond_to?(:deleted_at) && s.deleted_at.present? then "#{s.name} (deleted)"
      else s.name
      end
  end

  # Models
  MachineModelType.where(model_type: owned, deleted_at: nil).each do |mt|
    live['models'] << { 'key' => mt.model_type, 'model_type' => mt.model_type, 'name' => mt.name,
                        'show_in_plus_menu' => mt.show_in_plus_menu ? true : false }
  end

  # Profile permissions on owned models (e.g. Grantee may view/update their own
  # Consent). Which profile holds them is instance-specific, so only the
  # permission itself is compared; profile names are reported.
  UserProfileRule.where(model_type: owned).to_a.group_by { |r| [r.model_type, r.permission_name] }.each do |(mt, perm), rules|
    live['permissions'] << {
      'key' => "#{mt}:#{perm}", 'model_type' => mt, 'permission_name' => perm,
      'allowed' => rules.any? { |r| r.allowed },
      'profiles' => rules.map { |r| (UserProfile.find_by(id: r.user_profile_id)&.name rescue nil) || r.user_profile_id.to_s }.sort
    }
  end

  # Attributes and static dropdown options (ModelAttributeValue).
  # ModelAttributeChoice is per-record data and is never read here.
  ModelAttribute.where(deleted_at: nil)
                .where('model_type IN (?) OR (model_type = ? AND name IN (?))', owned, gr['model_type'], gr['attributes'])
                .each do |a|
    key = "#{a.model_type}.#{a.name}"
    e = {
      'key' => key, 'model_type' => a.model_type, 'name' => a.name, 'description' => a.description,
      'attribute_type' => a.attribute_type, 'multi_allowed' => a.multi_allowed ? true : false,
      'value_model_type' => a.value_model_type
    }
    if a.attribute_type == 'multi_value'
      e['options'] =
        if runtime.include?(key)
          'runtime'
        else
          ModelAttributeValue.where(model_attribute_id: a.id, deleted_at: nil).order(:display_order, :id).map do |v|
            { 'value' => v.value, 'description' => v.description, 'display_order' => v.display_order, 'retired' => v.retired ? true : false }
          end
        end
    end
    live['attributes'] << e
  end

  # Methods: everything on owned models, plus GrantRequest methods with a PDC prefix
  ModelMethod.where(model_type: owned + [gr['model_type']], deleted_at: nil).each do |mm|
    next if mm.model_type == gr['model_type'] && gr['method_prefixes'].none? { |p| mm.name.start_with?(p) }
    next if excluded.any? { |re| mm.name =~ re }
    e = { 'key' => "#{mm.model_type}##{mm.name}", 'model_type' => mm.model_type, 'name' => mm.name, 'method_type' => mm.method_type }
    if secrets.include?(mm.name)
      e['secret'] = true
    else
      add_body.call(e, 'body', mm.unsafe_dyn_method)
    end
    live['methods'] << e
  end

  # Themes -> workflows -> events
  ModelTheme.where(model_type: owned, deleted_at: nil).each do |t|
    # Portable theme settings only; ids (user_profile_ids, program_id, ...) differ per instance.
    e = { 'key' => "#{t.model_type}/#{t.name}", 'model_type' => t.model_type, 'name' => t.name, 'label' => t.label }
    %w[external_access_enabled limit_by_user_profile_flag hide_from_theme_switching request_may_be_grantee_user_only].each do |col|
      e[col] = t[col] ? true : false if t.has_attribute?(col)
    end
    add_body.call(e, 'before_new', t.unsafe_before_new_block)
    add_body.call(e, 'after_create', t.unsafe_after_create_block)
    live['themes'] << e

    MachineWorkflow.where(model_theme_id: t.id, deleted_at: nil).each do |w|
      live['workflows'] << { 'key' => "#{t.model_type}/#{t.name}", 'model_type' => t.model_type, 'theme' => t.name, 'name' => w.name }

      MachineEvent.where(machine_workflow_id: w.id, deleted_at: nil).each do |ev|
        ee = {
          'key' => "#{t.model_type}/#{t.name}>#{ev.button_name}", 'model_type' => t.model_type, 'theme' => t.name,
          'button_name' => ev.button_name, 'name' => ev.name, 'to_state' => state_name.call(ev.to_state_id),
          'from_states' => MachineEventFromState.where(machine_event_id: ev.id)
                                                .map { |f| [state_name.call(f.from_state_id), f.button_order] }
                                                .sort_by { |pair| pair[0].to_s },
          'is_validation_suppressed' => ev.is_validation_suppressed ? true : false,
          'guard_strategy' => ev.guard_strategy, 'filter' => ev.filter
        }
        add_body.call(ee, 'guard', ev.unsafe_guard)
        # Roles are the admin's choice per instance; reported, never part of the manifest.
        ee['roles'] = MachineEventRole.where(machine_event_id: ev.id).map do |r|
          (role = Role.find_by(id: r.role_id)) ? role.name : "missing-role-#{r.role_id}"
        end.sort
        live['events'] << ee
      end
    end
  end

  # States (one row per model type, shared by every theme)
  MachineState.where(model_type: owned, deleted_at: nil).each do |s|
    e = {
      'key' => "#{s.model_type}:#{s.name}", 'model_type' => s.model_type, 'name' => s.name,
      'description' => s.description, 'state_type' => s.state_type, 'state_order' => s.state_order,
      'allowed_roles' => s.allowed_roles
    }
    add_body.call(e, 'before_validation_enter', s.unsafe_before_validation_enter)
    add_body.call(e, 'after_enter', s.unsafe_after_enter)
    live['states'] << e
  end

  # Owned stencils: each owned model's form/list/show stencil (identical
  # copies left behind by imports are ignored)
  owned.each do |mt|
    cands = Stencil.where(model_type: mt, deleted_at: nil).to_a.select { |st| lib[:form_types].call(st).include?('form') }
    next if cands.empty?
    primary = cands.max_by { |st| [st.compiled ? 1 : 0, st.updated_at.to_i] }
    if cands.map { |st| lib[:stencil_sha].call(st['json'], volatile, masked) }.uniq.size > 1
      live['warnings'] << "#{cands.size} form stencils for #{mt} with different content (ids #{cands.map(&:id).join(', ')}); compared #{primary.id}"
    end
    e = { 'key' => "#{mt}:form", 'model_type' => mt, 'name' => primary.name }
    e['json_sha256'] = lib[:stencil_sha].call(primary['json'], volatile, masked)
    # Raw JSON for export (the repo keeps real profile ids for reference); masked for hashing.
    e['json'] = JSON.parse(primary['json']) if include_bodies
    e['profiles'] = lib[:stencil_profiles].call(primary['json'], masked).map do |id|
      (UserProfile.find_by(id: id.to_i)&.name rescue nil) || id
    end
    live['stencils'] << e
  end
  # Shared GrantRequest hooks: only the marker slice is PDC's
  gr['shared_state_hooks'].each do |h|
    st = MachineState.where(model_type: gr['model_type'], name: h['state'], deleted_at: nil).first
    next if st.nil?
    e = { 'key' => "#{gr['model_type']}:#{h['state']}:#{h['field']}", 'model_type' => gr['model_type'], 'state' => h['state'], 'field' => h['field'] }
    slice = lib[:code_slice].call(st[h['field']], scope['markers'])
    if slice
      add_body.call(e, 'body', slice)
    else
      e['marker_found'] = false
    end
    live['shared_slices'] << e
  end

  # Stencil elements inside stencils PDC doesn't own
  located = lib[:locate_elements].call(scope, include_bodies)
  scope['stencil_elements'].each do |spec|
    live['stencil_elements'] << { 'key' => spec['id'], 'id' => spec['id'], 'locations' => located[spec['id']] }
  end

  live
end

# ---------------------------------------------------------------------------
# Comparing manifest vs live
# ---------------------------------------------------------------------------

# Manifest keys that are bookkeeping, not something to compare.
skip_key = lambda do |k|
  %w[key secret roles profiles locations marker_found].include?(k) || k.end_with?('_path')
end

short = lambda do |v|
  s = v.is_a?(String) ? v : JSON.generate(v)
  s.length > 160 ? "#{s[0, 160]}..." : s
end

lib[:selected_role_name] = lambda do |deploy_model|
  next nil unless deploy_model.respond_to?(:pdc_event_role)
  v = deploy_model.pdc_event_role
  v = v.first if v.is_a?(Array)
  next nil if v.blank?
  r = Role.find_by(id: v.to_s.to_i) if v.to_s =~ /\A\d+\z/
  r ||= Role.find_by(name: v.to_s)
  r ? r.name : v.to_s
end

# The deploy model's dropdown choice for a UserProfile, as a profile name.
lib[:selected_profile_name] = lambda do |deploy_model, attr|
  next nil unless deploy_model.respond_to?(attr)
  v = deploy_model.public_send(attr)
  v = v.first if v.is_a?(Array)
  next nil if v.blank?
  p = UserProfile.find_by(id: v.to_s.to_i) if v.to_s =~ /\A\d+\z/
  p ||= UserProfile.find_by(name: v.to_s)
  p ? p.name : v.to_s
end

# Returns report rows: { kind, key, status, detail }.
# Statuses: MATCH, DIFFERS, MISSING, EXTRA, SKIPPED_SECRET, MARKER_NOT_FOUND,
# MISSING_ROLE, ROLE_DIFFERS, PROFILE_DIFFERS, UNMARKED, UNMARKED_DIFFERS,
# AMBIGUOUS, DUPLICATE.
lib[:validate] = lambda do |manifest, live, deploy_model|
  rows = []
  row = lambda { |kind, key, status, detail = nil| rows << { 'kind' => kind, 'key' => key, 'status' => status, 'detail' => detail }.compact }
  wanted_role = lib[:selected_role_name].call(deploy_model)
  wanted_grantee = lib[:selected_profile_name].call(deploy_model, :pdc_grantee_profile)
  wanted_staff = lib[:selected_profile_name].call(deploy_model, :pdc_staff_profile)

  %w[models permissions attributes methods themes states workflows events stencils shared_slices].each do |kind|
    by_key = {}
    Array(live[kind]).each { |l| by_key[l['key']] = JSON.parse(JSON.generate(l)) }
    seen = {}

    Array(manifest[kind]).each do |m|
      key = m['key']
      seen[key] = true
      l = by_key[key]
      if l.nil?
        row.call(kind, key, 'MISSING')
        next
      end
      if m['secret']
        row.call(kind, key, 'SKIPPED_SECRET')
        next
      end
      if l['marker_found'] == false
        row.call(kind, key, 'MARKER_NOT_FOUND')
        next
      end

      diffs = m.keys.reject { |k| skip_key.call(k) }.reject { |k| m[k] == l[k] }.map do |k|
        k.end_with?('_sha256') ? k.sub(/_sha256\z/, '') : "#{k}: expected #{short.call(m[k])}, found #{short.call(l[k])}"
      end
      diffs.empty? ? row.call(kind, key, 'MATCH') : row.call(kind, key, 'DIFFERS', diffs)

      if kind == 'permissions' && wanted_grantee && !Array(l['profiles']).include?(wanted_grantee)
        row.call(kind, key, 'PROFILE_DIFFERS', ["expected #{wanted_grantee}, found #{Array(l['profiles']).join(', ')}"])
      end
      if kind == 'stencils' && wanted_staff && Array(l['profiles']).any? && Array(l['profiles']) != [wanted_staff]
        row.call(kind, key, 'PROFILE_DIFFERS', ["restricted to #{Array(l['profiles']).join(', ')}, expected #{wanted_staff}"])
      end
      if kind == 'events'
        roles = Array(l['roles'])
        if roles.empty?
          row.call(kind, key, 'MISSING_ROLE', wanted_role ? ["expected #{wanted_role}"] : nil)
        elsif wanted_role && !roles.include?(wanted_role)
          row.call(kind, key, 'ROLE_DIFFERS', ["expected #{wanted_role}, found #{roles.join(', ')}"])
        end
      end
    end

    next if kind == 'shared_slices'
    by_key.each_key { |key| row.call(kind, key, 'EXTRA') unless seen[key] }
  end

  live_elements = {}
  Array(live['stencil_elements']).each { |l| live_elements[l['key']] = l }
  Array(manifest['stencil_elements']).each do |m|
    locs = Array((live_elements[m['key']] || {})['locations'])
    if locs.empty?
      row.call('stencil_elements', m['key'], 'MISSING')
      next
    end
    locs.group_by { |loc| loc['stencil_id'] }.each do |stencil_id, here|
      where = "#{m['key']} @ stencil #{stencil_id} (#{here.first['stencil_name']})"
      groups = here.map { |loc| loc['parent_groups'] }.uniq
      if here.any? { |loc| Array(loc['also_matches']).any? }
        row.call('stencil_elements', where, 'AMBIGUOUS', here.map { |loc| "trail #{loc['trail'].inspect} also looks like #{loc['also_matches'].join(', ')}" })
      elsif here.size > 1
        row.call('stencil_elements', where, 'DUPLICATE', here.map { |loc| "copy at trail #{loc['trail'].inspect} in groups: #{loc['parent_groups'].join(' > ')}" })
      elsif here.first['via'] == 'fingerprint'
        # No marker yet, but the content can still be compared with the repo
        # copy minus its marker line.
        same = m['unmarked_sha256'] && [here.first['sha256'], here.first['sha256_decoded']].include?(m['unmarked_sha256'])
        row.call('stencil_elements', where, same ? 'UNMARKED' : 'UNMARKED_DIFFERS',
                 ["#{same ? 'content matches the repo' : 'content differs from the repo'}; groups: #{groups.first.join(' > ')}"])
      elsif [here.first['sha256'], here.first['sha256_decoded']].include?(m['sha256'])
        row.call('stencil_elements', where, 'MATCH')
      else
        row.call('stencil_elements', where, 'DIFFERS', ['body'])
      end
    end
  end

  rows
end

# Exports travel through Fluxx's console, which collapses runs of spaces and
# re-escapes quotes and newlines. A single deflated base64 line survives that
# untouched; deploy/tools/pdc_manifest.rb unpacks it.
lib[:pack_export] = lambda do |data|
  'PDCEXPORT1:' + Base64.strict_encode64(Zlib::Deflate.deflate(JSON.generate(data), Zlib::BEST_COMPRESSION))
end

lib[:summarize] = lambda do |rows, meta|
  counts = Hash.new(0)
  rows.each { |r| counts[r['status']] += 1 }
  meta.merge('summary' => counts, 'problems' => rows.reject { |r| r['status'] == 'MATCH' })
end

lib
