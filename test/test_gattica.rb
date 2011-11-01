require File.dirname(__FILE__) + '/helper'
 
class TestUser < Test::Unit::TestCase
  def test_build_query_string
    @gattica = Gattica.new(:token => 'ga-token', :profile_id => 'ga-profile_id')
    expected = "ids=ga:ga-profile_id&start-date=2008-01-02&end-date=2008-01-03&dimensions=ga:pageTitle,ga:pagePath&metrics=ga:pageviews&sort=-ga:pageviews&max-results=3"
    result = @gattica.send(:build_query_string, {
      :start_date => Date.civil(2008,1,2), 
      :end_date => Date.civil(2008,1,3),
      :dimensions => ['pageTitle','pagePath'], 
      :metrics => ['pageviews'], 
      :sort => '-pageviews',
      :max_results => '3'}, 'ga-profile_id')
    assert_equal expected, result
  end
end
