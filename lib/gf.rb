require "gf/version"

require 'net/http'
require 'uri'
require 'erb'

require 'thor'
require 'octokit'
require 'netrc'
require 'git_diff_parser'
require 'erb_with_hash'

module Gf
  class NetrcFile
    class FileNotFoundError < RuntimeError; end
    class MachineNotFoundError < RuntimeError; end

    def validate!
      raise_error_if_netrc_not_exist!
      raise_error_if_machine_not_found!
    end

    private

    def netrc_path
      @netrc_path ||= "#{ENV['HOME']}/.netrc"
    end

    def raise_error_if_netrc_not_exist!
      raise FileNotFoundError unless File.exist?(netrc_path)
    end

    def raise_error_if_machine_not_found!
      n = Netrc.read(netrc_path)
      raise MachineNotFoundError unless n['api.github.com']
    end
  end

  class DiffFile
    def initialize(path)
      @path  = path
      @pulls = []
    end

    def <<(pull)
      @pulls << pull
    end

    def report
      template.result_with_hash(path: @path, pulls: @pulls)
    end

    private

    def template
      ERB.new(<<-'EOS', nil, '-')
<%= path %> (<%= pulls.count %>)
<% pulls.each do |pull| -%>
    - <%= "#{pull.branch_name} : #{pull.html_url}" %>
<% end -%>
      EOS
    end
  end

  class DiffFetcher
    attr_reader :diff_body

    def initialize(diff_url)
      @diff_url = diff_url
    end

    def fetch!
      @diff_body = fetch_url(@diff_url)
    end

    private

    def fetch_url(url)
      response = Net::HTTP.get_response(URI.parse(url))

      case response
      when Net::HTTPSuccess
        response.body
      when Net::HTTPRedirection
        fetch_url(response['location'])
      else
        response.value
      end
    end
  end

  class PullRequest
    def initialize(pull_request_params)
      @pull_request_params = pull_request_params
    end

    def changed_files
      @changed_files ||= fetch_changed_files
    end

    def html_url
      @pull_request_params[:_links][:html][:href]
    end

    def branch_name
       @pull_request_params[:head][:label]
    end

    private
    def diff_url
      @pull_request_params['diff_url']
    end

    def fetch_changed_files
      fetcher = DiffFetcher.new(diff_url)
      fetcher.fetch!

      patches = GitDiffParser.parse(fetcher.diff_body)
      patches.map(&:file)
    end
  end

  class Repositry
    attr_reader :owner_slash_repo

    def initialize(owner_slash_repo)
      @client = nil
      @owner_slash_repo = owner_slash_repo
    end

    def collect_pull_requested_files
      pulls = client.pulls(owner_slash_repo, state: 'open').map { |pull| PullRequest.new(pull) }

      pulls.each_with_object(Hash.new {|h, path| h[path] = DiffFile.new(path) }) do |pull, files|
        pull.changed_files.each do |path|
          files[path] << pull
        end
      end
    end

    private

    def client
      @client ||= ::Octokit::Client.new(netrc: true).tap(&:login)
    end
  end

  class Command < Thor
    desc 'hi', 'hi'
    def show_files(owner_slash_repo, *files)
      NetrcFile.new.validate!

      repo = Repositry.new(owner_slash_repo)
      repo.collect_pull_requested_files.each do |_, pull|
        puts pull.report
      end
    end
    default_command :show_files
  end
end
