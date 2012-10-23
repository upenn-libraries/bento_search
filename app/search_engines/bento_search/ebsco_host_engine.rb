# encoding: utf-8

require 'nokogiri'

require 'http_client_patch/include_client'
require 'httpclient'

# Right now for EbscoHost API (Ebsco Integration Toolkit/EIT), 
# may be expanded or refactored for EDS too.
#
# == Required Configuration
#
# * profile_id
# * profile_password
# * databases: ARRAY of ebsco shortcodes of what databases to include in search. If you specify one you don't have access to, you get an error message from ebsco, alas.
#
# == Custom response data
# 
# Iff EBSCO API reports that fulltext is available for the hit, then 
# result.custom_data["result_formats"] will be non-nil, and will be an array of
# one or more of EBSCO's internal codes (P=PDF, T=HTML, C=HTML+Images). If
# no fulltext is avail according to EBSCO API, result.custom_data["result_formats"]
# will be nil. 
#
# You can use this to, for instance, hyperlink the displayed title directly
# to record on EBSCO if and only if there's fulltext.  See 
# app/item_decorators/bento_search/ebscohost/conditional_openurl_main_link for an example. 
# 
#
# == Limitations
# We do set language of ResultItems based on what ebsco tells us, but ebsoc
# seems to often leave out language or say 'english' for things that are not
# (maybe cause abstract is in English?). Config variable to tell us to ignore language?
#
# == Note on including databases
#
# Need to specifically configure all databases your institution licenses from
# EBSCO that you want included in the search. You can't just say "all of them"
# the api doesn't support that, and also more than 30 or 40 starts getting
# horribly slow. If you include a db you do not have access to, EBSCO api
# fatal errors. 
#
# You may want to make sure all your licensed databases are included
# in your EIT profile. Log onto ebscoadmin, Customize Services, choose
# EIT profile, choose 'databases' tag. 
# 
# === Download databases from EBSCO api
#
# We include a utility to download ALL activated databases for EIT profile
# and generate a file putting them in a ruby array. You may want to use this
# file as a starting point, and edit by hand:
#
# First configure your EBSCO search engine with bento_search, say under
# key 'ebscohost'. 
#
# Then run:
#    rails generate bento_search:pull_ebsco_dbs ebscohost
#
# assuming 'ebscohost' is the key you registered the EBSCO search engine. 
#
# This will create a file at ./config/ebsco_dbs.rb. You may want to hand
# edit it. Then, in your bento search config, you can:
#
#    require "#{Rails.root}/config/ebsco_dbs.rb"
#    BentoSearch.register_engine("ebscohost") do |conf|
#       # ....
#       conf.databases = $ebsco_dbs
#    end
#
# == Vendor documentation 
#
# Vendor documentation is a bit scattered, main page:
# * http://support.ebsco.com/eit/ws.php
# Some other useful pages we discovered:
# * http://support.ebsco.com/eit/ws_faq.php
# * search syntax examples: http://support.ebsco.com/eit/ws_howto_queries.php
# * Try construct a query: http://eit.ebscohost.com/Pages/MethodDescription.aspx?service=/Services/SearchService.asmx&method=Search
# * The 'info' service can be used to see what databases you have access to. 
# * DTD of XML Response, hard to interpret but all we've got: http://support.ebsco.com/eit/docs/DTD_EIT_WS_searchResponse.zip
#
#  Hard to find docs page on embedding EBSCO limiters (like peer reviewed only "RV Y") in search query: 
#     http://support.epnet.com/knowledge_base/detail.php?id=5397
#
#  EBSCO searchable support portal has a section for the EIT api we use here:
#     http://support.epnet.com/knowledge_base/search.php?keyword=&interface_id=1082&document_type=&page_function=search

