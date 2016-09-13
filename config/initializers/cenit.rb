
Cenit.config do
  service_path '/service'

  schema_service_path '/schema'
end

Cenit::MultiTenancy.tenant_model Account