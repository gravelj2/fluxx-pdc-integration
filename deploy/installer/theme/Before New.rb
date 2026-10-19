# PDC deploy model: Before New
#
# The ONLY thing an admin pastes by hand (into the deploy model theme's
# Before New block). On the first record it downloads PDC Bootstrap Deploy
# Model from the repo and runs it, which builds the rest of the deploy model.
# Only one deploy record may exist: a second one deletes itself (Fluxx shows
# an error page; raising an error here does NOT stop the save).
#
# Pin REPO_REF to a release tag or commit SHA in production: whatever is at
# that ref becomes Ruby that runs in this Fluxx instance.

require 'json'
require 'net/http'
require 'uri'
require 'cgi'

repo_url = "https://github.com/macfound/fluxx-pdc-integration"
repo_ref = "main"

if model.class.where(deleted_at: nil).where.not(id: model.id).exists?
  model.delete
else
  path = "deploy/installer/PDC Bootstrap Deploy Model.rb"
  m = repo_url.match(%r{github\.com/([^/]+)/([^/]+)})
  uri = URI.parse("https://raw.githubusercontent.com/#{m[1]}/#{m[2]}/#{repo_ref}/#{CGI.escape(path).gsub('+', '%20').gsub('%2F', '/')}")
  resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    http.request(Net::HTTP::Get.new(uri))
  end

  if resp.code == '200'
    body = resp.body.to_s.dup.force_encoding('UTF-8')
    bootstrap = ModelMethod.where(model_type: model.class.name, name: 'PDC Bootstrap Deploy Model', deleted_at: nil).first
    if bootstrap
      bootstrap.unsafe_dyn_method = body
      bootstrap.save!
    else
      ModelMethod.create!(model_type: model.class.name, method_type: 'method', name: 'PDC Bootstrap Deploy Model', unsafe_dyn_method: body)
    end
    model.instance_variable_set(:@pdc_bootstrap, { 'repo_url' => repo_url, 'repo_ref' => repo_ref })
    model.dyn_invoke_for(:"PDC Bootstrap Deploy Model")
  else
    msg = "PDC bootstrap: could not fetch #{path} at #{repo_ref} (HTTP #{resp.code})"
    model.installer_results = JSON.generate('title' => 'Installer update', 'mode' => 'failed', 'error' => msg) if model.respond_to?(:installer_results=)
    msg
  end
end
