#!/usr/bin/env ruby

class Array; def sum; inject( nil ) { |sum,x| sum ? sum+x : x }; end; end
class Array; def mean; sum / size; end; end

class HAProxyStatsParser
  
  attr_accessor :data, :haproxy_socket, :data_dir
  
  def initialize(haproxy_socket, data_dir)
    @data = {}
    @haproxy_socket = haproxy_socket
    @data_dir = data_dir
    `mkdir -p #{data_dir}`
  end
  
  def run
    
    raw_data = `echo "show stat" | socat unix-connect:#{haproxy_socket} stdio`
    
    process(raw_data)
    
    report
    
    save_raw_data(raw_data)
  end
  
  def process(raw_data)
    return if raw_data.nil? || raw_data == ''

    raw_data = raw_data.split("\n")
    raw_data.shift # get rid of header
    
    raw_data.each do |line|
      process_line(line)
    end
    
    data
  end
  
  def save_raw_data(raw_data)
    File.open("#{data_dir}/previous", "w") do |f|
      f.print raw_data
    end
  end
  
  def load_previous_raw_data
    if File.exists?("#{data_dir}/previous")
      File.read("#{data_dir}/previous")
    else
      ""
    end
  end
  
  def process_line(line)
    server_info = line.split(",")
    backend = server_info[0]
    server = server_info[1]

    if server == 'BACKEND'
      add_totals(server_info)
    elsif server == 'FRONTEND'
      add_frontend_totals(server_info)
    else
      add_server(server_info)
    end
  end

  def add_frontend_totals(info)
    backend = 'total'
    data[backend] ||= {}
    data[backend][:request_rate_per_second] = (data[backend][:request_rate_per_second] || 0 ) + info[33].to_i
    data[backend][:current_sessions] = (data[backend][:current_sessions] || 0) + info[4].to_i
    data[backend][:max_sessions] = (data[backend][:max_sessions] || 0 ) + info[5].to_i
    data[backend][:bytes_in] = (data[backend][:bytes_in]  || 0 ) + info[8].to_i / 1024
    data[backend][:bytes_out] = (data[backend][:bytes_out]  || 0 ) + info[9].to_i / 1024
  end
  
  def add_totals(info)
    backend = info[0]
    data[backend] ||= {}
    data[backend][:request_rate_per_second] = info[33].to_i
    data[backend][:current_sessions] = info[4].to_i
    data[backend][:max_sessions] = info[5].to_i
    data[backend][:bytes_in] = info[8].to_i / 1024
    data[backend][:bytes_out] = info[9].to_i / 1024
  end
  
  def add_server(info)
    backend = info[0]
    data[backend] ||= {}
    data[backend][:sessions] ||= []
    data[backend][:sessions] << info[4].to_i 
    data[backend][:servers_up] = data[backend][:servers_up].to_i + (info[17].to_s == 'UP' ? 1 : 0)
    data[backend][:servers_down] = data[backend][:servers_down].to_i + (info[17].to_s == 'DOWN' ? 1 : 0)
  end
  
  def report
    previous_result = HAProxyStatsParser.new("/tmp/haproxy.sock", "/tmp/haproxy-stats").process(load_previous_raw_data)
    
    data.each do |backend, stats|
      bytes_in = stats[:bytes_in] - (previous_result[backend][:bytes_in].to_i rescue 0)
      bytes_out = stats[:bytes_out] - (previous_result[backend][:bytes_out].to_i rescue 0)
      
      puts "Backend #{backend}"
      puts "Bytes IN: #{bytes_in} KB"
      puts "Bytes OUT: #{bytes_out} KB"
      puts "Current sessions: #{stats[:current_sessions]}"
      puts "Current request rate per second: #{stats[:request_rate_per_second]}"
      puts "Max sessions total: #{stats[:max_sessions]}"
      puts "Max sessions per server: #{stats[:sessions].max}" unless backend == 'total'
      puts "Avg sessions per server: #{stats[:sessions].mean}" unless backend == 'total'
      puts "Servers UP: #{stats[:servers_up]}" unless backend == 'total'
      puts "Servers DOWN: #{stats[:servers_down]}" unless backend == 'total'
      puts ""
      
      `gmetric -tint32 -x60 -uKilobytes -n"#lb_{backend}_kbytes_in" -v#{bytes_in}`
      `gmetric -tint32 -x60 -uKilobytes -n"lb_#{backend}_kbytes_out" -v#{bytes_out}`
      `gmetric -tuint8 -x60 -n"lb_#{backend}_req_per_s" -v#{stats[:request_rate_per_second]}`
      `gmetric -tuint8 -x60 -n"lb_#{backend}_current_sess" -v#{stats[:current_sessions]}`
      `gmetric -tuint8 -x60 -n"lb_#{backend}_sess_max" -v#{stats[:max_sessions]}`
      `gmetric -tuint8 -x60 -n"lb_#{backend}_avg_sess_per_server" -v#{stats[:sessions].mean}` unless backend == 'total'
      `gmetric -tuint8 -x60 -n"lb_#{backend}_max_sess_per_server" -v#{stats[:sessions].max}` unless backend == 'total'
      `gmetric -tuint8 -x60 -n"lb_#{backend}_servers_up" -v#{stats[:servers_up]}` unless backend == 'total'
      `gmetric -tuint8 -x60 -n"lb_#{backend}_servers_down" -v#{stats[:servers_down]}` unless backend == 'total'
    end
  end
  
end

HAProxyStatsParser.new("/tmp/haproxy.sock", "/tmp/haproxy-stats").run
