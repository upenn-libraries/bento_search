require 'test_helper'

require 'cgi'
require 'uri'

class EbscoHostEngineTest < ActiveSupport::TestCase
  extend TestWithCassette
  
  @@profile_id = (ENV['EBSCOHOST_PROFILE'] || 'DUMMY_PROFILE')
  @@profile_pwd = (ENV['EBSCOHOST_PWD'] || 'DUMMY_PWD')
  @@dbs_to_test = (ENV['EBSCOHOST_TEST_DBS'] || %w{a9h awn} )
  
  VCR.configure do |c|
    c.filter_sensitive_data("prof=DUMMY_PROFILE", :ebscohost) { "prof=#{@@profile_id}" }
    c.filter_sensitive_data("pwd=DUMMY_PWD", :ebscohost) { "pwd=#{@@profile_pwd}" }
  end
  
  
  def setup
    @config = {
      :profile_id => @@profile_id,
      :profile_password => @@profile_pwd,
      :databases => @@dbs_to_test
    }
    
    @engine = BentoSearch::EbscoHostEngine.new( @config )             
  end
  
  
  def test_url_construction
    url = @engine.query_url(:query => "cancer", :start => 10, :per_page => 5)
    
    assert_present url
    
    query_params = CGI.parse( URI.parse(url).query )

    assert_equal [@engine.configuration.profile_id], query_params["prof"]
    assert_equal [@engine.configuration.profile_password], query_params["pwd"]
    
    assert_equal ["cancer"], query_params["query"]
    
    assert_equal ["5"], query_params["numrec"]
    assert_equal ["11"], query_params["startrec"]
    
    # default sort relevance
    assert_equal ["relevance"], query_params["sort"]
    
    @engine.configuration.databases.each do |db|
      assert_include query_params["db"], db
    end    
  end
  
  def test_date_sort_construction
    url = @engine.query_url(:query => "cancer", :sort => "date_desc")
    
    query_params = CGI.parse( URI.parse(url).query )
    
    assert_equal ["date"], query_params["sort"]
  end
  
  def test_fielded_construction
    url = @engine.query_url(:query => "cancer", :search_field => "SU")
    
    query_params = CGI.parse( URI.parse(url).query )
    
    assert_equal ["(SU cancer)"], query_params["query"]
  end
  
  def test_peer_review_limit_construction
    url = @engine.query_url(:query => "cancer", :search_field => "SU", :peer_reviewed_only => true)
    
    query_params = CGI.parse( URI.parse(url).query )
    
    assert_equal ["(SU cancer) AND (RV Y)"], query_params["query"]
  end
  
  def test_date_limit_construction
    url = @engine.query_url(:query => "cancer", :pubyear_start => "1980", :pubyear_end => "1989")    
    query_params = CGI.parse( URI.parse(url).query )    
    
    assert_equal ["cancer AND (DT 1980-1989)"], query_params["query"]
    
    # just one
    url = @engine.query_url(:query => "cancer", :pubyear_start => "1980")
    query_params = CGI.parse( URI.parse(url).query )    
    
    assert_equal ["cancer AND (DT 1980-)"], query_params["query"]    
    
  end
  
  
  def test_prepare_query
    query = @engine.ebsco_query_prepare('one :. ; two "three four" and NOT OR five')
    
    assert_equal 'one AND two AND "three four" AND "and" AND "NOT" AND "OR" AND five', query
  end
  
  def test_removes_paren_literals
    url = @engine.query_url(:query => "cancer)", :sort => "date_desc")
    
    query_params = CGI.parse( URI.parse(url).query )
    
    assert_equal ["cancer "], query_params["query"]
  end
  
  def test_removes_question_marks
    # who knows why, ebsco doesn't like question marks even inside
    # quoted phrases, some special char to ebsco. 
    url = @engine.query_url(:query => "cancer?", :sort => "date_desc")    
    query_params = CGI.parse( URI.parse(url).query )    
    assert_equal ["cancer "], query_params["query"]
    
    url = @engine.query_url(:query => '"cancer?"', :sort => "date_desc")
    query_params = CGI.parse( URI.parse(url).query )    
    assert_equal ['"cancer "'], query_params["query"]
  end
  
  test_with_cassette("live search smoke test", :ebscohost) do
  
    results = @engine.search(:query => "cancer")
    
    assert_present results
    assert ! results.failed?
    
    first = results.first
    
    assert_present first.title
    assert_present first.authors  
    assert_present first.year
    
    assert_present first.format
    assert_present first.format_str
    
    assert_present first.language_code
    assert_present first.language_str
  end
  
  test_with_cassette("get_info", :ebscohost) do
    xml = @engine.get_info
    
    assert_present xml
    
    assert_present xml.xpath("./info/dbInfo/db")    
  end
  
  test_with_cassette("error bad password", :ebscohost) do    
    error_engine = BentoSearch::EbscoHostEngine.new(
      :profile_id       => "bad",
      :profile_password => "bad",
      :databases        => @@dbs_to_test
      )
    
    results = error_engine.search(:query => "cancer")    
    assert results.failed?    
    assert_present results.error[:error_info]
  end
    
    
  test_with_cassette("error bad db", :ebscohost) do
    error_engine = BentoSearch::EbscoHostEngine.new( 
      :profile_id => @@profile_id,
      :profile_password => @@profile_pwd,
      :databases => ["bad", "does_not_exist"]
    )    
    
    results = error_engine.search(:query => "cancer")    
    assert results.failed?    
    assert_present results.error[:error_info]        
    
  end
  
  test_with_cassette("fulltext info", :ebscohost) do
    # We count on SOME records from first 10 for this query having fulltext,
    # if you need to re-record VCR cassette and this query doesn't work
    # for that anymore, then pick a different query. 
    results = @engine.search("cancer")
    
    results_with_fulltext = results.find_all {|r| r.custom_data["fulltext_formats"] }
    
    assert_present results_with_fulltext
    
    results_with_fulltext.each do |record|
      array = record.custom_data["fulltext_formats"]
      # it's an array
      assert_kind_of Array, array
      # who's only legal values are P, T, and C, the EBSCO vocab for formats. 
      assert_equal array.length, array.find_all {|v| %w{P C T}.include?(v)}.length
    end    
    
  end
    
end
