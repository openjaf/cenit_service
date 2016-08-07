require 'sinatra'
require 'mongoid'
require './models'

ENV['BASE_PATH'] = '/service'
ENV['SCHEMA_PATH'] = ENV['BASE_PATH'] + '/schema'
ENV['TOKEN_PATH'] = ENV['BASE_PATH'] + '/token'
ENV['HOMEPAGE'] = 'www.cenit.io'

Cenit.config do
  homepage ENV['HOMEPAGE']
end

class Service < ::Sinatra::Base

  configure do
    Mongoid::Config.load!('mongoid.yml')
  end

  before do
    Account.current = nil
  end

  get ENV['SCHEMA_PATH'] do
    if (token = AccountToken.where(token: params[:token]).first)
      token.set_current_account!
      token.destroy
      if (schema = Setup::Schema.where(namespace: params[:ns], uri: params[:uri]).first)
        schema.cenit_ref_schema(service_url: request.base_url)
      else
        halt 404
      end
    else
      Setup::Notification.create(message: "Accessing service with an invalid token: #{params[:token]}")
      halt 401
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