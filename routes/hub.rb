require 'rest-client'
require 'benchmark'

# one day, when I grow up...I'll be a ruby dev
# hub calls
class Hub

  # obtain remote ip and port from local config
  begin
    # Provision new config if none exists.
    unless File.exist?('config/hub_config.json')
      hub_config = {
          :host => 'hub.hashview.io',
          :port => '8443',
      }
      File.open('config/hub_config.json', 'w') do |f|
        f.write(JSON.pretty_generate(hub_config))
      end
    end

    options = JSON.parse(File.read('config/hub_config.json'))
    @server = options['host'] + ':' + options['port']

    @hub_settings = HubSettings.first
    @auth_key = @hub_settings.auth_key
    if @hub_settings.uuid.nil?
      p 'Generating new UUID'
      uuid = SecureRandom.hex(10)
      # Add hyphens, (i am ashamed at how dumb this is)
      uuid.insert(15, '-')
      uuid.insert(10, '-')
      uuid.insert(5, '-')
      @hub_settings.uuid = uuid
      @hub_settings.save
    end


  rescue
    'Error reading config/hub_config.json. Did you run rake db:provision_agent ???'
  end

  ######### generic api handling of GET and POST request ###########
  def self.get(url)
    begin
      p 'get: ' + url.to_s

      hub_settings = HubSettings.first
      response = RestClient::Request.execute(
        :method => :get,
        :url => url,
        :cookies => {:uuid => hub_settings.uuid, :auth_key => hub_settings.auth_key},
        :verify_ssl => false
      )
      p 'response: ' + response.body.to_s
      return response.body
    rescue RestClient::Exception => e
      return '{"error_msg" : "api call failed"}'
    end
  end

  def self.post(url, payload)
    begin
      p 'post: ' + payload.to_s
      hub_settings = HubSettings.first
      p 'cookie: ' + hub_settings.uuid.to_s + ' ' + hub_settings.auth_key.to_s
      response = RestClient::Request.execute(
        :method => :post,
        :url => url,
        :payload => payload.to_json,
        :headers => {:accept => :json},
        :cookies => {:uuid => hub_settings.uuid, :auth_key => hub_settings.auth_key},
        :verify_ssl => false #TODO VALIDATE!
      )
      p 'response: ' + response.body.to_s
      return response.body
    rescue RestClient::Exception => e
      puts e
      return '{"error_msg": "api call failed"}'
    end
  end

  ######### specific api functions #############

  def self.register(action)
    hub_settings = HubSettings.first
    url = "https://#{@server}/v1/register"
    payload = {}
    payload['action'] = action
    payload['uuid'] = hub_settings.uuid
    payload['email'] = hub_settings.email unless hub_settings.email.nil? || hub_settings.email.empty?
    self.post(url, payload)
  end

  def self.hashSearch(hash)
    url = "https://#{@server}/v1/hashes/search"
    payload = {}
    payload['hash'] = hash
    self.post(url, payload)
  end

  def self.hashReveal(hash, hashtype)
    url = "https://#{@server}/v1/hashes/reveal"
    payload = {}
    payload['hash'] = hash
    payload['hashtype'] = hashtype
    self.post(url, payload)
  end

  def self.hashUpload(hash, plaintext, hashtype)
    url = "https://#{@server}/v1/hashes/upload"
    payload = {}
    payload['hash'] = hash
    payload['plaintext'] = plaintext
    payload['hashtype'] = hashtype
    self.post(url, payload)
  end

  def self.statusAuth()
    url = "https://#{@server}/v1/status/auth"
    payload = {}
    self.post(url, payload)
  end

  def self.statusBalance()
    url = "https://#{@server}/v1/status/balance"
    payload = {}
    self.post(url, payload)
  end
end

### ROUTES #############################################

