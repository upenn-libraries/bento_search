require 'nokogiri'

require 'http_client_patch/include_client'
require 'httpclient'

# Attempt to search using the WorldCat Search SRU variant, asking API for
# results in DC format. We'll see how far this takes us. 
#
# Does require an API key, and requires OCLC membership/FirstSearch subscription
# for access. 
#
# == API Docs
# * http://oclc.org/developer/documentation/worldcat-search-api/using-api
# * http://oclc.org/developer/documentation/worldcat-search-api/sru
# * http://oclc.org/developer/documentation/worldcat-search-api/parameters
class BentoSearch::WorldcatSruDcEngine
  include BentoSearch::SearchEngine
  
  extend HTTPClientPatch::IncludeClient
  include_http_client
  
  def search_implementation(args)
    url = construct_query_url(args)

    results = BentoSearch::Results.new
    
    response = http_client.get(url)
    
    if response.status != 200
      response.error ||= {}
      response.error[:status] = response.status
      response.error[:info] = response.body
      response.error[:url] = url
    end
    
    xml = Nokogiri::XML(response.body)
    # namespaces only get in the way
    xml.remove_namespaces!
    
    results.total_items = xml.at_xpath("//numberOfRecords").try {|n| n.text.to_i }
    
    
    (xml.xpath("/searchRetrieveResponse/records/record/recordData/oclcdcs") || []).each do |record|
      item = BentoSearch::ResultItem.new
      
      item.title        = first_text_if_present record, "title"
      
      # May have one (or more?) 'creator' and one or more 'contributor'. 
      # We'll use just creators if we got em, else contributors. 
      authors = record.xpath("./creator")
      authors = record.xpath("./contributor") if authors.empty?
      authors.each do |auth_node|
        item.authors << BentoSearch::Author.new(:display => auth_node.text)
      end
      
      
      # date may have garbage in it, just take the first four digits
      item.year         = record.at_xpath("date").try do |date_node|
        date_node.text =~ /(\d{4})/ ? $1 : nil          
      end
      
      # weird garbled from MARC format, best we have
      item.format_str   = first_text_if_present(record, "format") || first_text_if_present(record, "type")
      
      item.publisher    = first_text_if_present record, "publisher"
      
      # OCLC DC format gives us a bunch of jumbled 'description' elements
      # with any Marc 5xx. Sigh. We'll just concat em all and call it an
      # abstract, best we can do. 
      item.abstract     = record.xpath("description").collect {|n| n.text}.join(" \n ")
      
      # dc.identifier is a terrible smorgasbord of different identifiers,
      # with no way to tell for sure what's what other than pattern matching
      # of literals. sigh. 
      if ( id = first_text_if_present(record, "identifier"))
        possible_isxn = id.scan(/\d|X/).join('')
        # we could test check digit validity, but we ain't
        if possible_isxn.length == 10 || possible_isxn.length == 13
          item.isbn = possible_isxn
        elsif possible_isxn.length == 8
          item.issn = possible_isxn
        end
      end
      
      # The recordIdentifier with no "xsi:type" attrib is an oclcnum. sigh. 
      # lccn may also be in there if we wanted to keep it. 
      item.oclcnum        = first_text_if_present(record, "./recordIdentifier[not(@type)]")
      
      
      
      results << item
    end
    
    return results
  end
  
  def construct_query_url(args)
    url = configuration.base_url
    url += "&wskey=#{CGI.escape configuration.api_key}"
    url += "&recordSchema=#{CGI.escape 'info:srw/schema/1/dc'}"
    
    url += "&query=#{CGI.escape construct_cql_query(args)}"
  end
  
  def first_text_if_present(node, xpath)
    node.at_xpath(xpath).try {|n| n.text}
  end
  
  # construct valid CQL for the API's "query" param, from search
  # args. Tricky because we need to split terms/phrases ourselves
  #
  # returns CQL that is NOT uri escaped yet. 
  def construct_cql_query(args)
    field = "srw.kw" # later be field specific from args please. 
    
    # We need to split terms and phrases, so we can formulate
    # CQL with seperate clauses for each, bah. 
    tokens = args[:query].split(%r{\s|("[^"]+")}).delete_if {|a| a.blank?}
    

    
    return tokens.collect do |token|
      quoted_token = nil
      if token =~ /^".*"$/
        # phrase
        quoted_token = token
      else
        # escape internal double quotes with single backslash. sorry ruby escaping
        # makes this crazy. 
        token = token.gsub('"', %Q{\\"})
        quoted_token = %Q{"#{token}"}
      end
      
      "#{field} = #{quoted_token}"
      end.join(" AND ")    
  end

  def self.required_configuration
    [:api_key]
  end
  
  def self.default_configuration
    {
      :base_url => "http://www.worldcat.org/webservices/catalog/search/sru?"
    }
  end
  
end
