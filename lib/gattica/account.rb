module Gattica
  
  # Represents an account that an authenticated user has access to
  
  class Account
    
    include Convertible
    
    attr_reader :id, :updated, :title, :table_id, :account_id, :account_name, :profile_id, :web_property_id
  
    def initialize(xml)
      @id = xml.at_xpath('xmlns:id').text
      @updated = DateTime.parse(xml.at_xpath('xmlns:updated').text)
      @title = xml.at_xpath('xmlns:title').text
      @table_id = xml.at_xpath('dxp:tableid').text
      @account_id = xml.at_xpath("dxp:property[@name='ga:accountId']")['value'].to_i
      @account_name = xml.at_xpath("dxp:property[@name='ga:accountName']")['value']
      @profile_id = xml.at_xpath("dxp:property[@name='ga:profileId']")['value'].to_i
      @web_property_id = xml.at_xpath("dxp:property[@name='ga:webPropertyId']")['value']
    end
    
  end
end
