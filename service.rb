require 'sinatra'
require 'mongoid'
require './models'

configure do
  Mongoid::Config.load!('mongoid.yml')
end

before do
  if (key = params[:key]) && (user = User.where(unique_key: key).first)
    Thread.current[:current_account] = user.account
  else
    Setup::Notification.create(message: "Accessing service with an invalid user key: #{key}")
    halt 401
  end
end

get '/schema' do
  if (schema = Setup::Schema.where(namespace: params[:ns], uri: params[:uri]).first)
    schema.cenit_ref_schema(service_url: request.base_url)
  else
    halt 404
  end
end
