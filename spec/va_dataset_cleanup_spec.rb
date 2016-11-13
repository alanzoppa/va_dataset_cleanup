require "spec_helper"
require 'yaml'
require 'pry'

describe VaDatasetCleanup do
  before(:all) do
    @config = YAML.load(File.open('./config.yml', 'r').read)
    @va = VaDatasetCleanup.new(
      './va_sample.csv',
      @config['smartystreets_params']
    )
  end
  it "has a version number" do
    expect(VaDatasetCleanup::VERSION).not_to be nil
  end

  it "creates smartystreets urls" do
    p @va.smartystreets_url
  end

  it "prints the data just becasuse" do
    @va.data.each do |datum|
      print datum.to_h.to_yaml
      #print ['Condo Name (ID)', 'Address'].map {|k| [k, datum[k]]}.to_h.to_yaml
    end
  end

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

  #it 'should create an API-ready hash' do
    #expect(@va.data[0].verifiable_attrs).to eql(
      #{
        #"zipcode"=>"60607",
        #"city"=>"Chicago",
        #"state"=>"Illinois",
        #"street"=>"1000 WEST WASHINGTON LOFTS 1000 W WASHINGTON BLVD CHICAGO IL 60607 COOK",
      #}
    #)
  #end

  it 'should return a version of the address without the county' do
    expect(@va.data[3].street_address_without_county).to eql(
      "1015 W JACKSON BLVD CHICAGO IL 60607"
    )
  end

  it 'should try to guess the street address from the condo name' do
    expect(@va.data[1].address_from_name).to eql "1001 MADISON"
  end



#1015 W. JACKSON (002496),1015 W JACKSON BLVDCHICAGO IL 60607 COOK ,Accepted Without Conditions,Unavailable,05/02/2016,05/04/2016,559791

  it 'should figure out the street address' do
    @va.data.each do |datum|
      if datum.resolvable?
        puts datum.reconstructed_street_address
      end
    end

    #@va.data[-1].best_strategy_street_address

  end

  #it 'should create an API url' do
    #(0..10).each do |i|
      #puts @va.smartystreets_url(@va.data[i].verifiable_attrs)
    #end
  #end

  #it "should preview some API input" do
    #@va.data.each do |datum|
      #if datum.resolvable?
        #print datum.verifiable_attrs.to_yaml
      #end
    #end
  #end

  #it 'should decide on an address parsing strategy' do
    #out = @va.data[0].street_address_strategies
  #end

#StreetAddress::US.parse("1600 Pennsylvania Ave, Washington, DC, 20500")

  #it "should work on the whole set" do
    #expect(
      #@va.data.map {|d| d.details_from_zip(@va.zip_validator)}.length
    #).to eql 939
  #end

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
