require 'nokogiri'
require 'devise'

module AccountScoped
  extend ActiveSupport::Concern

  included do
    include Mongoid::Document
    store_in collection: Proc.new { Account.tenant_collection_name(to_s) }
  end
end

class User

end

class Account
  include Mongoid::Document

  belongs_to :owner, class_name: User.to_s, inverse_of: nil
  has_many :users, class_name: User.to_s, inverse_of: :account

  class << self
    def current
      Thread.current[:current_account]
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

    def initialize(scope)
      @nss = Set.new
      @data_types = Hash.new { |h, k| h[k] = Set.new }
      scope = scope.to_s.strip
      @openid, scope = split(scope, %w(openid email address phone offline_access))
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
      methods.present? && (nss.present? || data_types.present?)
    end

    def to_s
      (openid.present? ? openid.join(' ') + ' ' : '') +
        methods.join(' ') + ' ' +
        nss.collect { |ns| space(ns) }.join(' ') + (nss.present? ? ' ' : '') +
        data_types.collect { |ns, set| set.collect { |model| "#{space(ns)}::#{space(model)}" } }.join(' ')
    end

    def descriptions
      d = []
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
      d << 'Do all these on your behalf.' if offline_access?
      d
    end

    def openid?
      openid.inlude?(:openid)
    end

    def offline_access?
      openid.include?(:offline_access)
    end

    private

    attr_reader :openid, :methods, :nss, :data_types

    def space(str)
      str.index(' ') ? "'#{str}'" : str
    end

    def split(scope, tokens)
      counters = Hash.new { |h, k| h[k] = 0 }
      while (method = tokens.detect { |m| scope.start_with?("#{m} ") })
        counters[method] += 1
        scope = scope.from(method.length).strip
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

  def set_current_account
    Account.current = account if Account.current.nil?
    account
  end
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