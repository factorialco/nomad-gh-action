require './nomad.rb'

class Deploy
  attr_accessor :ssh_user, :ssh_host, :docker_image, :tag, :wait_status, :wait_task_group, :branch_name, :job_name, :nomad_url, :job_related_service

  def initialize(ssh_user:, ssh_host:, docker_image:, tag:, wait_status:, wait_task_group:, branch_name:, job_name:, nomad_url:, job_related_service:)
    @ssh_user = ssh_user
    @ssh_host = ssh_host
    @docker_image = docker_image
    @tag = tag
    @wait_status = wait_status
    @wait_task_group = wait_task_group
    @branch_name = branch_name
    @job_name = job_name
    @nomad_url = nomad_url
    @job_related_service = job_related_service.empty? ? 'nomad.service.consul' : job_related_service
  end

  def run!
    puts "đ  Executing '#{job_name}' job into #{job_related_service} through ssh://#{ssh_user}@#{ssh_host}"
    nomad = NomadJobExecutor.new(host: ssh_host, user: ssh_user)

    puts "âšī¸ You can check the progress in #{nomad_url}"
    job = nomad.update_image(image: docker_image, tag: tag, job: nomad.job(job_name, related_service: job_related_service))
    job = nomad.set_deployed_info(job: job, user: ssh_user, branch: branch_name)
    result = nomad.deploy!(job: job, wait_status: wait_status, wait_task_group: wait_task_group)

    if result.error?
      puts "đ´ Error trying to execute '#{job_name}' job"
      show_result_error(result)
      exit(1)
    end

    puts "đ Completed '#{job_name}' job!"
  end

  private

  attr_accessor :static_config

  def show_result_error(result)
    if result.data.respond_to?(:keys)
      result.data.each do |task, output|
        puts "#{task} Output:"
        %i[stderr stdout].each do |stream|
          puts "#{stream.to_s.upcase} đ"
          puts "------------------------"
          puts output[stream]
        end
      end
    else
      puts result.data
    end
  end
end
