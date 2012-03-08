require 'rubygems'
require 'AWS'
require "socket"
require 'optparse'

$options = {}

optparse = OptionParser.new do|opts|
	# Set a banner, displayed at the top
	# # of the help screen.
	opts.banner = "gaitling_gun.rb [$options]"

	# This displays the help screen, all programs are
	# assumed to have this option.
	opts.on( '-h', '--help', "This script opens up a listening port and randomly forwards traffic to multiple SOCKS proxies (similar to privoxy)
				It is meant to be used with EC2 but doesn't require it." ) do
		puts opts
		exit
	end

	$options[:lport] = 60000
	opts.on( '-l', '--lport n', 'The local port to listen on. Defaults to 60000.' ) do|t|
		$options[:lport] = t
	end

	$options[:rport] = 60001
	opts.on( '-r', '--rport n', 'The proxies port range to start on. Defaults to 60001.' ) do|t|
		$options[:rport] = t
	end

	$options[:blacklist] = nil
		opts.on( '-b', '--blacklist FILE', 'A file containing the list of IPs not to connect to in your ec2 cloud.' ) do|t|
			$options[:blacklist] = t
	end

	$options[:noec2] = nil
	opts.on( '-f', '--noec2 n', 'To not utilize ec2 or create the SSH connections for the user. The script still expects the you to enter the number
				of SOCKS proxies listening. It will then go from proxies starting port range. For example,
				# gaitling_gun.rb --noec2 5
				Will expect there are SOCKS proxies listening on 60001,60002,60003,60004,and 60005 ' ) do|t|
		$options[:noec2] = t
	end

	$options[:user] = "ubuntu"
	opts.on( '-u', '--user USER', 'SSH username to connect as.' ) do|t|
		$options[:user] = t
	end

end

optparse.parse!
ACCESS_KEY_ID = '<<ACCESS_KEY_ID>>'
SECRET_ACCESS_KEY = '<<SECRET_ACCESS_KEY>>'
TOTAL_PROXIES = 0 unless $options[:noec2]
$proxies = []

if ACCESS_KEY_ID == '<<ACCESS_KEY_ID>>' and ($options[:noec2] == nil)
	puts "\n PLEASE ADD YOUR ACCESS KEY ID AND SECRET ACCESS KEY TO THE SCRIPT OR NO MAS EC2!!"
	exit 1
end


def list_ips
	ec2 = AWS::EC2::Base.new(:access_key_id => ACCESS_KEY_ID, :secret_access_key => SECRET_ACCESS_KEY)

	running_ips = []

	regions = ["us-east-1","us-west-1","us-west-2","ap-southeast-1","eu-southwest-1"]

	regions.each{ |region|
		`ec2-describe-instances --region #{region}`.each_line { |line|
			if line =~ /\bec2-([0-9-]+)/
				ip = $1.gsub('-','.')
				puts "#{region}: #{ip}"
				#create ssh proxy
				create_proxy(ip) unless $options[:noec2] 
			end
		}
	}
end

def build_remote_proxies(ip)
	if $options[:noec2]
		for pport in (1..$options[:noec2].to_i) 
			$proxies.push(pport+$options[:rport]-1)
		end
	else
		proxy_port = $options[:rport].to_i + TOTAL_PROXIES.to_i	
		#DANGER: this is a real hack but net::ssh doesn't seem to support creating local socks proxies
		# Also avoids the hassle of gathering all fingerprints from remote ssh servers if you've never
		# logged into them before (although it is much less secure)

		`ssh -D #{proxy_port}-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no #{$options[:user]}@#{ip} &`

		# this is also annoying as the proxy won't be destroyed when the script exits

		$proxies.push(proxy_port)
	end
end

def build_local_proxy
	# I can no longer find the orginal for some of the proxy code, needs a rewrite anyways
	remote_host = "127.0.0.1"
	listen_port = $options[:lport]
	max_threads = $proxies.length*10
	threads = []

	puts "Starting listening port on 127.0.0.1:#{listen_port}"
	server = TCPServer.new(nil, listen_port)
	while true
	# Start a new thread for every client connection.
	threads << Thread.new(server.accept) do |client_socket|
		begin
			begin
				rport = $proxies[rand($proxies.size)]
				server_socket = TCPSocket.new(remote_host, rport)
				rescue Errno::ECONNREFUSED
				client_socket.close
				raise
			end

		while true
		# Wait for data to be available on either socket.
			(ready_sockets, dummy, dummy) = IO.select([client_socket, server_socket])
				begin
					ready_sockets.each do |socket|
						data = socket.readpartial(10000)
						if socket == client_socket
							server_socket.write data
							server_socket.flush
						else
							client_socket.write data
							client_socket.flush
						end
					end
					rescue EOFError
					break
				end
			end
			rescue StandardError => e
			puts "Thread #{Thread.current} got exception #{e.inspect}"
			end
		client_socket.close rescue StandardError
		server_socket.close rescue StandardError
		end

		# Clean up the dead threads, and wait until we have available threads.
		threads = threads.select { |t| t.alive? ? true : (t.join; false) }
		while threads.size >= max_threads
			sleep 1.5
			threads = threads.select { |t| t.alive? ? true : (t.join; false) }
		end
	end
end

if $options[:noec2]
	build_remote_proxies(nil)
else
	list_ips
end
build_local_proxy
