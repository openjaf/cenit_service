require 'nokogiri'
require 'devise'
require 'jwt'

module AccountScoped
  extend ActiveSupport::Concern

  included do
    include Mongoid::Document
    store_in collection: Proc.new { Account.tenant_collection_name(to_s) }
  end
end

class User
  include Mongoid::Document

  field :picture
end

class Account
  include Mongoid::Document

  belongs_to :owner, class_name: User.to_s, inverse_of: nil
  has_many :users, class_name: User.to_s, inverse_of: :account

  class << self
    def current
      Thread.current[:current_account]
    end

    def current=(account)
      Thread.current[:current_account] = account
    end

    def tenant_collection_prefix(options = {})
      sep = options[:separator] || ''
      acc_id =
        (options[:account] && options[:account].id) ||
          options[:account_id] ||
          (current && current.id)
      acc_id ? "acc#{acc_id}#{sep}" : ''
    end

    def tenant_collection_name(model_name, options = {})
      model_name = model_name.to_s
      options[:separator] ||= '_'
      tenant_collection_prefix(options) + model_name.collectionize
    end

    def data_type_collection_name(data_type)
      tenant_collection_name(data_type.data_type_name)
    end
  end
end

class User
  include Mongoid::Document

  field :email, type: String, default: ''
  field :name, type: String

  field :confirmed_at, type: DateTime

  field :unique_key, type: String

  belongs_to :account, inverse_of: :users, class_name: Account.to_s
end

module Setup

  class Validator
    include AccountScoped
  end

  class Schema < Validator

    field :namespace
    field :uri, type: String
    field :schema, type: String
    field :schema_type, type: Symbol

    def cenit_ref_schema(options = {})
      send("cenit_ref_#{schema_type}", options)
    end

    def cenit_ref_json_schema(options = {})
      schema
    end

    def cenit_ref_xml_schema(options = {})
      doc = Nokogiri::XML(schema)
      cursor = doc.root.first_element_child
      while cursor
        if %w(import include redefine).include?(cursor.name) && (attr = cursor.attributes['schemaLocation'])
          attr.value = options[:service_url].to_s + '/schema?' + {
            key: Account.current.owner.unique_key,
            ns: namespace,
            uri: Cenit::Utility.abs_uri(uri, attr.value)
          }.to_param
        end
        cursor = cursor.next_element
      end
      doc.to_xml
    end

  end

  class Notification
    include Mongoid::Document
    include Mongoid::Timestamps

    field :type, type: Symbol, default: :error
    field :message, type: String

    validates_presence_of :type, :message
    validates_inclusion_of :type, in: ->(n) { n.type_enum }

    def type_enum
      Setup::Notification.type_enum
    end

    class << self
      def type_enum
        [:error, :warning, :notice, :info]
      end
    end
  end

end

