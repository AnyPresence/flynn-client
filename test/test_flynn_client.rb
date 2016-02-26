require 'test/unit'
require 'flynn_client'
class FlynnClientTest < Test::Unit::TestCase
  def test_flynn_client_instantiation
    assert_nothing_raised do
      FlynnClient::Client.new("flynn.test.com", '', 'token', true)
    end
  end
end
