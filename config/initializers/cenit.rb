
Cenit.config do
  service_path '/'
  routed_service_url 'http://service.cenit.io'
  schema_service_path '/schema'
end

Cenit::MultiTenancy.tenant_model Account
