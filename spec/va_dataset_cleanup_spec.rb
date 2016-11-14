require "spec_helper"
require 'yaml'
require 'vcr'
require 'pry'

VCR.configure do |config|
  config.cassette_library_dir = "fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
end



describe VaDatasetCleanup do
  before(:all) do
    @config = YAML.load(File.open('./config.yml', 'r').read)
    @va = VaDatasetCleanup.new(
      './va_sample.csv',
    )
  end
  it "has a version number" do
    expect(VaDatasetCleanup::VERSION).not_to be nil
  end

  #it "prints the data just becasuse" do
    #@va.data.each do |datum|
      #print datum.to_h.to_yaml
    #end
  #end

  it "can find details of a zip" do
    expected = {
      "zip"=>"60622",
      "city"=>"Chicago",
      "state"=>"Illinois",
      "state_cd"=>"IL",
      "county"=>"Cook",
      "latitude"=>"41.9019",
      "longitude"=>"-87.6778",
    }
    actual = $ZIP_VALIDATOR.find_by_zip(60622)
    expected.keys.each do |key|
      expect(expected[key]).to eql actual[key]
    end
  end

  it 'should be able to identify a state' do
    expect(@va.data[0].extracted_state).to eql "IL"
  end

  it 'should be able to identify a zip' do
    expect(@va.data[0].extracted_zip).to eql "60607"
  end

  it 'should be able to reconcile multiple zips' do
    # 01008 is not in Illinois
    datum = VaDatum.new(
      {'Condo Name (ID)' => "foo bar 60607", 'Address' => "baz 01008 IL stuff"}
    )
    expect(datum.extracted_zip).to eql "60607"
  end

  it 'should be able to deal with multiple occurences of a zip' do
    datum = VaDatum.new(
      {'Condo Name (ID)' => "foo bar 60607", 'Address' => "baz 60607 IL stuff"}
    )
    expect(datum.extracted_zip).to eql "60607"
  end



  it 'should be able to find zip detail from the reference data' do
    expect(@va.data[0].details_from_zip).to eql(
      {
        "zip"=>"60607",
        "city"=>"Chicago",
        "state"=>"Illinois",
        "state_cd"=>"IL",
        "county"=>"Cook",
        "latitude"=>"41.8721",
        "longitude"=>"-87.6578"
      }
    )
  end

  it 'should extract the city' do
    expect(@va.data[0].extracted_city).to eql "Chicago"
  end

  it 'should fix va-specific weirdness' do
    expect(@va.data[0].cleaned_address).to eql(
      "1000 W WASHINGTON BLVD CHICAGO IL 60607 COOK"
    )
  end

  it "should refine out known data points to va quirks" do
    expect(@va.data[0].street_address_only).to eql(
      "1000 W WASHINGTON BLVD"
    )
  end

  it 'should create an Lob API-ready hash' do
    expect(@va.data[0].lob_api_hash).to eql(
      {
        address_line1: "1000 W WASHINGTON Blvd",
        address_city: "Chicago",
        address_state: "IL",
        address_zip: "60607"
      }
    )
  end

  it 'should return a version of the address without the county' do
    expect(@va.data[3].street_address_without_county).to eql(
      "1015 W JACKSON BLVD CHICAGO IL 60607"
    )
  end

  it 'should try to guess the street address from the condo name' do
    expect(@va.data[1].address_from_name).to eql "1001 MADISON"
  end

  context "Lob API", :vcr do
    it 'should get some data from Lob' do
      expected = {
        "address" => {
          "address_line1" => "1000 W WASHINGTON BLVD",
          "address_line2" => "",
          "address_city" => "CHICAGO",
          "address_state" => "IL",
          "address_zip" => "60607-2137",
          "address_country" => "US",
          "object" => "address"
        },
       "message" => "Default address: The address you entered was found but more information is needed (such as an apartment, suite, or box number) to match to a specific address."
      }
      actual = @va.lob_response(@va.data[0])
      expect(expected).to eql actual
    end
  end



  it 'should figure out the street address' do
    @va.data.each do |datum|
      if datum.has_complete_street_address?
        puts datum.complete_street_address
        puts datum.addresses
      end
    end
  end

end

describe ZipValidator do
  before (:all) do
    @zv = ZipValidator.new
  end
  it 'Should know all states' do
    expected = [
      "AA", "AK", "AL", "AP", "AR", "AZ", "CA", "CO", "CT", "DC", "DE", "FL",
      "FM", "GA", "GU", "HI", "IA", "ID", "IL", "IN", "KS", "KY", "LA", "MA",
      "MD", "ME", "MH ", "MI", "MN", "MO", "MP ", "MS", "MT", "NC", "ND", "NE",
      "NH", "NJ", "NM", "NV", "NY", "OH", "OK", "OR", "PA", "PW ", "RI", "SC",
      "SD", "TN", "TX", "UT", "VA", "VT", "WA", "WI", "WV", "WY"
    ]
    expect(@zv.states).to eql expected
  end


  it 'Should know all cities' do
    expect(@zv.cities.length).to eql 19219
    expect(@zv.cities[100]).to eql 'Ahsahka'
  end

  it "should not freak out when you search a bogus zip" do
    expect(@zv.find_by_zip(00000)).to be_nil
  end

end
