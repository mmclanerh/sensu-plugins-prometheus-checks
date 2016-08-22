#!/usr/bin/env ruby
require 'socket'
require 'json'
require 'net/http'
require 'yaml'
require 'cgi'

def query stuff
  stuff = CGI.escape(stuff)
  host, port = 'localhost:9090'.split(':')
  http = Net::HTTP.new(host, port)
  http.read_timeout = 3
  http.open_timeout = 3
  request = Net::HTTP::Get.new("/api/v1/query?query=#{stuff}")
  JSON.load(http.request(request).body)
end

def safe_hostname(hostname)
  hostname.gsub(/-|:/,'_')
end

def send_event(event)
  s = TCPSocket.open('localhost', 3030)
  s.puts JSON.generate(event)
  s.close
end

def check result, warn, crit
  result = result.to_f
  warn = warn.to_f
  crit = crit.to_f
  status = 3
  if result < warn
    status = 0
  elsif result >= crit
    status = 2
  elsif result >= warn
    status = 1
  end
  status
end

def memory(cfg)
  results = []
  query('100-(node_memory_MemTotal/(node_memory_MemTotal+node_memory_MemAvailable)*100)')['data']['result'].each do |result|
    hostname = result['metric']['instance']
    memory = result['value'][1].to_i
    status = check(memory, cfg['warn'], cfg['crit'])
    results << {'status' => status, 'output' => "Memory #{memory}%|memory=#{memory}", 'name' => 'check_memory', 'source' => hostname}
  end
  results
end

def disk(cfg)
  results = []
  disk = "mountpoint=\"#{cfg['mount']}\""
  query("100-(node_filesystem_size{#{disk}}/(node_filesystem_size{#{disk}}+node_filesystem_avail{#{disk}})*100)")['data']['result'].each do |result|
    hostname = result['metric']['instance']
    disk = result['value'][1].to_i
    status = check(disk, cfg['warn'], cfg['crit'])
    results << {'status' => status, 'output' => "Disk: #{disk}%, Mountpoint: #{cfg['mount']} |disk=#{disk}", 'name' => "check_disk_#{cfg['name']}", 'source' => hostname}
  end
  results
end

def service(cfg)
  results = []
  name = cfg['name']
  query("node_systemd_unit_state{name='#{name}',state='active'}")['data']['result'].each do |result|
    hostname = result['metric']['instance']
    state = result['value'][1].to_i
    status = equals(state, 1)
    results << {'status' => status, 'output' => "Service: #{name}", 'name' => "check_service_#{name}", 'source' => hostname}
  end
  results
end

def load_per_cluster_minus_n(cfg)
  cluster = cfg['cluster']
  minus_n = cfg['minus_n']
  sum_load = "sum(node_load5{job=\"#{cluster}\"})"
  total_cpus = "count(node_cpu{mode=\"system\",job=\"#{cluster}\"})"
  total_nodes = "count(node_load5{job=\"#{cluster}\"})"

  cpu = query("#{sum_load}/(#{total_cpus}-(#{total_cpus}/#{total_nodes})*#{minus_n})")['data']['result'][0]['value'][1].to_f.round(2)
  status = check(cpu, cfg['warn'], cfg['crit'])
  [{'status' => status, 'output' => "Cluster Load: #{cpu}|load=#{cpu}", 'name' => 'cluster_load_minus_n', 'source' => cfg['source']}]
end


def load_per_cluster(cfg)
  cluster = cfg['cluster']
  cpu = query("sum(node_load5{job=\"#{cluster}\"})/count(node_cpu{mode=\"system\",job=\"#{cluster}\"})")['data']['result'][0]['value'][1].to_f.round(2)
  status = check(cpu, cfg['warn'], cfg['crit'])
  [{'status' => status, 'output' => "Cluster Load: #{cpu}|load=#{cpu}", 'name' => 'cluster_load', 'source' => cfg['source']}]
end


def equals result, value
  if result.to_f == value.to_f
    0
  else
    2
  end
end

if __FILE__ == $0
  results = []
  checks = YAML.load_file(ARGV[0]||'config.yml')
  checks['checks'].each do |check|
    results << send(check['check'], check['cfg'])
  end
  results.flatten(1).each do |result|
    event = {
      'reported_by' => 'sbppapik8s'
    }.merge(result)
    if event['source'] =~ /sbppapi/
      event['source'] = safe_hostname(event['source'])
      puts event
      #send_event(event)
    end
  end
  #checks['custom'].each do |check|
  #  query(check['query'])['data']['result'].each do |result|
  #    puts result
  #    status = send(check['check']['type'], result['value'][1], check['check']['value'])
  #    puts result['metric']['instance']
  #    puts check['msg'][status['status']]
  #  end
  #end
  exit 0
end