module Cenit

  class Scope

    def initialize(scope = '')
      scope = scope.to_s
      @nss = Set.new
      @data_types = Hash.new { |h, k| h[k] = Set.new }
      scope = scope.to_s.strip
      @openid, scope = split(scope, %w(openid email profile address phone offline_access auth))
      @offline_access = openid.delete(:offline_access)
      @auth = openid.delete(:auth)
      if openid.present? && !openid.include?(:openid)
        openid.clear
        fail
      end
      @methods, scope = split(scope, %w(get post put delete))
      while scope.present?
        ns_begin, ns_end, next_idx =
          if scope.start_with?((c = "'")) || scope.start_with?((c = '"'))
            [1, (next_idx = scope.index(c, 1)) - 1, next_idx + 1]
          else
            quad_dot_index = scope.index('::')
            space_index = scope.index(' ')
            if quad_dot_index && (space_index.nil? || space_index > quad_dot_index)
              [0, quad_dot_index - 1, quad_dot_index]
            elsif quad_dot_index.nil? && space_index
              [0, space_index - 1, space_index + 1]
            elsif quad_dot_index.nil? && space_index.nil?
              [0, scope.length, scope.length]
            else
              fail
            end
          end
        if ns_end >= ns_begin
          ns = scope[ns_begin..ns_end]
          scope = scope.from(next_idx) || ''
          if scope.start_with?('::')
            scope = scope.from(2)
            if scope.start_with?((c = "'")) || scope.start_with?((c = '"'))
              model = scope[1, scope.index(c, 1) - 1]
              scope = scope.from(model.length + 2)
              fail if scope.present? && !scope.start_with?(' ')
            else
              model = scope[0..(scope.index(' ') || scope.length) - 1]
              scope = scope.from(model.length)
            end
            @data_types[ns] << model
          else
            @nss << ns
          end
        else
          fail
        end
        scope = scope.strip
      end
    rescue
      @nss.clear
      @data_types.clear
    end

    def valid?
      openid.present? || (methods.present? && (nss.present? || data_types.present?))
    end

    def to_s
      (auth? ? 'auth ' : '') +
        (offline_access? ? 'offline_access ' : '') +
        (openid? ? openid.join(' ') + ' ' : '') +
        methods.join(' ') + ' ' +
        nss.collect { |ns| space(ns) }.join(' ') + (nss.present? ? ' ' : '') +
        data_types.collect { |ns, set| set.collect { |model| "#{space(ns)}::#{space(model)}" } }.join(' ')
    end

    def descriptions
      d = []
      d << 'View your email' if email?
      d << 'View your basic profile' if profile?
      if methods.present?
        d << methods.to_sentence + ' records from ' +
          if nss.present?
            'namespace' + (nss.size == 1 ? ' ' : 's ') + nss.collect { |ns| space(ns) }.to_sentence
          else
            ''
          end + (nss.present? && data_types.present? ? ', and ' : '') +
          if data_types.present?
            'data type' + (data_types.size == 1 ? ' ' : 's ') + data_types.collect { |ns, set| set.collect { |model| "#{space(ns)}::#{space(model)}" } }.flatten.to_sentence
          else
            ''
          end
      end
      d
    end

    def auth?
      auth.present?
    end

    def openid?
      openid.include?(:openid)
    end

    def email?
      openid.include?(:email)
    end

    def profile?
      openid.include?(:profile)
    end

    def offline_access?
      offline_access.present?
    end

    def merge(other)
      merge = self.class.new
      merge.instance_variable_set(:@auth, offline_access || other.instance_variable_get(:@auth))
      merge.instance_variable_set(:@offline_access, offline_access || other.instance_variable_get(:@offline_access))
      merge.instance_variable_set(:@openid, (openid + other.instance_variable_get(:@openid)).uniq)
      merge.instance_variable_set(:@methods, (methods + other.instance_variable_get(:@methods)).uniq)
      merge.instance_variable_set(:@nss, nss + other.instance_variable_get(:@nss))
      merge.instance_variable_set(:@data_types, data_types.merge(other.instance_variable_get(:@data_types)))
      merge
    end

    private

    attr_reader :auth, :offline_access, :openid, :methods, :nss, :data_types

    def space(str)
      str.index(' ') ? "'#{str}'" : str
    end

    def split(scope, tokens)
      scope += ' '
      counters = Hash.new { |h, k| h[k] = 0 }
      while (method = tokens.detect { |m| scope.start_with?("#{m} ") })
        counters[method] += 1
        scope = scope.from(method.length).strip + ' '
      end
      if counters.values.all? { |v| v ==1 }
        [counters.keys.collect(&:to_sym), scope]
      else
        [[], scope]
      end
    end
  end

  class Utility
    class << self
      def abs_uri(base_uri, uri)
        uri = URI.parse(uri.to_s)
        return uri.to_s unless uri.relative?

        base_uri = URI.parse(base_uri.to_s)
        uri = uri.to_s.split('/')
        path = base_uri.path.split('/')
        begin
          path.pop
        end while uri[0] == '..' ? uri.shift && true : false

        path = (path + uri).join('/')

        uri = URI.parse(path)
        uri.scheme = base_uri.scheme
        uri.host = base_uri.host
        uri.to_s
      end
    end
  end

  class << self

    def http_proxy_options
      options = {}
      %w(http_proxy http_proxy_port http_proxy_user http_proxy_password).each do |option|
        if option_value = send(option)
          options[option] = option_value
        end
      end
      options
    end

    def dynamic_model_loading?
      !excluded_actions.include?(:load_model)
    end

    def excluded_actions(*args)
      if args.length == 0
        options[:excluded_actions]
      else
        self[:excluded_actions] = args.flatten.collect(&:to_s).join(' ').split(' ').collect(&:to_sym)
      end
    end

    def reserved_namespaces(*args)
      if args.length == 0
        options[:reserved_namespaces]
      else
        self[:reserved_namespaces] = (options[:reserved_namespaces] + args[0].flatten.collect(&:to_s).collect(&:downcase)).uniq
      end
    end

    def options
      @options ||=
        {
          service_url: 'http://localhost:3000', #TODO Automatize default service url
          service_schema_path: '/schema',
          reserved_namespaces: %w(cenit default)
        }
    end

    def [](option)
      (value = options[option]).respond_to?(:call) ? value.call : value
    end

    def []=(option, value)
      options[option] = value
    end

    def config(&block)
      class_eval(&block) if block
    end

    def respond_to?(*args)
      super || options.has_key?(args[0])
    end

    def method_missing(symbol, *args)
      if !symbol.to_s.end_with?('=') && ((args.length == 0 && block_given?) || args.length == 1 && !block_given?)
        self[symbol] = block_given? ? yield : args[0]
      elsif args.length == 0 && !block_given?
        self[symbol]
      else
        super
      end
    end

  end
end