class BentoSearch::EbscoHostEngine
  include BentoSearch::SearchEngine
  
  extend HTTPClientPatch::IncludeClient
  include_http_client
  
  # Include some rails helpers, text_helper.trucate
  def text_helper
    @@truncate ||= begin
      o = Object.new
      o.extend ActionView::Helpers::TextHelper
      o
    end
  end
  
  def search_implementation(args)
    url = query_url(args)
    
    results = BentoSearch::Results.new
    xml, response, exception = nil, nil, nil

    begin
      response = http_client.get(url)
      xml = Nokogiri::XML(response.body)
    rescue TimeoutError, HTTPClient::ConfigurationError, HTTPClient::BadResponseError, Nokogiri::SyntaxError  => e
        exception = e        
    end
    # error handle
    if ( response.nil? || 
         xml.nil? || 
         exception || 
         (! HTTP::Status.successful? response.status) ||
         (fault = xml.at_xpath("./Fault")))
    
         results.error ||= {}
         results.error[:api_url] = url
         results.error[:exception] = exception if exception
         results.error[:status] = response.status if response
         
         if fault
           results.error[:error_info] = text_if_present fault.at_xpath("./Message")
         end
            
         return results
    end
             
    
    
    # the namespaces they provide are weird and don't help and sometimes
    # not clearly even legal. Remove em!
    xml.remove_namespaces!
    
    results.total_items = xml.at_xpath("./searchResponse/Hits").text.to_i
    
    xml.xpath("./searchResponse/SearchResults/records/rec").each do |xml_rec|
      results << item_from_xml( xml_rec )
    end
    
    return results
    
  end
  
  # pass in nokogiri record xml for the records/rec node. 
  # Returns nil if NO fulltext is avail on ebsco platform, 
  # non-nil if fulltext is available. Non-nil value will
  # actually be a non-empty ARRAY of internal EBSCO codes, P=PDF, T=HTML, C=HTML with images. 
  # http://support.epnet.com/knowledge_base/detail.php?topic=996&id=3778&page=1
  def fulltext_formats(record_xml)
    fulltext_formats = record_xml.xpath("./header/controlInfo/artinfo/formats/fmt/@type").collect {|n| n.text }
    
    return nil if fulltext_formats.empty?
    
    return fulltext_formats    
  end
  
  
  # Pass in a nokogiri node, return node.text, or nil if
  # arg was nil or node.text was blank?
  def text_if_present(node)
    if node.nil? || node.text.blank?
      nil
    else
      node.text
    end    
  end
  
  # Figure out proper controlled format for an ebsco item. 
  # EBSCOHost (not sure about EDS) publication/document type
  # are totally unusable non-normalized vocabulary for controlled
  # types, we'll try to guess from other metadata features.   
  def sniff_format(xml_node)
    return nil if xml_node.nil?
    

    if xml_node.at_xpath("./jinfo/*") && xml_node.at_xpath("./artinfo/*")
      "Article"
    elsif xml_node.at_xpath("./bkinfo/*")
      "Book"
    elsif xml_node.at_xpath("./dissinfo/*")
      :dissertation
    elsif xml_node.at_xpath("./jinfo/*")
      :serial
    else
      nil
    end    
  end
  
  # Figure out uncontrolled literal string format to show to users.
  # We're going to try combining Ebsco Publication Type and Document Type,
  # when both are present. Then a few hard-coded special transformations. 
  def sniff_format_str(xml_node)  
    pubtype = text_if_present( xml_node.at_xpath("./artinfo/pubtype") )
    doctype = text_if_present( xml_node.at_xpath("./artinfo/doctype") )
    
    components = []
    components.push pubtype
    components.push doctype unless doctype == pubtype
    
    components.compact!
    
    components = components.collect {|a| a.titlecase if a}
    components.uniq! # no need to have the same thing twice

    # some hard-coded cases for better user-displayable string, and other
    # normalization. 
    if ["Academic Journal", "Journal"].include?(components.first) && ["Article", "Journal Article"].include?(components.last)
      return "Journal Article"
    elsif components.first == "Periodical" && components.length > 1
      return components.last
    elsif components.size == 2 && components.first.include?(components.last)
      # last is strict substring, don't need it
      return components.first
    elsif components.size == 2 && components.last.include?(components.first)
      # first is strict substring, don't need it
      return components.last
    end
    
    
    
    return components.join(": ")
  end
  
  # pass in <rec> nokogiri, will determine best link
  def get_link(xml)
    text_if_present(xml.at_xpath("./pdfLink")) || text_if_present(xml.at_xpath("./plink") )
  end
  
  
  # escape or replace special chars to ebsco 
  def ebsco_query_escape(txt)
    # it's unclear if ebsco API actually allows escaping of special chars,
    # or what the special chars are. But we know parens are special, can't
    # escape em, we'll just remove em (should not effect search).
    
    # undocumented but question mark seems to cause a problem for ebsco,
    # even inside quoted phrases, not sure why. 
    txt = txt.gsub(/[)(\?]/, ' ')
    
    # 'and' and 'or' need to be in phrase quotes to avoid being
    # interpreted as boolean. For instance, when people just
    # paste in a title: << A strategy for decreasing anxiety of ICU transfer patients and their families >>
    # You'd think 'and' as boolean would still work there, but it resulted
    # in zero hits unless quoted, I dunno. lowercase and uppercase and/or/not
    # both cause observed weirdness. 
    if ['and', 'or', 'not'].include?( txt.downcase )
      txt = %Q{"#{txt}"}
    end    
    
    return txt
  end
  
  # Actually turn the user's query into an EBSCO "AND" boolean query,
  # seems only way to get decent results where terms can match cross-fields
  # at the moment, for EIT. We'll see for EDS. 
  def ebsco_query_prepare(txt)
    # use string split with regex cleverly to split into space
    # seperated terms and phrases, keeping phrases as unit. 
    terms = txt.split %r{[[:space:]]+|("[^"]+")}

    # Remove parens in non-phrase-quoted terms
    terms = terms.collect do |t| 
      ebsco_query_escape(t)      
    end
    

    # Remove empty strings. Remove terms that are solely punctuation
    # without any letters. 
    terms.delete_if do |term|
      ( 
        term.blank? || 
        term =~ /\A[^[[:alnum:]]]+\Z/
      )
    end
    
    terms.join(" AND ")    
  end
  
  def query_url(args)
    
    url = 
      "#{configuration.base_url}/Search?prof=#{configuration.profile_id}&pwd=#{configuration.profile_password}"
    
    query = ebsco_query_prepare  args[:query]  
    
    
    # wrap in (FI $query) if fielded search
    if args[:search_field]
      query = "(#{args[:search_field]} #{query})"
    end
    
    url += "&query=#{CGI.escape query}"
    
    # startrec is 1-based for ebsco, not 0-based like for us. 
    url += "&startrec=#{args[:start] + 1}" if args[:start]
    url += "&numrec=#{args[:per_page]}" if args[:per_page]
    
    # Make relevance our default sort, rather than EBSCO's date. 
    args[:sort] ||= "relevance"
    url += "&sort=#{ sort_definitions[args[:sort]][:implementation]}"
    
    # Contrary to docs, don't pass these comma-seperated, pass em in seperate
    # query params. 
    configuration.databases.each do |db|
      url += "&db=#{db}"
    end    

    return url
  end
  
  # pass in a nokogiri representing an EBSCO <rec> result,
  # we'll turn it into a BentoSearch::ResultItem. 
  def item_from_xml(xml_rec)        
    info = xml_rec.at_xpath("./header/controlInfo")
    
    item = BentoSearch::ResultItem.new
    
    item.link           = get_link(xml_rec)

    item.issn           = text_if_present info.at_xpath("./jinfo/issn")

    item.journal_title  = text_if_present(info.at_xpath("./jinfo/jtl"))
    item.publisher      = text_if_present info.at_xpath("./pubinfo/pub")
    # if no publisher, but a dissertation institution, use that
    # as publisher. 
    unless item.publisher
      item.publisher    = text_if_present info.at_xpath("./dissinfo/dissinst")
    end
    
    
    # Might have multiple ISBN's in record, just take first for now
    item.isbn           = text_if_present info.at_xpath("./bkinfo/isbn")
    
    item.year           = text_if_present info.at_xpath("./pubinfo/dt/@year")
    # fill in complete publication_date too only if we've got it. 
    if (item.year &&
        month = text_if_present(info.at_xpath("./pubinfo/dt/@month")) &&
        day = text_if_present(info.at_xpath("./pubinfo/dt/@day"))      
      )
      if (item.year.to_i != 0 && month.to_i != 0 && day.to_i != 0)
        item.publication_date = Date.new(item.year.to_i, month.to_i, day.to_i)
      end
    end
    
    item.volume         = text_if_present info.at_xpath("./pubinfo/vid")
    item.issue          = text_if_present info.at_xpath("./pubinfo/iid")
    
    
    item.title          = text_if_present info.at_xpath("./artinfo/tig/atl")
    # sometimes title is bizarrely not present there, but in bkinfo instead
    unless item.title
      item.title        = text_if_present info.at_xpath("./bkinfo/btl")
    end
    # EBSCO sometimes has crazy long titles, truncate em.
    if item.title.present?
      item.title        = text_helper.truncate(item.title, :length => 200, :separator => ' ', :omission => '…')
    end
    
    item.start_page     = text_if_present info.at_xpath("./artinfo/ppf")
    
    item.doi            = text_if_present info.at_xpath("./artinfo/ui[@type='doi']")
    
    item.abstract       = text_if_present info.at_xpath("./artinfo/ab")
    # EBSCO abstracts have an annoying habit of beginning with "Abstract:"
    if item.abstract
      item.abstract.gsub!(/^Abstract\: /, "")
    end
    
    # authors, only get full display name from EBSCO. 
    info.xpath("./artinfo/aug/au").each do |author|
      a = BentoSearch::Author.new(:display => author.text)
      item.authors << a
    end
   
    item.format          = sniff_format info
    item.format_str      = sniff_format_str info
    
    # Totally unreliable, seems to report english for everything? Maybe
    # because abstracts are in english? Nevertheless we include for now.
    item.language_code   = text_if_present info.at_xpath("./language/@code")
    
    # array of custom ebsco codes (or nil) for fulltext formats avail. 
    item.custom_data["fulltext_formats"] = fulltext_formats xml_rec
    
    
    return item
  end
  
  # This method is not used for normal searching, but can be used by
  # other code to retrieve the results of the EBSCO API Info command, 
  # using connection details configured in this engine. The Info command
  # can tell you what databases your account is authorized to see.
  # Returns the complete Nokogiri response, but WITH NAMESPACES REMOVED
  def get_info
    url = 
      "#{configuration.base_url}/Info?prof=#{configuration.profile_id}&pwd=#{configuration.profile_password}"    
    
    noko = Nokogiri::XML( http_client.get( url ).body )
    
    noko.remove_namespaces!
    
    return noko
  end
  
  # David Walker says pretty much only relevance and date are realiable
  # in EBSCOhost cross-search. 
  def sort_definitions
    { 
      "relevance" => {:implementation => "relevance"},
      "date_desc" => {:implementation => "date"}
    }      
  end
  
  def search_field_definitions
    {
      "AU"    => {:semantic => :author},
      "TI"    => {:semantic => :title},
      "SU"    => {:semantic => :subject},
      "IS"    => {:semantic => :issn},
      "IB"    => {:semantic => :isbn}
    }
  end
  
  def max_per_page
    # Actually only '50' if you ask for 'full' records, but I don't think
    # we need to do that ever, that's actually getting fulltext back! 
    200
  end
  
  def self.required_configuration
    ["profile_id", "profile_password"]
  end
  
  def self.default_configuration
    {
      # /Search
      :base_url => "http://eit.ebscohost.com/Services/SearchService.asmx",
      :databases => []
    }
  end
  
end
