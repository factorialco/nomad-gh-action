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
    @client ||= TunneledClient.new(self)
  end

  def gw_open
    gateway.open('nomad.service.consul', 4646, 4646) do
      yield
    end
  end

  def job(job_name, options = {})
    client.get("/v1/job/#{job_name}")
  rescue ::Nomad::HTTPError
    puts 'Job not found in remote Nomad server, will try run it remotely and retry'
    gateway.ssh(options[:related_service], user, keys: ['/id_rsa']) do |ssh|
      puts "Executing `nomad run /etc/nomad/jobs.d/#{job_name}.nomad` in remote location"

      # FIXME: Generic
      job_spec = ssh.exec!("cat /etc/nomad/jobs.d/#{job_name}.nomad")
      client.post('/v1/jobs/parse', {'JobHCL' => job_spec}.to_json)
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
    client.get("/v1/job/#{job_name}/versions")[:Versions]
  end

  # Updates a job and changes its images to the one being deployed
  def deploy!(
    job:,
    wait:
  )
    response = client.post("/v1/job/#{job['Name']}", { 'Job' => job , 'EnforceIndex' => job['JobModifyIndex'] }.to_json)
    return Result.ok(response) if wait.empty?

    eval_id = response[:EvalID]
    client.get_until("/v1/evaluation/#{eval_id}", {}, {}, proc { |r| p "Get evaluation #{eval_id}"; p r["Name"]; p r[:JobID]; p r[:Status]; r[:Status] == wait })
    allocations = client.get("/v1/evaluation/#{eval_id}/allocations")

    if allocations.empty?
      puts 'Nothing was run'
      return Result.error('Nothing was run')
    end

    allocations.each do |allocation|
      result = client.get_until(
        "/v1/allocation/#{allocation[:ID]}",
        {},
        {},
        proc { |r| "Get allocation #{allocation[:ID]}"; p r["Name"]; p r[:JobID]; p r[:Status]; r[:ClientStatus] == 'complete' },
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
    data = client.get("/v1/client/fs/logs/#{allocation_id}?type=#{type}&task=#{task_name}")[:Data]
    Base64.decode64(data)
  rescue ::Nomad::HTTPClientError,::JSON::ParserError => e
    puts 'There was an error trying to obtain allocation log'
    puts e.inspect
    ''
  end

end

class TunneledClient
  def initialize(caller_object)
    @caller_object = caller_object
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

  # We call Nomad::Client, but wrapping the call in a tunnel so we can ssh to the host
  # before making the call
  def method_missing(method, *args)
    @caller_object.gw_open { ::Nomad.client.send(method, *args) }
  end
end
