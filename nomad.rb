require 'nomad'
require 'net/ssh/gateway'

class Result
  RESULT_TYPE = { error: 'error', ok: 'ok' }.freeze
  attr_reader :data

  def initialize(status:, data:)
    @status = status
    @data = data
  end

  def self.ok(data = {})
    new(status: RESULT_TYPE[:ok], data: data)
  end

  def self.error(data = {})
    new(status: RESULT_TYPE[:error], data: data)
  end

  def ok?
    @status == RESULT_TYPE[:ok]
  end

  def error?
    @status == RESULT_TYPE[:error]
  end
end

class NomadJobExecutor
  attr_reader :host, :user
  def initialize(host:, user:)
    @host = host
    @user = user
  end

  def gateway
    @gateway ||= Net::SSH::Gateway.new(host, user, {
      keys: ['/id_rsa']
    })
  end

  def client
    gw_open do |port|
      original_client = Nomad::Client.new(address: "http://localhost:#{port}")
      client = ExtendedNomadClient.new(original_client)
      yield client
    end
  end

  def gw_open
    gateway.open('localhost', 4646) do |port|
      yield port
    end
  end


end

class ExtendedNomadClient
  def initialize(original_client)
    @client = original_client
  end

  def get_until(path, params, headers, wait_clause, error_clause = Proc.new { |r| })
    req_until(:get, path, params, headers, wait_clause, error_clause)
  end

  def post_until(path, params, headers, wait_clause, error_clause = Proc.new { |r| })
    req_until(:post, path, params, headers, wait_clause, error_clause)
  end

  def req_until(verb, path, params, headers, wait_clause, error_clause)
    loop do
      response = send(verb, path, params, headers)
      return Result.ok(data: response) if wait_clause.call(response)
      return Result.error(data: response) if error_clause.call(response)

      puts('Waiting')
      sleep 1
    end
  end

  def get_job(job_name, options = {})
    get("/v1/job/#{job_name}")
  rescue ::Nomad::HTTPError
    puts 'Job not found in remote Nomad server, will try run it remotely and retry'
    gateway.ssh(options[:related_service], user, keys: ['/id_rsa']) do |ssh|
      puts "Executing `nomad run /etc/nomad/jobs.d/#{job_name}.nomad` in remote location"

      # FIXME: Generic
      job_spec = ssh.exec!("cat /etc/nomad/jobs.d/#{job_name}.nomad")
      post('/v1/jobs/parse', {'JobHCL' => job_spec}.to_json)
    end
  rescue ::Nomad::HTTPError
    puts 'Job not found and in remote Nomad server'
  end

  def update_image(job:, image:, tag:)
    job[:TaskGroups].each do |task_group|
      task_group[:Tasks].each do |task|
        task[:Config][:image] = "#{image}:#{tag}"

        # FIXME: Generic
        task[:Env] ||= {}
        task[:Env][:DD_VERSION] = tag
        task[:Env][:RELEASE_VERSION] = tag
      end
    end
    job
  end

  def set_deployed_info(job:, user: nil, branch: nil)
    # FIXME: Generic
    job[:Meta] ||= {}
    job[:Meta]['deploy-user'] = user if user
    job[:Meta]['deploy-branch'] = branch if branch
    job[:Meta]['deploy-at'] = Time.now.strftime("%Y-%m-%d %H:%M:%S %Z")
    job
  end

  def versions(job_name)
    get("/v1/job/#{job_name}/versions")[:Versions]
  end

  # Updates a job and changes its images to the one being deployed
  def deploy!(
    job:,
    wait_status:,
    wait_task_group:
  )
    response = post("/v1/job/#{job['Name']}", { 'Job' => job , 'EnforceIndex' => job['JobModifyIndex'] }.to_json)
    return Result.ok(response) if wait_status.empty?

    eval_id = response[:EvalID]
    get_until("/v1/evaluation/#{eval_id}", {}, {}, proc { |r| r[:Status] == 'complete' })
    allocations = get("/v1/evaluation/#{eval_id}/allocations").filter do |allocation|
      next true if wait_task_group.empty?

      allocation[:TaskGroup] == wait_task_group
    end

    if allocations.empty?
      puts 'Nothing was run'
      return Result.error('Nothing was run')
    end

    allocations.each do |allocation|
      result = get_until(
        "/v1/allocation/#{allocation[:ID]}",
        {},
        {},
        proc { |r| r[:ClientStatus] == wait_status },
        proc { |r| r[:ClientStatus] == 'failed' }
      )
      return job_error_result(result.data) if result.error?
    end
    Result.ok
  end

  def job_error_result(result)
    begin
      error_data = nil
      if result && result.respond_to?(:key?) && result.key?(:data)
        allocation = result[:data]
        tasks = allocation[:TaskStates].keys.map(&:to_s)
        error_data = tasks.map do |task_name|
          [
            task_name, {
              stdout: allocation_log(allocation_id: allocation[:ID],task_name: task_name, type: 'stdout'),
              stderr: allocation_log(allocation_id: allocation[:ID],task_name: task_name, type: 'stderr'),
            }
          ]
        end.to_h
      else
        puts 'There was an error with the allocation'
        error_data = result.inspect
      end
      Result.error(error_data)
    end
  end

  private

  def allocation_log(allocation_id:, task_name:, type:)
    data = get("/v1/client/fs/logs/#{allocation_id}?type=#{type}&task=#{task_name}")[:Data]
    Base64.decode64(data)
  rescue ::Nomad::HTTPClientError,::JSON::ParserError => e
    puts 'There was an error trying to obtain allocation log'
    puts e.inspect
    ''
  end

  def method_missing(method, *args)
    @client.send(method, *args)
  end
end
