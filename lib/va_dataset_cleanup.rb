require "va_dataset_cleanup/version"
require 'csv'
require 'google_places'
require 'uri'
require 'open-uri'
require 'ostruct'

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



class VaDatum < OpenStruct
  def searchable
    unless defined? @searchable
      @searchable = self['Condo Name (ID)'] + ' ' + self['Address']
    end
    @searchable
  end

  def extracted_zip(zip_validator)
    candidates = searchable.scan(/\b\d{5}\b/)
    if candidates.length == 0
      raise "No candidate zips found"
    elsif candidates.length > 1
      state = extracted_state(zip_validator)
      refined_candidates = candidates.map do |candidate|
        found = zip_validator.data.find do |entry|
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

  def extracted_state(zip_validator)
    identified_states = zip_validator.states.map do |state|
      searchable.scan /\b#{state}\b/
    end.flatten
    if identified_states.length > 1
      raise "Found too many states"
    elsif identified_states.length == 0
      raise "Found no states"
    end
    return identified_states[0]
  end

  def details_from_zip(zip_validator)
    zip_validator.find_by_zip(extracted_zip(zip_validator))
  end
end

class VaDatasetCleanup
  attr_accessor :data, :zip_validator


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
      @data << VaDatum.new(datum)
    end
    @zip_validator = ZipValidator.new
  end

  def smartystreets_url(query={})
    uri = 'https://us-street.api.smartystreets.com/street-address?'
    uri+URI.encode_www_form(@smartystreets_params.merge(query))
  end

end
