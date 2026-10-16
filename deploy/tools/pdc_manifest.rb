#!/usr/bin/env ruby
# Builds and checks deploy/pdc-manifest.json. Plain Ruby, no gems.
#
#   ruby deploy/tools/pdc_manifest.rb unpack EXPORT.json [--take ID[@STENCIL_ID] ...]
#       Writes the bodies from a PDC_Export_Components export into the repo,
#       then regenerates deploy/pdc-manifest.json from the repo files.
#       Stencil-element files normally win over Fluxx; --take replaces one with
#       Fluxx's copy (marker added). Add @STENCIL_ID when Fluxx has different
#       copies in different stencils.
#   ruby deploy/tools/pdc_manifest.rb rehash
#       Recomputes every hash in the manifest from the repo files (run after
#       editing a body by hand).
#   ruby deploy/tools/pdc_manifest.rb check
#       Fails if any manifest hash is stale, a referenced file is missing, or
#       a data-explorer file doesn't match its own marker/fingerprints.
#
# The normalize/hash rules MUST stay identical to deploy/installer/PDC
# Installer Lib.rb, or every body will report DIFFERS in Fluxx.

require 'json'
require 'digest'
require 'fileutils'
require 'zlib'
require 'base64'

ROOT = File.expand_path('../..', __dir__)
SCOPE_PATH = File.join(ROOT, 'deploy/pdc-scope.json')
MANIFEST_PATH = File.join(ROOT, 'deploy/pdc-manifest.json')

# Body fields per manifest section. Stencil "json" is hashed structurally.
BODY_FIELDS = {
  'methods' => %w[body],
  'themes' => %w[before_new after_create],
  'states' => %w[before_validation_enter after_enter],
  'events' => %w[guard],
  'stencils' => %w[json],
  'shared_slices' => %w[body]
}.freeze
SECTIONS = %w[models permissions attributes methods themes states workflows events stencils shared_slices stencil_elements].freeze

def normalize(text)
  return nil if text.nil?
  out = text.to_s.gsub("\r\n", "\n").split("\n").map(&:rstrip).join("\n").strip
  out.empty? ? nil : out
end

def sha(text)
  norm = normalize(text)
  norm && Digest::SHA256.hexdigest(norm)
end

def canon(obj, volatile, masked = [])
  case obj
  when Hash
    obj.keys.sort.each_with_object({}) do |k, h|
      next if volatile.include?(k)
      h[k] = masked.include?(k) && !obj[k].nil? ? '<profile>' : canon(obj[k], volatile, masked)
    end
  when Array
    obj.map { |v| canon(v, volatile, masked) }
  else
    obj
  end
end

def stencil_sha(raw, volatile, masked = [])
  return nil if raw.nil? || raw.strip.empty?
  Digest::SHA256.hexdigest(JSON.generate(canon(JSON.parse(raw), volatile, masked), ascii_only: true))
end

def scope
  @scope ||= JSON.parse(File.read(SCOPE_PATH, encoding: "UTF-8"))
end

