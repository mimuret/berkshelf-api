require 'gitlab'
require 'semverse'
require 'pp'

module Berkshelf::API
  class CacheBuilder
    module Worker
      class Gitlab < Worker::Base
        worker_type "gitlab"

        include Logging

        # @return [String]
        attr_reader :group

        # @option options [String] :organization
        #   the organization to crawl for cookbooks
        # @option options [String] :access_token
        #   authentication token for accessing the Github organization. This is necessary
        #   since Github throttles unauthenticated API requests
        def initialize(options = {})
          ::Gitlab.endpoint = options[:web_endpoint]
          ::Gitlab.private_token = options[:private_token]
          ::Gitlab.http_proxy(options[:proxy],options[:proxy_port])
          @group = ::Gitlab.group_search(options[:group])[0]
          @private_token = options[:private_token]
          super(options)
        end

        # @return [String]
        def to_s
          friendly_name(@group)
        end

        # @return [Array<RemoteCookbook>]
        #  The list of cookbooks this builder can find
        def cookbooks
          [].tap do |cookbook_versions|
            ::Gitlab.project_search("cookbook",{:per_page=>100}).each do |project|
              ::Gitlab.tags(project.id).each do |tag|
                if match = /^v(?<version>.*)$/.match(tag.name)
                  begin
                    next unless cookbook_metadata = load_metadata(project.id, tag.name)
                    uri = project.web_url + "/repository/archive.tar.gz?ref=#{tag.name}&private_token=#{@private_token}"
                    if cookbook_metadata.version.to_s == match[:version].to_s
                      cookbook_versions << RemoteCookbook.new(cookbook_metadata.name, cookbook_metadata.version,
                        "uri", uri, priority, {:project_id => project.id} )
                    else
                      log.warn "Version found in metadata for #{repo.name} (#{tag.name}) does not " +
                        "match the tag. Got #{cookbook_metadata.version}."
                    end
                  rescue Semverse::InvalidVersionFormat
                    log.debug "Ignoring tag #{tag.name} for: #{repo.name}. Does not conform to semver."
                  rescue Octokit::NotFound
                    log.debug "Ignoring tag #{tag.name} for: #{repo.name}. No raw metadata found."
                  end
                else
                  log.debug "Version number cannot be parsed"
                end
              end
            end
          end
        end

        # Return the metadata of the given RemoteCookbook. If the metadata could not be found or parsed
        # nil is returned.
        #
        # @param [RemoteCookbook] remote
        #
        # @return [Ridley::Chef::Cookbook::Metadata, nil]
        def metadata(remote)
          load_metadata(remote.info[:project_id], "v#{remote.version}")
        end

        private
          # Helper function for loading metadata from a particular ref in a Github repository
          #
          # @param [String] repo
          #   name of repository to load from
          # @param [String] ref
          #   reference, tag, or branch to load from
          #
          # @return [Ridley::Chef::Cookbook::Metadata, nil]
          def load_metadata(project_id, ref)
            metadata_content  = ::Gitlab.file_contents(project_id, Ridley::Chef::Cookbook::Metadata::RAW_FILE_NAME, ref)
            cookbook_metadata = Ridley::Chef::Cookbook::Metadata.new
            cookbook_metadata.instance_eval(metadata_content)
            cookbook_metadata
          rescue => ex
            nil
          end
      end
    end
  end
end
