require 'excon'

module FlynnClient
  class Client
    REQUEST_TIMEOUT = 180 #seconds
    VERIFY_SSL = false
    MAX_RETRIES = 100
    JOB_POLL_INTERVAL = 10

    def initialize(host, admin_username, admin_password, mock=false)
      raise "Missing host!" if host.nil?
      raise "Missing admin password!" if admin_password.nil? && ! mock
      controller_url = "https://controller.#{host}"
      router_url = "https://router.#{host}"
      @mock = mock
      Excon.defaults[:ssl_verify_peer] = VERIFY_SSL
      @controller = Excon.new(controller_url, user: admin_username, password: admin_password, mock: mock)
      @router = Excon.new(router_url, user: admin_username, password: admin_password, mock: mock)
    end

    def create_app(app_name)
      raise "Missing app_name!" if app_name.nil?
      response = @controller.post(path: apps_path, headers: headers, body: { name: app_name }.to_json)
      result = JSON.parse response.body
      return response.status == 200, result.fetch('id'), result.fetch('name')
    end

    def destroy_app(app_id)
      raise "Missing app_id!" if app_id.nil?
      response = @controller.delete(path: app_path(app_id), headers: headers)
      return response.status == 200
    end

    def restart_app(app_id, app_name)
      raise "Missing app_id!" if app_id.nil?
      raise "Missing app_name!" if app_name.nil?
      formation = get_current_formation(app_id)
      processes = formation.fetch("processes")
      results = []
      processes.each_pair do |process_type, process_count|
        results << scale_process(app_name, process_type, 0)
        results << scale_process(app_name, process_type, process_count)
      end
      results.all?
    end

    def get_logs(app_id)
      raise "Missing app_id!" if app_id.nil?
      response = @controller.get(path: app_log_path(app_id), headers: headers)
      #TODO filter garbage
      response.body
    end

    def run_command(app_id, command)
      raise "Missing app_id!" if app_id.nil?
      raise "Missing command!" if command.nil?
      release = get_release(app_id)
      payload = {"release": release.fetch("id"), "cmd": [command], "release_env": true, "disable_log": false}
      job_response = @controller.post(path: app_jobs_path(app_id), headers: headers, body: payload.to_json)
      job_result = JSON.parse job_response.body
      if job_response.status == 200
        job_id = job_result.fetch("id")
        wait_for_job(app_id, job_id)
      else
        raise "Failed to submit job to run command\n#{job_response}"
      end
    end

    def get_config(app_id)
      raise "Missing app_id!" if app_id.nil?
      release = get_release(app_id)
      release.fetch('env')
    end

    def set_config(app_id, hash)
      raise "Missing app_id!" if app_id.nil?
      release = get_release(app_id)
      release.delete("id")
      if release.has_key?("env")
        release["env"].merge!(hash)
      else
        release["env"] = hash
      end
      # First, create a new release of the app using the new environment variables
      release_response = @controller.post(path: releases_path, headers: headers, body: release.to_json)
      release_result = JSON.parse release_response.body
      if release_response.status == 200
        payload = {"id": release_result.fetch("id")}
        # Then, set app release to it
        response = @controller.put(path: app_release_path(app_id), headers: headers, body: payload.to_json)
        response.status == 200
      else
        false
      end
    end

    def scale_web(app_id, count)
      raise "Missing app_id!" if app_id.nil?
      raise "Missing count!" unless count.is_a? Integer
      scale_process(app_id, "web", count)
    end

    def scale_worker(app_id, count)
      raise "Missing app_id!" if app_id.nil?
      raise "Missing count!" unless count.is_a? Integer
      scale_process(app_id, "worker", count)
    end

    def ssl_domain_create(app_name, domain, certificate, private_key, sticky)
      raise "Missing app_name!" if app_name.nil?
      raise "Missing domain!" if domain.nil?
      raise "Missing certificate!" if certificate.nil?
      raise "Missing private_key!" if private_key.nil?
      raise "Wrong sticky (true or false only)" unless [true, false].include?(sticky)
      payload = {
        type: "http",
        service: "#{app_name}-web",
        tls_cert: certificate,
        tls_key: private_key,
        sticky: sticky,
        domain: domain
      }
      response = @router.post(path: routes_path, headers: headers, body: payload.to_json)
      response.status == 200
    end

    def ssl_domain_update(app_name, old_domain, new_domain, certificate, private_key, sticky)
      raise "Missing app_name!" if app_name.nil?
      raise "Missing old_domain!" if old_domain.nil?
      raise "Missing new_domain!" if new_domain.nil?
      raise "Missing certificate!" if certificate.nil?
      raise "Missing private_key!" if private_key.nil?
      raise "Wrong sticky (true or false only)" unless [true, false].include?(sticky)
      route = get_route(app_name, old_domain)
      route["domain"] = new_domain
      route["tls_cert"] = certificate
      route["tls_key"] = private_key
      route["sticky"] = sticky
      response = @router.put(path: route_path(route.fetch('id')), headers: headers, body: payload.to_json)
      response.status == 200
    end

    def domain_remove(app_name, domain)
      raise "Missing app_name!" if app_name.nil?
      raise "Missing domain!" if domain.nil?
      route = get_route(app_name, domain)
      response = @router.delete(path: route_path(route.fetch('id')), headers: headers)
      response.status == 200
    end

    private

    def wait_for_job(app_id, job_id)
      job = get_job(app_id, job_id)
      counter = 0
      until job.has_key?("exit_status")
        counter = counter + 1
        raise "Wait counter exhausted" if counter >= MAX_RETRIES
        sleep JOB_POLL_INTERVAL
        job = get_job(app_id, job_id)
      end

      if job.fetch("exit_status") == 0
        return "Success!"
      else
        response = @controller.get(path: app_log_path(app_id), headers: headers, body: {"job_id": job.fetch("uuid")}.to_json)
        raise "Status code: #{job.fetch('exit_status')} #{job.fetch('state')}\n#{response.body}"
      end
    end

    def get_job(app_id, job_id)
      result = @controller.get(path: "#{app_jobs_path(app_id)}/#{job_id}", headers: headers)
      JSON.parse result.body
    end

    def get_release(app_id)
      response = @controller.get(path: app_release_path(app_id), headers: headers)
      if response.body.nil? || response.body.to_s.strip.length == 0
        return Hash.new
      else
        JSON.parse response.body
      end
    end

    def get_formations(app_id)
      response = @controller.get(path: app_formations_path(app_id), headers: headers)
      JSON.parse response.body
    end

    def get_current_formation(app_id)
      formation_id = get_formations(app_id).first.fetch('release') # This is actually the formation ID and NOT the release ID
      get_formation(app_id, formation_id)
    end

    def get_formation(app_id, formation_id, expanded=false)
      response = @controller.get(path: app_formation_path(app_id, formation_id), headers: headers, query: { expanded: expanded})
      JSON.parse response.body
    end

    def get_route(app_name, domain)
      get_routes.detect{|route| route["service"] == "#{app_name}-web" && route["domain"] == domain}
    end

    def get_routes
      response = @router.get(path: routes_path, headers: headers)
      JSON.parse response.body
    end

    def get_apps
      response = @controller.get(path: apps_path, headers: headers)
      JSON.parse response.body
    end

    def scale_process(app_id, process_type, count)
      raise "I don't know what to do with #{process_type}" unless ["web", "worker"].include?(process_type)
      formation = get_current_formation(app_id)
      formation_id = formation.fetch('release') # This is actually the formation ID and NOT the release ID
      if formation["processes"].has_key?(process_type) && formation["processes"].fetch(process_type) != count
        formation["processes"][process_type] = count
        begin
          response = @controller.put(path: app_formation_path(app_id, formation_id), headers: headers, body: formation.to_json)
          response.status == 200
        rescue => e
          puts "\nERROR #{e.message}\n#{e.response.inspect}"
        end
      end
    end

    def app_jobs_path(app_id)
      "#{app_path(app_id)}/jobs"
    end

    def app_formation_path(app_id, formation_id)
      "#{app_formations_path(app_id)}/#{formation_id}"
    end

    def app_formations_path(app_id)
      "#{app_path(app_id)}/formations"
    end

    def app_release_path(app_id)
      "#{app_path(app_id)}/release"
    end

    def app_log_path(app_id)
      "#{app_path(app_id)}/log"
    end

    def app_path(app_id)
      "#{apps_path}/#{app_id}"
    end

    def route_path(route_id)
      "#{routes_path}/#{route_id}"
    end

    def releases_path
      "/releases"
    end

    def apps_path
      '/apps'
    end

    def routes_path
      '/routes'
    end

    def headers
      {:content_type => :json, :accept => :json}
    end

  end
end