class CenitToken
  include Mongoid::Document
  include Mongoid::Timestamps

  field :token, type: String
  field :token_span, type: Integer, default: -> { self.class.default_token_span }
  field :data

  before_save :ensure_token

  def ensure_token
    self.token = Devise.friendly_token(self.class.token_length) unless token.present?
    true
  end

  def long_term?
    token_span.nil?
  end

  class << self
    def token_length(*args)
      if (arg = args[0])
        @token_length = arg
      else
        @token_length ||= 20
      end
    end

    def default_token_span(*args)
      if (arg = args[0])
        @token_span = arg.to_i rescue nil
      else
        @token_span
      end
    end
  end
end

module AccountTokenCommon
  extend ActiveSupport::Concern

  included do
    belongs_to :account, class_name: Account.to_s, inverse_of: nil

    before_create { self.account ||= Account.current }
  end

  def set_current_account!
    set_current_account(force: true)
  end

  def set_current_account(options = {})
    Account.current = account if Account.current.nil? || options[:force]
    account
  end
end

class AccountToken < CenitToken
  include AccountTokenCommon
end

module OauthTokenCommon
  extend ActiveSupport::Concern

  include AccountTokenCommon

  included do
    token_length 60

    default_token_span 1.hour
  end
end

class OauthCodeToken < CenitToken
  include OauthTokenCommon

  field :scope, type: String
end

class ApplicationId;
end

module OauthGrantToken
  extend ActiveSupport::Concern

  include OauthTokenCommon

  included do
    belongs_to :application_id, class_name: ApplicationId.to_s, inverse_of: nil
  end

  def access_grant
    @access_grant ||= Setup::OauthAccessGrant.with(account).where(application_id: application_id).first
  end

  def scope
    access_grant.scope
  end
end

class OauthRefreshToken < CenitToken
  include OauthTokenCommon

  default_token_span :never

  belongs_to :application_id, class_name: ApplicationId.to_s, inverse_of: nil
end

class OauthAccessToken < CenitToken
  include OauthGrantToken

  field :token_type, type: Symbol, default: :Bearer

  validates_inclusion_of :token_type, in: [:Bearer]

  class << self
    def for(user, app_id, scope)
      account = user.account
      scope = Cenit::Scope.new(scope) unless scope.is_a?(Cenit::Scope)
      unless (access_grant = Setup::OauthAccessGrant.with(account).where(application_id: app_id).first)
        access_grant = Setup::OauthAccessGrant.with(account).new(application_id: app_id)
      end
      access_grant.scope = scope.to_s
      access_grant.save
      token = OauthAccessToken.create(account: account, application_id: app_id)
      access =
        {
          access_token: token.token,
          token_type: token.token_type,
          created_at: token.created_at.to_i,
          token_span: token.token_span
        }
      if scope.offline_access? &&
        OauthRefreshToken.where(account: account, application_id: app_id).blank?
        refresh_token = OauthRefreshToken.create(account: account, application_id: app_id)
        access[:refresh_token] = refresh_token.token
      end
      if scope.openid?
        payload =
          {
            iss: Cenit.homepage,
            sub: user.id.to_s,
            aud: app_id.identifier,
            exp: access[:created_at] + access[:token_span],
            iat: access[:created_at],
          }
        if scope.email? || scope.profile? #TODO Include other OpenID scopes
          payload[:email] = user.email
          payload[:email_verified] = user.confirmed_at.present?
          if scope.profile?
            payload[:given_name] = user.name
            payload[:picture] = "#{Cenit.homepage}/file/user/picture/#{user.id}/#{user.picture}"
            #TODO Family Name for Cenit Users
            # payload[:family_name] = user.family_name
          end
        end
        access[:id_token] = JWT.encode(payload, nil, 'none')
      end
      access
    end
  end
end

module Setup
  class Application
    include AccountScoped

    field :configuration_attributes, type: Hash

    belongs_to :application_id, class_name: ApplicationId.to_s, inverse_of: nil
    field :secret_token, type: String

    attr_readonly :secret_token

    def identifier
      application_id && application_id.identifier
    end

    class << self
      def with(options)
        options = { collection: Account.tenant_collection_name(Setup::Application, account: options) } if options.is_a?(Account)
        super
      end
    end
  end

  class OauthAccessGrant
    include AccountScoped
    include Mongoid::Timestamps

    belongs_to :application_id, class_name: ApplicationId.to_s, inverse_of: nil
    field :scope, type: String

    class << self
      def with(options)
        options = { collection: Account.tenant_collection_name(OauthAccessGrant, account: options) } if options.is_a?(Account)
        super
      end
    end

  end
end

class ApplicationId
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, class_name: Account.to_s, inverse_of: nil

  field :identifier, type: String
  field :oauth_name, type: String

  before_save do
    self.identifier ||= (id.to_s + Devise.friendly_token(60))
    self.account ||= Account.current
  end

  def app
    @app ||= Setup::Application.with(account).where(application_id: self).first
  end

  def redirect_uris
    redirect_uris = app.configuration_attributes['redirect_uris'] || []
    redirect_uris = [redirect_uris.to_s] unless redirect_uris.is_a?(Enumerable)
    redirect_uris
  end
end