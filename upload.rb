#!/usr/bin/env ruby

require "net/http"
require 'net/https'
require "rubygems"
require 'json'
require "time"
require 'mime/types'


module Net
  class HTTP
    def urlencode(str)
      str.gsub(/[^a-zA-Z0-9_\.\-]/n) {|s| sprintf('%%%02x', s[0].ord) }
    end

    def post_form(path, params)
      req = Net::HTTP::Post.new(path)
      req.body = params.map {|k,v| "#{urlencode(k.to_s)}=#{urlencode(v.to_s)}" }.join('&')
      req.content_type = 'application/x-www-form-urlencoded'
      self.request req
    end

    def post_multipart(path, params)
      boundary = "#{rand(1000000)}boundryofdoomydoom#{rand(1000000)}"

      fp = []
      files = []

      params.each do |k,v|
        if v.respond_to?(:path) and v.respond_to?(:read) then
          filename = v.path
          content = v.read
          mime_type = MIME::Types.type_for(filename)[0] || MIME::Types["application/octet-stream"][0]
          fp.push(prepare_param("Content-Type", mime_type.simplified))
          files.push("Content-Disposition: form-data; name=\"#{urlencode(k.to_s)}\"; filename=\"#{ filename }\"\r\nContent-Type: #{ mime_type.simplified }\r\n\r\n#{ content }\r\n")
        else
          fp.push(prepare_param(k,v))
        end
      end

      self.post(path, "--#{boundary}\r\n" + (fp + files).join("--#{boundary}\r\n") + "--#{boundary}--", {
        "Content-Type" => "multipart/form-data; boundary=#{boundary}",
        "User-Agent" => "Mozilla/5.0 (Macintosh; U; PPC Mac OS X; en-us) AppleWebKit/523.10.6 (KHTML, like Gecko) Version/3.0.4 Safari/523.10.6"
      })
    end

    def prepare_param(name, value)
      "Content-Disposition: form-data; name=\"#{urlencode(name.to_s)}\"\r\n\r\n#{value}\r\n"
    end
  end
end


def die(message, with_usage = false)
  puts "ERROR: #{message}"
  puts %Q|Usage: #{__FILE__} file_to_upload [repo]
  file_to_upload: File to be uploaded.
  repo: GitHub repo to upload to.  Ex: "tekkub/sandbox".  If omitted, the repo from `git remote show origin` will be used.| if with_usage
  exit 1
end


user  = `git config --global github.user`.strip
token = `git config --global github.token`.strip
die "Cannot find login credentials" if user.empty? || token.empty?


die "No file specified", true unless filename = ARGV[0]
die "Target file does not exist" unless File.size?(filename)


repo = ARGV[1]
repo = $1 if repo.nil? && `git remote show origin` =~ /git@github.com:(.+?)\.git/
die("Unable to find GitHub repo", true) if repo.nil?


file = File.new(filename)
mime_type = MIME::Types.type_for(filename)[0] || MIME::Types["application/octet-stream"][0]


# Check for conflict
url = URI.parse "https://github.com/"
http = Net::HTTP.new url.host, url.port
http.use_ssl = url.scheme == 'https'
http.verify_mode = OpenSSL::SSL::VERIFY_NONE
res = http.get("/#{repo}/downloads?login=#{user}&token=#{token}")
die "File has already been uploaded" if res.body =~ /<td><a href="https?:\/\/s3.amazonaws.com\/github\/downloads\/#{repo.gsub(/\//, "\/")}\/#{filename}.+">#{filename}<\/a><\/td>/


# Get the info we need from GitHub to post to S3
res = http.post_form("/#{repo}/downloads", {
  :file_size => File.size(filename),
  :content_type => mime_type.simplified,
  :file_name => filename,
  :description => '',
  :login => user,
  :token => token,
})
die "Repo not found" if res.class == Net::HTTPNotFound
date = res["Date"]
data = JSON.parse(res.body)
die "Unable to authorize upload" if data["signature"].nil?


# Post to S3
url = URI.parse "http://github.s3.amazonaws.com/"
http = Net::HTTP.new url.host, url.port
res = http.post_multipart("/", {
  :key => "#{data["prefix"]}#{filename}",
  :Filename => filename,
  :policy => data["policy"],
  :AWSAccessKeyId => data["accesskeyid"],
  :signature => data["signature"],
  :acl => data["acl"],
  :file => file,
  :success_action_status => 201
})
die "File upload failed" unless res.class == Net::HTTPCreated
puts "File uploaded successfully"
