require 'sinatra'
require 'mongoid'
require './models'

ENV['TOKEN_PATH'] = '/oauth/token'
ENV['HOMEPAGE'] = 'www.cenit.io'

Cenit.config do
  homepage ENV['HOMEPAGE']
end

class Service < ::Sinatra::Base

  configure do
    Mongoid::Config.load!('mongoid.yml')
  end

  before do
    if (key = params[:key]) && (user = User.where(unique_key: key).first)
      Thread.current[:current_account] = user.account
    else
      Setup::Notification.create(message: "Accessing service with an invalid user key: #{key}")
      halt 401
    end unless request.path == ENV['TOKEN_PATH']
  end

  get '/schema' do
    if (schema = Setup::Schema.where(namespace: params[:ns], uri: params[:uri]).first)
      schema.cenit_ref_schema(service_url: request.base_url)
    else
      halt 404
    end
  end

  post ENV['TOKEN_PATH'] do
    response_code = 400
    errors = ''
    unless (app_id = ApplicationId.where(identifier: params[:client_id]).first) &&
      app_id.app.secret_token == params[:client_secret]
      errors += 'Invalid client credentials. '
    end
    token_class =
      case (grant_type = params[:grant_type])
      when 'authorization_code'
        errors += 'Invalid redirect_uri. ' unless app_id.nil? || app_id.redirect_uris.include?(params[:redirect_uri])
        errors += 'Code missing. ' unless (auth_value = params[:code])
        OauthCodeToken
      when 'refresh_token'
        errors += 'Refresh token missing. ' unless (auth_value = params[:refresh_token])
        OauthRefreshToken
      else
        errors += 'Invalid grant_type parameter.'
        nil
      end
    if errors.blank? && (token = token_class.where(token: auth_value).first)
      token.destroy unless token.long_term?
      begin
        content_hash = OauthAccessToken.for(token.account.owner, app_id, token.scope)
        response_code = 200
      rescue Exception => ex
        errors += ex.message
      end
    else
      errors += "Invalid #{grant_type.gsub('_', ' ')}." if token_class
    end
    content_hash = { error: errors } if errors.present?
    halt response_code, { 'Content-Type' => 'application/json' }, content_hash.to_json
  end
end