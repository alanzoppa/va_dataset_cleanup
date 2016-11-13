require "va_dataset_cleanup/version"
require 'csv'
require 'google_places'
require 'uri'
require 'open-uri'
require 'ostruct'
require 'street_address'

class ZipValidator
  attr_accessor :data

  def initialize
    @data = []
    CSV.foreach('./us_postal_codes.csv') do |row|
      unless defined? @header
        @header = row
        next
      end
      @data << @header.zip(row).to_h
    end
  end

  def _uniq_per_datum(key, shorthand)
    unless self.instance_variable_defined?("@#{shorthand}")
      #binding.pry
      self.instance_variable_set(
        "@#{shorthand}",
        self.data.map { |datum| datum[key]}.uniq.compact.sort
      )
    end
    self.instance_variable_get("@#{shorthand}")
  end

  def states
    _uniq_per_datum('state_cd', 'states')
  end

  def cities
    _uniq_per_datum('city', 'cities')
  end



  def find_by_zip zip
    @data.find do |entry|
      entry['zip'] == zip.to_s
    end
  end

end

$ZIP_VALIDATOR = ZipValidator.new

class VaDatum < OpenStruct
  def searchable
    unless defined? @searchable
      @searchable = self['Condo Name (ID)'] + ' ' + self['Address']
    end
    @searchable
  end

  def _removable_street_address_patterns
    d = details_from_zip
    [
      /#{d['city']} #{d['state_cd']} #{d['zip']}.-..0000/i,
      /#{d['city']} #{d['state_cd']} #{d['zip']} #{d['county']}/i,
      / USA\s*$/i
    ]
  end

  def cleaned_name
    name = self['Condo Name (ID)']
    [
      / \(\d{5,7}\)/,
      / \(#{details_from_zip['state_cd']}\d{3,5}\)/
    ].each do |pattern|
      name.gsub! pattern, ''
    end
    name
  end

  def street_address_only
    addr = cleaned_address
    _removable_street_address_patterns.each do |r|
      addr.gsub!(r, "")
    end
    addr.strip
  end

  def street_address_without_county
    cleaned_address.gsub(
      / #{details_from_zip['county']}/i,
      ''
    )
  end

  def address_from_name
    name = cleaned_name
    [
      / condo.*/i
    ].each do |pattern|
      name.gsub! pattern, ''
    end
    name
  end

  def cleaned_address
    # VA-specific data entry quirk
    address = self['Address']
    pattern = /(\w)(#{Regexp.escape(extracted_city)})\b/i
    address.gsub!(pattern, '\1 \2')
    address.strip
  end

  def extracted_zip
    candidates = searchable.scan(/\b\d{5}\b/)
    if candidates.length == 0
      raise "No candidate zips found"
    elsif candidates.length > 1
      state = extracted_state
      refined_candidates = candidates.map do |candidate|
        found = $ZIP_VALIDATOR.data.find do |entry|
          entry['zip'] == candidate && entry['state_cd'] == state
        end
        unless found.nil?
          found['zip']
        end
      end
      refined_candidates = refined_candidates.compact.uniq
      if refined_candidates.length != 1
        binding.pry
        raise "Can't refine candidate zips"
      end
    end
    candidates[0]
  end

  def extracted_state
    identified_states = $ZIP_VALIDATOR.states.map do |state|
      searchable.scan /\b#{state}\b/
    end.flatten
    if identified_states.length > 1
      raise "Found too many states"
    elsif identified_states.length == 0
      raise "Found no states"
    end
    return identified_states[0]
  end

  def extracted_city
    details_from_zip['city']
  end

  def details_from_zip
    unless defined? @details_from_zip
      @details_from_zip = $ZIP_VALIDATOR.find_by_zip(
        extracted_zip
      )
    end
    @details_from_zip
  end

  def resolvable?
    !details_from_zip.nil?
  end

  def street_address_strategies
    [ street_address_only,
      street_address_without_county,
      address_from_name,
      cleaned_name,
      cleaned_address,
      cleaned_name+' '+cleaned_address,
    ].map do |address|
      StreetAddress::US.parse_informal_address(address)
    end.compact
  end

  def best_strategy_street_address
    unless defined? @best_strategy_street_address
      @best_strategy_street_address = street_address_strategies.find do |address|
        !address.number.nil? && !address.street.nil?
      end
    end
    @best_strategy_street_address
  end

  def reconstructed_street_address
    if best_strategy_street_address.nil?
      #binding.pry
      return "---failed: #{cleaned_name} #{cleaned_address}"
      #return strategies
    else
      a = best_strategy_street_address
      out = ""
      out << "#{a.number} "
      if a.prefix
        out << "#{a.prefix} "
      end
      out << "#{a.street} "
      if a.street_type
        out << "#{a.street_type} "
      end
      return out.strip
    end
  end

  def verifiable_attrs
    return nil unless resolvable?
    out = {}
    [
      ['zipcode', 'zip'],
      ['city', 'city'],
      ['state', 'state'],
    ].each do |api_key, key|
      out[api_key] = details_from_zip[key] unless details_from_zip[key].nil?
    end
    out['street'] = street_address_only
    out['addressee'] = cleaned_name
    out
  end

end

class VaDatasetCleanup
  attr_accessor :data


  def initialize(filepath, smartystreets_params)
    @smartystreets_params = smartystreets_params
    @data = []
    CSV.foreach(filepath) do |row|
      unless defined? @header
        @header = row
        next
      end
      datum = @header.zip(row).to_h
      datum.delete(nil)
      datum.keys.each do |key|
        datum[key].tr!(" ", " ")
        unless datum[key].nil?
          datum[key] = datum[key].strip
        end
      end
      @data << VaDatum.new(datum)
    end
    @zip_validator = $ZIP_VALIDATOR
  end

  def cleaned_data
    unless defined? @cleaned_data
      @cleaned_data = @data.select {|d| d.resolvable?}
    end
    @cleaned_data
  end

  def smartystreets_url(query={})
    uri = 'https://us-street.api.smartystreets.com/street-address?'
    uri+URI.encode_www_form(@smartystreets_params.merge(query))
  end

end