def safe_name(name)
  name.to_s.gsub(%r{[/\\:*?"<>|]}, '-').strip
end

def folder_for(model_type)
  owned = scope['owned_model_types'][model_type]
  return owned['folder'] if owned
  return scope['grant_request']['folder'] if model_type == scope['grant_request']['model_type']
  raise "No repo folder for model type #{model_type}"
end

# Repo path for one body field of one manifest entry.
def body_path(section, entry, field)
  case section
  when 'methods'
    "#{folder_for(entry['model_type'])}/#{entry['name']}.rb"
  when 'themes'
    "#{folder_for(entry['model_type'])}/#{field == 'before_new' ? 'Before New' : 'After Create'}.rb"
  when 'states'
    "#{folder_for(entry['model_type'])}/states/#{safe_name(entry['name'])}.#{field}.rb"
  when 'events'
    "#{folder_for(entry['model_type'])}/events/#{safe_name(entry['button_name'])}.#{field}.rb"
  when 'stencils'
    "#{folder_for(entry['model_type'])}/stencils/form.json"
  when 'shared_slices'
    hook = scope['grant_request']['shared_state_hooks'].find { |h| h['state'] == entry['state'] && h['field'] == entry['field'] }
    raise "No repo path for shared hook #{entry['key']}" unless hook
    hook['path']
  end
end

def read_repo(path)
  full = File.join(ROOT, path)
  File.exist?(full) ? File.read(full, encoding: "UTF-8") : nil
end

def hash_for(section, field, path)
  text = read_repo(path)
  return nil if text.nil?
  section == 'stencils' && field == 'json' ? stencil_sha(text, scope['stencil_volatile_keys'] || [], scope['stencil_profile_keys'] || []) : sha(text)
end

# Recomputes every *_sha256 from the *_path it sits next to. Returns
# a list of problems (missing files).
def rehash!(manifest)
  problems = []
  (manifest.keys & SECTIONS).each do |section|
    manifest[section].each do |entry|
      if section == 'stencil_elements'
        entry['sha256'] = sha(read_repo(entry['path']))
        problems << "#{entry['path']} is missing" if entry['sha256'].nil?
        next
      end
      entry.keys.grep(/_path\z/).each do |path_key|
        field = path_key.sub(/_path\z/, '')
        entry["#{field}_sha256"] = hash_for(section, field, entry[path_key])
        problems << "#{entry[path_key]} is missing" if entry["#{field}_sha256"].nil?
      end
    end
  end
  problems
end

def write_repo(path, text)
  full = File.join(ROOT, path)
  FileUtils.mkdir_p(File.dirname(full))
  File.write(full, text.end_with?("\n") ? text : "#{text}\n")
end

# Accepts the packed "PDCEXPORT1:<base64 deflate>" line (tolerating console
# noise around it, like quotes or `result = `) or plain JSON.
def read_export(path)
  raw = File.read(path, encoding: 'UTF-8')
  packed = raw[/PDCEXPORT1:([A-Za-z0-9+\/=\s]+)/, 1]
  return JSON.parse(raw) unless packed
  JSON.parse(Zlib::Inflate.inflate(Base64.decode64(packed.gsub(/\s+/, ''))).force_encoding('UTF-8'))
end

# Fluxx's copy of one element as the new repo text, marker line first.
def taken_element_text(live_elements, spec, stencil_id, marker_re)
  locs = Array((live_elements[spec['id']] || {})['locations'])
  locs = locs.select { |l| l['stencil_id'].to_s == stencil_id.to_s } if stencil_id
  texts = locs.map { |l| l['text'] }.compact.uniq
  abort "--take #{spec['id']}: not found in the export" if texts.empty?
  if texts.size > 1
    abort "--take #{spec['id']}: Fluxx has #{texts.size} different copies; pick one with " +
          locs.map { |l| "#{spec['id']}@#{l['stencil_id']} (#{l['stencil_name'].to_s.strip})" }.uniq.join(' or ')
  end
  text = texts.first
  text =~ marker_re ? text : "<!-- PDC:ELEMENT id=#{spec['id']} -->\n#{text}"
end

def unpack(export_path, takes = [])
  export = read_export(export_path)
  abort "Export reports an error: #{export['error']}" if export['error']
  live = export['live'] or abort 'Not a PDC_Export_Components export (no "live" key)'
  # Exports from before permissions were collected carry them in extras.
  if live['permissions'].nil? && (rules = (export['extras'] || {})['user_profile_rules_for_pdc']).is_a?(Array)
    live['permissions'] = rules.group_by { |r| [r['model_type'], r['permission_name']] }.map do |(mt, perm), rs|
      { 'key' => "#{mt}:#{perm}", 'model_type' => mt, 'permission_name' => perm,
        'allowed' => rs.any? { |r| r['allowed'] == true || r['allowed'] == 1 } }
    end
  end

  manifest = {
    '_comment' => 'Generated by deploy/tools/pdc_manifest.rb from a PDC_Export_Components export. Do not edit by hand; edit the repo files and run `rehash`.',
    'format' => 1,
    'source' => { 'exported_at' => export['exported_at'], 'deploy_model' => export['deploy_model'], 'ref' => export['ref'] },
    'scope' => scope
  }
  cross_check = []

  SECTIONS.each do |section|
    if section == 'stencil_elements'
      # Repo files are authoritative for elements (they carry the markers).
      # An element with no repo file yet is seeded from the export, marker added.
      marker_re = Regexp.new(scope['markers']['element_regex'])
      live_elements = Array(live['stencil_elements']).map { |e| [e['id'], e] }.to_h
      takes.each do |take|
        id, stencil_id = take.split('@', 2)
        spec = scope['stencil_elements'].find { |e| e['id'] == id } or abort "--take #{id}: unknown element id"
        write_repo(spec['path'], taken_element_text(live_elements, spec, stencil_id, marker_re))
        puts "Took #{spec['path']} from Fluxx#{stencil_id ? " (stencil #{stencil_id})" : ''}"
      end
      scope['stencil_elements'].each do |spec|
        next if read_repo(spec['path'])
        texts = Array((live_elements[spec['id']] || {})['locations']).map { |l| l['text'] }.compact.uniq
        next if texts.empty?
        puts "WARNING: #{spec['id']} has #{texts.size} different copies in Fluxx; seeded from the first" if texts.size > 1
        text = texts.first
        text = "<!-- PDC:ELEMENT id=#{spec['id']} -->\n#{text}" unless text =~ marker_re
        write_repo(spec['path'], text)
        puts "Seeded #{spec['path']} from Fluxx"
      end
      manifest[section] = scope['stencil_elements'].map do |spec|
        { 'key' => spec['id'], 'id' => spec['id'], 'path' => spec['path'], 'host_model_types' => spec['host_model_types'] }
      end
      next
    end

    manifest[section] = Array(live[section]).sort_by { |e| e['key'] }.map do |live_entry|
      entry = live_entry.reject { |k, _| %w[roles profiles marker_found].include?(k) }
      Array(BODY_FIELDS[section]).each do |field|
        body = entry.delete(field)
        exported_sha = entry["#{field}_sha256"]
        if section == 'methods' && entry['secret']
          next # repo keeps a placeholder; never compared
        end
        if body.nil? && !(section == 'shared_slices' && live_entry['marker_found'] == false)
          next # empty in Fluxx: no file, sha stays null
        end
        path = body_path(section, entry, field)
        entry["#{field}_path"] = path
        # Leave the repo file alone when it already hashes the same (avoids
        # whitespace-only churn).
        if !body.nil? && hash_for(section, field, path) != exported_sha
          write_repo(path, field == 'json' ? JSON.pretty_generate(body) : body)
          local_sha = hash_for(section, field, path)
          cross_check << "#{section} #{entry['key']} #{field}: Fluxx #{exported_sha} vs local #{local_sha}" if local_sha != exported_sha
        end
      end
      entry
    end
  end

  problems = rehash!(manifest)
  File.write(MANIFEST_PATH, JSON.pretty_generate(manifest) + "\n")
  puts "Wrote #{MANIFEST_PATH}"
  SECTIONS.each { |s| puts format('  %-17s %d', s, manifest[s].size) }
  unless cross_check.empty?
    puts "\nHASH CROSS-CHECK FAILED: Fluxx and this tool hash the same text differently."
    puts '  Fix the normalize/canon rules before trusting validation:'
    cross_check.each { |c| puts "  #{c}" }
  end
  problems.each { |p| puts "WARNING: #{p}" }
  puts 'Review `git status` / `git diff`: bodies from Fluxx overwrote repo files where they differed.'
end

def fingerprint_problems
  marker_re = Regexp.new(scope['markers']['element_regex'])
  specs = scope['stencil_elements']
  specs.flat_map do |spec|
    text = read_repo(spec['path'])
    next ["#{spec['path']} is missing"] if text.nil?
    out = []
    m = text.match(marker_re)
    out << "#{spec['path']}: marker id is #{m ? m[1].inspect : 'absent'}, expected #{spec['id'].inspect}" unless m && m[1] == spec['id']
    matches = specs.select do |s|
      s['include'].all? { |t| text.include?(t) } && s['exclude'].none? { |t| text.include?(t) }
    end.map { |s| s['id'] }
    out << "#{spec['path']}: fingerprints match #{matches.inspect}, expected only #{spec['id'].inspect}" unless matches == [spec['id']]
    out
  end
end

def check
  problems = fingerprint_problems
  if File.exist?(MANIFEST_PATH)
    manifest = JSON.parse(File.read(MANIFEST_PATH, encoding: "UTF-8"))
    fresh = JSON.parse(JSON.generate(manifest))
    problems.concat(rehash!(fresh))
    problems << 'manifest scope differs from deploy/pdc-scope.json (run rehash)' if manifest['scope'] != scope
    (manifest.keys & SECTIONS).each do |section|
      manifest[section].each_with_index do |entry, i|
        entry.each do |k, v|
          next unless k.end_with?('sha256') && fresh[section][i][k] != v
          problems << "stale hash: #{section} #{entry['key']} #{k} (run rehash)"
        end
      end
    end
  else
    puts "No #{MANIFEST_PATH} yet (run unpack on an export); checked fingerprints only."
  end
  if problems.empty?
    puts 'OK'
  else
    problems.each { |p| puts p }
    exit 1
  end
end

case ARGV[0]
when 'unpack'
  abort 'usage: pdc_manifest.rb unpack EXPORT.json [--take ID[@STENCIL_ID] ...]' unless ARGV[1]
  takes = ARGV[2..-1].each_slice(2).map { |flag, val| flag == '--take' && val ? val : abort("unknown option #{flag}") }
  unpack(ARGV[1], takes)
when 'rehash'
  manifest = JSON.parse(File.read(MANIFEST_PATH, encoding: "UTF-8"))
  manifest['scope'] = scope
  problems = rehash!(manifest)
  File.write(MANIFEST_PATH, JSON.pretty_generate(manifest) + "\n")
  problems.each { |p| puts "WARNING: #{p}" }
  puts "Rehashed #{MANIFEST_PATH}"
when 'check'
  check
else
  abort File.read(__FILE__).lines.drop(1).take_while { |l| l.start_with?('#') }.join
end
