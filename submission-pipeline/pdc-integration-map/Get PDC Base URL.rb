# Get PDC Base URL

dashboard_config = ClientConfiguration.find_by_id(47)
return "https://api-test.philanthropydatacommons.org" unless dashboard_config

begin
  dashboard_title = JSON.parse(dashboard_config.configuration).dig("application", "dashboard_title")
  
  if dashboard_title && !dashboard_title.include?("[")
    "https://api.philanthropydatacommons.org"
  else
    "https://api-test.philanthropydatacommons.org"
  end
rescue
  "https://api-test.philanthropydatacommons.org"
end