require 'sinatra/base'
require 'mongoid'
require './models'

class Service < ::Sinatra::Base

  configure do

    Mongoid::Config.load!('mongoid.yml')

    enable :logging
  end

  before do
    logger.info 'Before'
    if (key = params[:key]) && (user = User.where(unique_key: key).first)
      logger.info 'Key Ok!'
      Thread.current[:current_account] = user.account
    else
      logger.info 'Invalid Key'
      Setup::Notification.create(message: "Accessing service with an invalid user key: #{key}")
      halt 401
    end
  end

  get '/schema' do
  logger.info 'Resolving Schema'
    if (schema = Setup::Schema.where(namespace: params[:ns], uri: params[:uri]).first)
      schema.cenit_ref_schema(service_url: request.base_url)
    else
      halt 404
    end
  end

end


