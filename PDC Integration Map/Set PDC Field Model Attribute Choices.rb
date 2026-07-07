# Set PDC Field Model Attribute Choices
# Validates and creates model attribute values for PDC base fields

require 'net/http'
require 'uri'
require 'json'

# Get base fields from PDC API
base_url = model.dyn_invoke_for(:"Get PDC Base URL")
auth_token = model.dyn_invoke_for(:"Get Auth Token from PDC")

# Fetch current base fields from PDC
endpoint = "#{base_url}/baseFields"
uri = URI.parse(endpoint)

request = Net::HTTP::Get.new(uri)
request['Authorization'] = "Bearer #{auth_token}"
request['Accept'] = 'application/json'

pdc_base_fields = []

begin
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end
  
  case response.code
  when "200"
    pdc_base_fields = JSON.parse(response.body)
  when "401"
    raise "Unauthorized: Invalid or expired auth token"
  when "404"
    raise "Base fields endpoint not found at #{endpoint}"
  else
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "Failed to get base fields (#{response.code}): #{error_message}"
  end
  
rescue Net::OpenTimeout, Net::ReadTimeout
  raise "Timeout connecting to PDC API"
rescue SocketError, Errno::ECONNREFUSED
  raise "Cannot connect to PDC API at #{uri.hostname}"
rescue JSON::ParserError => e
  raise "Invalid JSON response: #{e.message}"
end

# Find the model attribute for PDC fields
pdc_field_attribute = ModelAttribute.find_by(
  model_type: "MacModelTypeDynPDCMappedField1", 
  name: "pdc_field"
)

if pdc_field_attribute.nil?
  raise "PDC field model attribute not found. Cannot create field choices."
end

# Track results
created_count = 0
updated_count = 0
skipped_count = 0
errors = []

# Process each base field
pdc_base_fields.each do |field|
  short_code = field['shortCode']
  label = field['label']
  
  # Skip if essential data is missing
  if short_code.blank? || label.blank?
    errors << "Skipping field with missing shortCode or label"
    skipped_count += 1
    next
  end
  
  # Check if value already exists
  existing_value = ModelAttributeValue.find_by(
    model_attribute_id: pdc_field_attribute.id,
    value: short_code
  )
  
  if existing_value
    # Update description if changed (using label as description)
    if existing_value.description != label
      existing_value.update(description: label)
      updated_count += 1
    else
      skipped_count += 1
    end
  else
    # Create new value with label as description
    ModelAttributeValue.create!(
      model_attribute_id: pdc_field_attribute.id,
      value: short_code,
      description: label
    )
    created_count += 1
  end
end

# Return summary
{
  total_fields: pdc_base_fields.length,
  created: created_count,
  updated: updated_count,
  skipped: skipped_count,
  errors: errors
}