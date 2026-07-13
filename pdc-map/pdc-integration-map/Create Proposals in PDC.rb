# Create Proposal in PDC
# Creates a new proposal from application form context
# Returns the created proposal object
# Raises error if creation fails or required data is missing

require 'net/http'
require 'uri'
require 'json'

# Find the linked grant request through the relationship table
relationship = Relationship.find_by(
  related_model_id: model.id,
  related_relatable_type: "MacModelTypeDynPdcApplicationForm1",
  relatable_type: "GrantRequest"
)

unless relationship && relationship.relatable_id
  raise "No grant request linked to this application form. Cannot create proposal."
end

grant_request = GrantRequest.find_by_id(relationship.relatable_id)
unless grant_request
  raise "Grant request not found for this application form"
end

# Check if grant already has a PDC proposal
if grant_request.respond_to?(:pdc_proposal_id) && grant_request.pdc_proposal_id.present?
  raise "Grant request already has PDC proposal ID: #{grant_request.pdc_proposal_id}"
end

# Get opportunity ID from application form
if !model.respond_to?(:opportunity) || model.opportunity.blank?
  raise "No opportunity selected on application form. Cannot create proposal without opportunity."
end

# Extract numeric opportunity ID
opportunity_id = model.opportunity.to_s
if opportunity_id !~ /^\d+$/
  # If stored as description, look up the actual ID
  application_attribute = ModelAttribute.find_by(
    model_type: model.class.name,
    name: "opportunity"
  )
  
  if application_attribute
    attr_value = ModelAttributeValue.find_by(
      model_attribute_id: application_attribute.id,
      description: opportunity_id
    )
    
    if attr_value && attr_value.value.present?
      opportunity_id = attr_value.value
    else
      raise "Could not find opportunity ID for: #{opportunity_id}"
    end
  end
end

# Generate external ID from grant request
external_id = "fluxx_grant_#{grant_request.id}"

# Get base URL and auth token
base_url = model.dyn_invoke_for(:"Get PDC Base URL")
auth_token = model.dyn_invoke_for(:"Get Auth Token from PDC")

# Build request body
request_body = {
  opportunityId: opportunity_id.to_i,
  externalId: external_id
}

# Construct endpoint URL
endpoint = "#{base_url}/proposals"
uri = URI.parse(endpoint)

# Create POST request
request = Net::HTTP::Post.new(uri)
request['Authorization'] = "Bearer #{auth_token}"
request['Accept'] = 'application/json'
request['Content-Type'] = 'application/json'
request.body = request_body.to_json

begin
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end
  
  case response.code
  when "201"
    # Success - parse the created proposal
    proposal_data = JSON.parse(response.body)
    
    # Update grant request with PDC proposal ID
    if grant_request.respond_to?(:pdc_proposal_id=)
      grant_request.update_attribute(:pdc_proposal_id, proposal_data['id'])
    end
    
    # Return the created proposal with grant info
    {
      proposal: proposal_data,
      grant_request_id: grant_request.id,
      external_id: external_id,
      message: "Successfully created proposal #{proposal_data['id']} for grant #{grant_request.id}"
    }
    
  when "401"
    raise "Unauthorized: Invalid or expired auth token"
  when "409"
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "Conflict - proposal with external ID '#{external_id}' may already exist: #{error_message}"
  when "422"
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "Invalid data - opportunity #{opportunity_id} may not exist: #{error_message}"
  else
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "Failed to create proposal (#{response.code}): #{error_message}"
  end
  
rescue Net::OpenTimeout, Net::ReadTimeout
  raise "Timeout connecting to PDC API"
rescue SocketError, Errno::ECONNREFUSED
  raise "Cannot connect to PDC API at #{uri.hostname}"
rescue JSON::ParserError => e
  raise "Invalid JSON response: #{e.message}"
end