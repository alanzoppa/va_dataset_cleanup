require "va_dataset_cleanup/version"
require 'csv'
require 'google_places'
require 'uri'
require 'open-uri'
require 'ostruct'
require 'street_address'
require 'lob'

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
      @searchable = cleaned_name(true) + ' ' + self['Address']
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

  def cleaned_name(simple=false)
    name = self['Condo Name (ID)']
    patterns = [
      / \(\d{5,7}\)/,
    ]
    unless simple
      patterns << / \(#{details_from_zip['state_cd']}\d{3,5}\)/
    end
    patterns.each do |pattern|
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
      refined_candidates = candidates.map do |candidate|
        found = $ZIP_VALIDATOR.data.find do |entry|
          entry['zip'] == candidate && entry['state_cd'] == extracted_state
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

  def _validate_extracted_state!(identified_states)
    if identified_states.length > 1
      identified_states.delete_if {|state| ['IN', 'OH', 'CT', 'DE', 'CO'].include? state }
    end
    if identified_states.length > 1
      raise "Found too many states"
    elsif identified_states.length == 0
      raise "Found no states"
    end
    identified_states
  end

  def _extract_states_raw(searchable)
    identified_states = $ZIP_VALIDATOR.states.map do |state|
      searchable.scan /\b#{state}\b/
    end.flatten
  end

  def extracted_state
    identified_states = _extract_states_raw(searchable)
    identified_states = _validate_extracted_state!(identified_states)
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

  def _build_street_address_string(a)
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

  def complete_street_address
    unless defined? @complete_street_address
      if best_strategy_street_address.nil?
        #binding.pry
        #return "---failed: #{cleaned_name} #{cleaned_address}"
        #return strategies
        @complete_street_address = nil
      else
        @complete_street_address = _build_street_address_string(
          best_strategy_street_address
        )
      end
    end
    @complete_street_address
  end

  def has_nested_addresses?
    components = best_strategy_street_address.number.split('-')
    all_are_numbers = components.all? {|c| c == c.to_i.to_s}
    has_complete_street_address? && all_are_numbers && components.length == 2
  end

  def _left_padding(a,b) a[0..-b.length-1] end

  def addresses
    if has_nested_addresses?
      a, b = best_strategy_street_address.number.split('-')
      if a.length == b.length
        low, high = [a,b].map(&:to_i)
      else
        left_padding = _left_padding(a,b)
        low, high = a.to_i, "#{left_padding}#{b}".to_i
      end
      house_numbers = (low..high).step(2).to_a
      house_numbers.map! do |number|
        cpy = best_strategy_street_address.clone
        cpy.number = number.to_s
        lob_hash_copy = lob_api_hash.clone
        lob_hash_copy[:address_line1] = _build_street_address_string(cpy)
        lob_hash_copy
      end
      return house_numbers
    else
      return [lob_api_hash]
    end
  end

  def has_complete_street_address?
    resolvable? && !complete_street_address.nil?
  end

  def lob_api_hash
    if has_complete_street_address?
      return {
        address_line1: complete_street_address,
        address_city: extracted_city,
        address_state: extracted_state,
        address_zip: details_from_zip['zip']
      }
    end
  end

  #def verifiable_attrs
    #return nil unless resolvable?
    #out = {}
    #[
      #['zipcode', 'zip'],
      #['city', 'city'],
      #['state', 'state'],
    #].each do |api_key, key|
      #out[api_key] = details_from_zip[key] unless details_from_zip[key].nil?
    #end
    #out['street'] = street_address_only
    #out['addressee'] = cleaned_name
    #out
  #end

end

class VaDatasetCleanup
  attr_accessor :data


  def initialize(filepath)
    @config = YAML.load(File.open('./config.yml', 'r').read)
    @lob = Lob::Client.new(api_key: @config['lob_key'])
    @data = []
    CSV.foreach(filepath) do |row|
      unless defined? @header
        @header = row
        next
      end
      datum = @header.zip(row).to_h
      datum.delete(nil)
      datum.keys.each_with_index do |key, i|
        datum[key].tr!(" ", " ")
        unless datum[key].nil?
          datum[key] = datum[key].strip
        end
        datum['index'] = i
      end
      @data << VaDatum.new(datum)
    end
    @zip_validator = $ZIP_VALIDATOR
  end

  def lob_response(obj)
    @lob.addresses.verify(obj.lob_api_hash) if obj.has_complete_street_address?
  end

  def cleaned_data
    unless defined? @cleaned_data
      @cleaned_data = @data.select {|d| d.resolvable?}
    end
    @cleaned_data
  end

end