get '/hub/register' do
  varWash(params)
  hub_settings = HubSettings.first

  response = Hub.register('new')
  response = JSON.parse(response)

  if response['status'] == '200'
    hub_settings.auth_key = response['auth_key']
    hub_settings.status = 'registered'
    hub_settings.email = param[:email] if params[:email]
    hub_settings.save
    flash[:success] = 'Hub registration success.'
  else
    flash[:error] = 'Hub registration failed.'
  end

  redirect to('/settings')
end

# TODO
# Should probably be :hash_id instead of :hash for privacy sake
get '/hub/hash/reveal/:job_id/:hashtype/:hash' do
  varWash(params)

  hub_response = Hub.hashReveal(params[:hash], params[:hashtype])
  hub_response = JSON.parse(hub_response)

  if hub_response['status'] == '200'

    # Add to local db
    entry = Hashes.first(hashtype: params[:hashtype], originalhash: params[:hash])
    if entry.nil?
      new_entry = Hashes.new
      new_entry.lastupdated = Time.now()
      new_entry.originalhash = params[:hash]
      new_entry.hashtype = params[:hashtype]
      new_entry.cracked = '1'
      new_entry.plaintext = hub_response['plaintext']
      new_entry.save
    else
      entry.plaintext = hub_response['plaintext']
      entry.cracked = '1'
      entry.save
    end

    referer = request.referer.split('/')
    # We redirect the user back to where he came
    if referer[3] == 'search'
      # We came from Search we send back to search
      flash[:success] = 'Successfully unlocked hash'
      redirect to('/search')
    elsif referer[3] == 'jobs'
      flash[:success] = 'Unlocked 1 Hash'
      redirect to("/jobs/hub_check?job_id=#{params[:job_id]}")
    else
      p request.referer.to_s
      p referer[3].to_s
    end

  elsif hub_response['status'] == 'error'
    p 'You dun goofed up'
  end
end

get '/hub/hash/reveal/:hashfile_id' do
  varWash(params)

  # TODO verify we have enough credit

  @hashfile_hashes = Hashfilehashes.all(hashfile_id: params[:hashfile_id])
  @hashfile_hashes.each do |entry|
    hash = Hashes.first(id: entry.hash_id, cracked: '0')
    unless hash.nil?
      hub_response = Hub.hashReveal(hash.originalhash)
      hub_response = JSON.parse(hub_response)

      if hub_response['status'] == '200'
        # Add to local db
        entry = Hashes.first(hashtype: hash.hashtype, originalhash: hash.originalhash)
        entry.plaintext = hub_response['plaintext']
        entry.cracked = '1'
        entry.save
      end
    end
  end

  # TODO announce how many were cracked, what the remaining balance is
  referer = request.referer.split('/')
  # We redirect the user back to where he came
  if referer[3] == 'search'
    # We came from Search we send back to search
    flash[:success] = 'Successfully unlocked hash'
    redirect to('/search')
  elsif referer[3] == 'jobs'
    # flash[:success] = 'Unlocked 1 Hash'
    redirect to("/jobs/hub_check?job_id=#{params[:job_id]}")
  else
    p request.referer.to_s
    p referer[3].to_s
  end
end

get '/hub/hash/upload/:id' do

  hash = Hashes.first(id: params[:id], cracked: 1)
  p 'hash: ' + hash.plaintext.to_s
  p 'hash: ' + hash.hashtype.to_s
  p 'hash: ' + hash.originalhash.to_s
  if hash.nil?
    flash[:error] = 'Error uploading hash'
  else
    hub_response = Hub.hashUpload(hash.originalhash, hash.plaintext, hash.hashtype.to_s)
    hub_response = JSON.parse(hub_response)
    flash[:error] = hub_response['message'] if hub_response['status'] != '200'

    referer = request.referer.split('/')
    if referer[3] == 'search'
      flash[:success] = 'Successfully uploaded hash!' if hub_response['status'] == '200'
    end
  end
  # TODO detect referer came from and redirect accordingly
  redirect to('/search')
end

### Functions ##########################################
