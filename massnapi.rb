#!/usr/bin/env ruby

require 'digest/md5'
require 'tempfile'
require 'net/http'
require 'rexml/document'
require 'time'
require 'base64'
require 'yaml'

def findSourceEncoding(source, infos)
	pl = 'ąćęłńóśżź'
	utf8 = pl.encode('UTF-8')
	cp = pl.encode('CP1250')
	iso = pl.encode('ISO-8859-2')
	encodings = { 'UTF-8' => utf8, 'CP1250' => cp, 'ISO-8859-2' => iso }.map { |name, charstr|
		chars = charstr.split(//)
		[ name, source.force_encoding(name).each_char.map { |c|
			chars.index(c) ? 1 : 0
		}.reduce(:+) ]
	}.sort_by { |name, count| [ count, name ] }
	encodings.each { |name, count|
		if count > 0
			infos << "#{count} PL chars from #{name}"
		end
	}
	encodings.last[0]
end

def napiUnpack(source, dstfilename, infos)
	temp = Dir::Tmpname.make_tmpname(['/tmp/massnapi', '.7z'], nil)
	File.write(temp, source)
	io = IO.popen("7za x -y -so -bd -piBlm8NTigvru0Jr0 '#{temp}'", 'r')	
	body = io.read
	encoding = findSourceEncoding(body, infos)
	infos << 'source encoding ' + encoding
	File.write(dstfilename, body.force_encoding(encoding).encode($config[:local_encoding]))
end

def cacheFilename(filename)
	cachefn = filename.gsub(/\/([^\/]+)\.([^.]+)$/, '/.\1.massnapicache')
	raise "Invalid movie filename: #{filename}" if cachefn == filename
	cachefn
end

def readCache(filename)
	cfn = cacheFilename(filename)
	if File.exists?(cfn)
		cache = YAML::load(File.read(cfn))
		stat = File.stat(filename)
		if cache[:mtime] != stat.mtime or File.size(filename) != cache[:size]
			cache = {}
		end
		cache
	else
		{}
	end
end

def saveCache(filename, cache)
	cfn = cacheFilename(filename)
	stat = File.stat(filename)
	cache[:mtime] = stat.mtime
	cache[:size] = File.size(filename)
	File.write(cfn, cache.to_yaml)
end

def startApiV1(queue, filename, language = 'PL')
	hash = Digest::MD5.hexdigest(File.read(filename, 10485760))
	add = [0, 13, 16, 11, 5]
	idx = [14, 3, 6, 8, 2]
	mul = [2, 2, 5, 4, 3]
	f = add.zip(mul, idx).map { |a, m, i| 
		t = a + hash[i].to_i(16) 
		v = hash[t..t+1].to_i(16) 
		(v*m).to_s(16)[-1] 
	}.join
	url = sprintf('/unit_napisy/dl.php?l=%s&f=%s&t=%s&v=other&kolejka=false&nick=&pass=&napios=posix', language, hash, f)
	queue << [ filename, [], :get, [ url ], lambda do |filename, body, dst, infos|
		napiUnpack(body, dst, infos)
	end ]	
end

def startApiV3(queue, filename, language = 'PL')
	baseurl = URI('http://napiprojekt.pl/api/api-napiprojekt3.php')
	cache = readCache(filename)
	infos = []
	if cache[:md5]
		hash = cache[:md5]
		infos << 'cached hash'
	else
		hash = Digest::MD5.hexdigest(File.read(filename, 10485760))
		cache[:md5] = hash
		saveCache(filename, cache)		
		infos << 'calculated hash'
	end

	options = {
		'mode' => '31',
		'client' => 'NapiProjekt',
		'client_ver' => '2.2.0.2399',
		'user_nick' => '',
		'user_password' => '',
		'downloaded_subtitles_id' => hash,
		'downloaded_subtitles_lang' => language,
		'downloaded_cover_id' => hash,
		'advert_type' => 'flashAllowed',
		'video_info_hash' => hash,
		'nazwa_pliku' => filename.split('/').last,
		'rozmiar_pliku_bajty' => File.size(filename),
		'the' => 'end'
	}
	queue << [ filename, infos, :post, [ baseurl, URI.encode_www_form(options) ], lambda do |filename, body, dst, infos|
		raise "Empty response" if body.empty?
		doc = REXML::Document.new(body)
#		raise "Empty response (no XML subtitles)" unless doc.elements['result/status']
		raise "No subtitles found" unless doc.elements['result/status']
		raise "Invalid response status: #{doc.elements['result/status'].text}" unless doc.elements['result/status'].text == 'success'
		raise "Invalid response hash: our #{hash} vs response #{doc.elements['result/subtitles/id'].text}" unless doc.elements['result/subtitles/id'].text == hash
#		subs_hash = doc.elements['result/subtitles/subs_hash'].text # md5 of decompressed subtitle text?
#		subs_size = doc.elements['result/subtitles/filesize'].text # size in bytes of decompressed subtitle text?
#		author = doc.elements['result/subtitles/author'].text 
#		uploader = doc.elements['result/subtitles/uploader'].text 
#		upload_date = Time.parse(doc.elements['result/subtitles/upload_date'].text)
#		movie = Hash[*[ 
#			'id', 'title', 'year', 'country/en', 'genre/en', 'direction', 
#			'screenplay', 'cinematography', 'music', 'tv_series', 'episode', 'season',
#			'direct_links/imdb_com', 'rating', 'votes' ].map { |i| [ i, doc.elements['result/movie/' + i].text ] }.flatten]
		contents = Base64.decode64(doc.elements['result/subtitles/content'].text)
		napiUnpack(contents, dst, infos)
	end ]
end

def makeMicroDvdPath(filename)
	result = filename.gsub(/\.([^.]+)$/, '.txt')
	raise "Invalid movie filename: #{filename}" if result == filename
	result
end

configfn = File.join(ENV['HOME'], '.massnapi.conf')
$config = YAML::load(File.read(configfn)) if File.exists?(configfn)
if $config == nil
	puts "ERROR: no configuration file found"
	File.write(configfn, { :local_encoding => 'UTF-8', :movies => '\.(mkv|mp4|avi)', :roots => [], :show_skips => false }.to_yaml )
	puts "Config file created at #{configfn}, please add roots (directories with movie files inside)"
	exit
end

unless $config and $config[:roots] and $config[:roots].count > 1 
	puts "Config file incomplete, please add :roots (directories with movie files inside)"
	exit
end
unless $config[:movies]
	puts "Config file incomplete, please add :movies (regex for movie file)"
	exit
end
unless $config[:local_encoding]
	puts "Config file incomplete, please add :local_encoding (encoding for local subtitle files)"
	exit
end

	
roots = $config[:roots]
queue = []
$debug = false
if ARGV[0] == '--debug'
	$debug = true
	startApiV3(queue, ARGV[1])
else
	puts "Scan starting"
	movieregexp = Regexp.new($config[:movies], Regexp::IGNORECASE)
	roots.each do |root|
		puts "Scanning root #{root}"
		last = nil
		prefix = root.split('/').count
		Dir.glob(root + '/**/*') do |filepath|
			if filepath.match(movieregexp)
				cur = filepath.split('/')[prefix..prefix+1]
				if cur != last
					last = cur
					puts "Entering #{cur.join('/')}"
				end
				startApiV3(queue, filepath)
			end
		end
	end
end
Net::HTTP.start('napiprojekt.pl', 80) do |http|
	queue.each { |filename, infos, method, url, action|
		infostr = "\e[1;34m(#{infos.join(', ')})\e[0m"
		subpath = makeMicroDvdPath(filename)
		if File.exists?(subpath) and File.size(subpath) > 1024 and File.mtime(subpath) >= File.mtime(filename)
			puts "#{filename}: \e[1;33mSKIP\e[0m #{infostr}" if $config[:show_skips]
		else
			begin
				p url if $debug
				body = http.send(method, *url).body	
				action.call(filename, body, subpath, infos)
			infostr = "\e[1;34m(#{infos.join(', ')})\e[0m"
				puts "#{filename}: \e[1;32mOK\e[0m #{infostr}"
			rescue StandardError => e
				puts "#{filename}: \e[1;31m#{e}\e[0m #{infostr}"
			end
		end
	}
end

