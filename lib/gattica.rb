$:.unshift File.dirname(__FILE__) # for use/testing when no gem is installed

# external
require 'net/http'
require 'net/https'
require 'uri'
require 'cgi'
require 'logger'
require 'rubygems'
require 'nokogiri'
require 'yaml'

# internal
require 'gattica/core_extensions'
require 'gattica/convertible'
require 'gattica/exceptions'
require 'gattica/user'
require 'gattica/auth'
require 'gattica/account'
require 'gattica/data_set'
require 'gattica/data_point'

# Gattica is a Ruby library for talking to the Google Analytics API.
#
# Please see the README for usage docs.

module Gattica
  
  VERSION = '0.4.0'
  
  # Creates a new instance of Gattica::Engine and gets us going. Please see the README for usage docs.
  #
  #   ga = Gattica.new({:email => 'anonymous@anon.com', :password => 'password, :profile_id => 123456 })
  
  def self.new(*args)
    Engine.new(*args)
  end
  
  # The real meat of Gattica, deals with talking to GA, returning and parsing results. You actually get 
  # an instance of this when you go Gattica.new()
  
  class Engine
    
    SERVER = 'www.google.com'
    PORT = 443
    SECURE = true
    DEFAULT_ARGS = { :start_date => nil, :end_date => nil, :dimensions => [], :metrics => [], :filters => [], :sort => [], :start_index => 1, :max_results => 10000, :page => false }
    DEFAULT_OPTIONS = { :email => nil, :password => nil, :token => nil, :profile_id => nil, :debug => false, :headers => {}, :logger => Logger.new(STDOUT) }
    FILTER_METRIC_OPERATORS = %w{ == != > < >= <= }
    FILTER_DIMENSION_OPERATORS = %w{ == != =~ !~ =@ ~@ }
    
    attr_reader :user
    attr_accessor :profile_id, :token
    
    # Create a user, and get them authorized.
    # If you're making a web app you're going to want to save the token that's retrieved by Gattica
    # so that you can use it later (Google recommends not re-authenticating the user for each and every request)
    #
    #   ga = Gattica.new({:email => 'johndoe@google.com', :password => 'password', :profile_id => 123456})
    #   ga.token => 'DW9N00wenl23R0...' (really long string)
    #
    # Or if you already have the token (because you authenticated previously and now want to reuse that session):
    #
    #   ga = Gattica.new({:token => '23ohda09hw...', :profile_id => 123456})
    
    def initialize(options={})
      @options = DEFAULT_OPTIONS.merge(options)
      @logger = @options[:logger]
      
      @profile_id = @options[:profile_id]     # if you don't include the profile_id now, you'll have to set it manually later via Gattica::Engine#profile_id=
      @user_accounts = nil                    # filled in later if the user ever calls Gattica::Engine#accounts
      @headers = {}.merge(@options[:headers]) # headers used for any HTTP requests (Google requires a special 'Authorization' header which is set any time @token is set)
      
      # save a proxy-aware http connection for everyone to use
      proxy_host = nil
      proxy_port = nil
      proxy_var  = SECURE ? 'https_proxy' : 'http_proxy'
      [proxy_var, proxy_var.upcase].each do |pxy|
        if ENV[pxy]
          uri = URI::parse(ENV[pxy])
          proxy_host = uri.host
          proxy_port = uri.port
        end
      end
      @http = Net::HTTP::Proxy(proxy_host,proxy_port).new(SERVER, PORT)
      @http.use_ssl = SECURE
      @http.set_debug_output $stdout if @options[:debug]
      
      # authenticate
      if @options[:email] && @options[:password]      # email and password: authenticate, get a token from Google's ClientLogin, save it for later
        @user = User.new(@options[:email], @options[:password])
        @auth = Auth.new(@http, user)
        self.token = @auth.tokens[:auth]
      elsif @options[:token]                          # use an existing token
        self.token = @options[:token]
      else                                            # no login or token, you can't do anything
        raise GatticaError::NoLoginOrToken, 'You must provide an email and password, or authentication token'
      end
      
      # TODO: check that the user has access to the specified profile and show an error here rather than wait for Google to respond with a message
    end
    
    
    # Returns the list of accounts the user has access to. A user may have multiple accounts on Google Analytics
    # and each account may have multiple profiles. You need the profile_id in order to get info from GA. If you
    # don't know the profile_id then use this method to get a list of all them. Then set the profile_id of your
    # instance and you can make regular calls from then on.
    #
    #   ga = Gattica.new({:email => 'johndoe@google.com', :password => 'password'})
    #   ga.get_accounts
    #   # you parse through the accounts to find the profile_id you need
    #   ga.profile_id = 12345678
    #   # now you can perform a regular search, see Gattica::Engine#get
    #
    # If you pass in a profile id when you instantiate Gattica::Search then you won't need to
    # get the accounts and find a profile_id - you apparently already know it!
    #
    # See Gattica::Engine#get to see how to get some data.
    
    def accounts
      # if we haven't retrieved the user's accounts yet, get them now and save them
      if @user_accounts.nil?
        data = do_http_get('/analytics/feeds/accounts/default')
        xml = Nokogiri.XML(data)
        @user_accounts = xml.root.xpath('xmlns:entry').collect { |entry| Account.new(entry) }
      end
      return @user_accounts
    end

    # Performs a Gattica::Engine#get but instead of returning the dataset streams it to the file handle in a CSV format
    #
    # == Usage
    #
    #   gs = Gattica.new({:email => 'johndoe@google.com', :password => 'password', :profile_id => 123456})
    #   fh = File.new("file.csv", "w")
    #   gs.get_to_csv({ :start_date => '2008-01-01', 
    #            :end_date => '2008-02-01', 
    #            :dimensions => 'browser', 
    #            :metrics => 'pageviews', 
    #            :sort => 'pageviews',
    #            :filters => ['browser == Firefox']}, fh, :short)
    #
    # See Gattica::Engine#get to see details of arguments

    def get_to_csv(args={}, fh = nil, format = :long)   
      raise GatticaError::InvalidFileType, "Invalid file handle" unless !fh.nil?
      results(args, fh, :csv, format)
    end
    
    # This is the method that performs the actual request to get data.
    #
    # == Usage
    #
    #   gs = Gattica.new({:email => 'johndoe@google.com', :password => 'password', :profile_id => 123456})
    #   gs.get({ :start_date => '2008-01-01', 
    #            :end_date => '2008-02-01', 
    #            :dimensions => 'browser', 
    #            :metrics => 'pageviews', 
    #            :sort => 'pageviews',
    #            :filters => ['browser == Firefox']})
    #
    # == Input
    #
    # When calling +get+ you'll pass in a hash of options. For a description of what these mean to 
    # Google Analytics, see http://code.google.com/apis/analytics/docs
    #
    # Required values are:
    #
    # * +start_date+ => Beginning of the date range to search within
    # * +end_date+ => End of the date range to search within
    #
    # Optional values are:
    #
    # * +dimensions+ => an array of GA dimensions (without the ga: prefix)
    # * +metrics+ => an array of GA metrics (without the ga: prefix)
    # * +filter+ => an array of GA dimensions/metrics you want to filter by (without the ga: prefix)
    # * +sort+ => an array of GA dimensions/metrics you want to sort by (without the ga: prefix)
    # * +page+ => true|false Does the paging to create a single set of all of the data
    # * +start_index+ => Beginning offset of the query (default 1)
    # * +max_results+ => How many results to grab (maximum 10,000)
    #
    # == Exceptions
    #
    # If a user doesn't have access to the +profile_id+ you specified, you'll receive an error.
    # Likewise, if you attempt to access a dimension or metric that doesn't exist, you'll get an
    # error back from Google Analytics telling you so.
    
    def get(args={})
      return results(args)
    end
    
    private
    
    def results(args={}, fh=nil, type=nil, format=nil)
      raise GatticaError::InvalidFileType, "Invalid file type" unless type.nil? ||[:csv,:xml].include?(type)
      args = validate_and_clean(DEFAULT_ARGS.merge(args))

      header = 0
      results = nil
      total_results = args[:max_results]
      while(args[:start_index] < total_results)
        query_string = build_query_string(args,@profile_id)
        @logger.debug("Query String: " + query_string) if @debug

        data = do_http_get("/analytics/feeds/data?#{query_string}")
        result = DataSet.new(Nokogiri.XML(data).root)
        
        #handle returning results
        results.points.concat(result.points) if !results.nil? && fh.nil?
        #handle csv
        
        if(!fh.nil? && type == :csv && header == 0)
          fh.write result.to_csv_header(format)
          header = 1 
        end
        
        fh.write result.to_csv(:noheader) if !fh.nil? && type == :csv
        fh.flush if !fh.nil?
        
        results = result if results.nil?
        total_results = result.total_results
        args[:start_index] += args[:max_results]
        break if !args[:page] # only continue while if we are suppose to page
      end 
      return results if fh.nil?
    end
    
    # Since google wants the token to appear in any HTTP call's header, we have to set that header
    # again any time @token is changed so we override the default writer (note that you need to set
    # @token with self.token= instead of @token=)
    
    def token=(token)
      @token = token
      set_http_headers
    end
    
    
    # Does the work of making HTTP calls and then going through a suite of tests on the response to make
    # sure it's valid and not an error
    
    def do_http_get(query_string)
      response, data = @http.get(query_string, @headers)
      
      # error checking
      if response.code != '200'
        case response.code
        when '400'
          raise GatticaError::AnalyticsError, response.body + " (status code: #{response.code})"
        when '401'
          raise GatticaError::InvalidToken, "Your authorization token is invalid or has expired (status code: #{response.code})"
        else  # some other unknown error
          raise GatticaError::UnknownAnalyticsError, response.body + " (status code: #{response.code})"
        end
      end
      
      return data
    end
    
    private
    
    # Sets up the HTTP headers that Google expects (this is called any time @token is set either by Gattica
    # or manually by the user since the header must include the token)
    def set_http_headers
      @headers['Authorization'] = "GoogleLogin auth=#{@token}"
    end
    
    
    # Creates a valid query string for GA
    def build_query_string(args,profile)
      query_params  = args.clone
      ga_start_date = query_params.delete(:start_date)
      ga_end_date   = query_params.delete(:end_date)
      ga_dimensions = query_params.delete(:dimensions)
      ga_metrics    = query_params.delete(:metrics)
      ga_sort       = query_params.delete(:sort)
      ga_filters    = query_params.delete(:filters)
      
      output = "ids=ga:#{profile}&start-date=#{ga_start_date}&end-date=#{ga_end_date}"
      unless ga_dimensions.nil? || ga_dimensions.empty?
        output += '&dimensions=' + ga_dimensions.collect do |dimension|
          "ga:#{dimension}"
        end.join(',')
      end
      unless ga_metrics.nil? || ga_metrics.empty?
        output += '&metrics=' + ga_metrics.collect do |metric|
          "ga:#{metric}"
        end.join(',')
      end
      unless ga_sort.nil? || ga_sort.empty?
        output += '&sort=' + Array(ga_sort).collect do |sort|
          sort[0..0] == '-' ? "-ga:#{sort[1..-1]}" : "ga:#{sort}"  # if the first character is a dash, move it before the ga:
        end.join(',')
      end
      
      # TODO: update so that in regular expression filters (=~ and !~), any initial special characters in the regular expression aren't also picked up as part of the operator (doesn't cause a problem, but just feels dirty)
      unless args[:filters].empty?    # filters are a little more complicated because they can have all kinds of modifiers
        output += '&filters=' + args[:filters].collect do |filter|
          match, name, operator, expression = *filter.match(/^(\w*)\s*([=!<>~@]*)\s*(.*)$/)           # splat the resulting Match object to pull out the parts automatically
          unless name.empty? || operator.empty? || expression.empty?                      # make sure they all contain something
            "ga:#{name}#{CGI::escape(operator.gsub(/ /,''))}#{CGI::escape(expression)}"   # remove any whitespace from the operator before output
          else
            raise GatticaError::InvalidFilter, "The filter '#{filter}' is invalid. Filters should look like 'browser == Firefox' or 'browser==Firefox'"
          end
        end.join(';')
      end
 
      query_params.inject(output) {|m,(key,value)| m << "&#{key}=#{value}"}
 
      return output
    end
    
    
    # Validates that the args passed to +get+ are valid
    def validate_and_clean(args)
      
      raise GatticaError::MissingStartDate, ':start_date is required' if args[:start_date].nil? || args[:start_date].empty?
      raise GatticaError::MissingEndDate, ':end_date is required' if args[:end_date].nil? || args[:end_date].empty?
      raise GatticaError::TooManyDimensions, 'You can only have a maximum of 7 dimensions' if args[:dimensions] && (args[:dimensions].is_a?(Array) && args[:dimensions].length > 7)
      raise GatticaError::TooManyMetrics, 'You can only have a maximum of 10 metrics' if args[:metrics] && (args[:metrics].is_a?(Array) && args[:metrics].length > 10)
      
      possible = args[:dimensions] + args[:metrics]
      
      # make sure that the user is only trying to sort fields that they've previously included with dimensions and metrics
      if args[:sort]
        missing = args[:sort].find_all do |arg|
          !possible.include? arg.gsub(/^-/,'')    # remove possible minuses from any sort params
        end
        unless missing.empty?
          raise GatticaError::InvalidSort, "You are trying to sort by fields that are not in the available dimensions or metrics: #{missing.join(', ')}"
        end
      end
      
      # make sure that the user is only trying to filter fields that are in dimensions or metrics
      if args[:filters]
        missing = args[:filters].find_all do |arg|
          !possible.include? arg.match(/^\w*/).to_s    # get the name of the filter and compare
        end
        unless missing.empty?
          raise GatticaError::InvalidSort, "You are trying to filter by fields that are not in the available dimensions or metrics: #{missing.join(', ')}"
        end
      end
      
      return args
    end
    
    
  end
end
