require 'nokogiri'

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

    def tenant_collection_prefix(sep = '')
      current.present? ? "acc#{current.id}#{sep}" : ''
    end

    def tenant_collection_name(model_name, sep='_')
      tenant_collection_prefix(sep) + model_name.collectionize
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