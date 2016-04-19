require 'sinatra'
require 'mongoid'
require './models'

ENV['TOKEN_PATH'] = '/oauth/token'

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
      response_code = 200
      token.destroy unless token.long_term?
      unless (access_grant = Setup::OauthAccessGrant.with(token.account).where(application_id: app_id).first)
        access_grant = Setup::OauthAccessGrant.with(token.account).new(application_id: app_id)
      end
      access_grant.scope = token.scope
      access_grant.save if access_grant.changed?
      token = OauthAccessToken.create(account: token.account, application_id: app_id)
      content_hash =
        {
          access_token: token.token,
          token_type: token.token_type,
          created_at: token.created_at.to_i,
          token_span: token.token_span
        }
      if Cenit::Scope.new(token.scope).offline_access? &&
        OauthRefreshToken.where(account: token.account, application_id: app_id).blank?
        refresh_token = OauthRefreshToken.create(account: token.account, application_id: app_id)
        content_hash[:refresh_token] = refresh_token.token
      end
    else
      errors += "Invalid #{grant_type.gsub('_', ' ')}." if token_class
      content_hash =
        {
          error: errors
        }
    end
    halt response_code, { 'Content-Type' => 'application/json' }, content_hash.to_json
  end
end