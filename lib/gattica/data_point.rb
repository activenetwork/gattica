require "csv"

module Gattica
  
  # Represents a single "row" of data containing any number of dimensions, metrics
  
  class DataPoint
    
    include Convertible
    
    attr_reader :id, :updated, :title, :dimensions, :metrics, :xml
    
    # Parses the XML <entry> element
    def initialize(xml)
      @xml = xml.to_s
      @id = xml.at_xpath('xmlns:id').text
      @updated = DateTime.parse(xml.at_xpath('xmlns:updated').text)
      @title = xml.at_xpath('xmlns:title').text
      @dimensions = xml.xpath('dxp:dimension').collect do |dimension|
        { dimension['name'].split(':').last.to_sym => dimension['value'].split(':', 1).last }
      end
      @metrics = xml.xpath('dxp:metric').collect do |metric|
        { metric['name'].split(':').last.to_sym => metric['value'].split(':', 1).last.to_i }
      end
    end
    
    
    # Outputs in Comma Seperated Values format
    def to_csv(format = :long)
      output = ''
      
      columns = []
      # only output
      case format
      when :long
        columns.concat([@id, @updated, @title])
      end
      
      # output all dimensions
      columns.concat(@dimensions.map {|d| d.value})
      
      # output all metrics
      columns.concat(@metrics.map {|m| m.value})

      output = CSV.generate_line(columns)      
      return output
    end
    
    
    def to_yaml
      { 'id' => @id,
        'updated' => @updated,
        'title' => @title,
        'dimensions' => @dimensions,
        'metrics' => @metrics }.to_yaml
    end
    
  end
  
end
