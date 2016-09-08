Rails.application.routes.draw do
  mount Cenit::Service::Engine => Cenit.service_path || '/service'
end
