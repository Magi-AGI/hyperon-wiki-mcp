# frozen_string_literal: true

require "mcp"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for admin database backup operations
          class AdminBackup < ::MCP::Tool
            description "Manage database backups (admin only): download, list, or delete backups"

            annotations(
              read_only_hint: true,
              destructive_hint: true
            )

            input_schema(
              properties: {
                operation: {
                  type: "string",
                  enum: ["download", "list", "delete"],
                  description: "Operation: 'download' creates and downloads a new backup, 'list' shows available backups, 'delete' removes a backup file"
                },
                filename: {
                  type: "string",
                  description: "Backup filename (required for 'delete' operation)"
                },
                save_path: {
                  type: "string",
                  description: "Local path to save backup (for 'download' operation)"
                }
              },
              required: ["operation"]
            )

            class << self
              def call(operation:, filename: nil, save_path: nil, server_context:)
                tools = server_context[:magi_tools]

                result = case operation
                        when "download"
                          if save_path
                            tools.download_database_backup(save_path: save_path)
                            { "status" => "success", "path" => save_path }
                          else
                            data = tools.download_database_backup
                            { "status" => "success", "size" => data.bytesize }
                          end
                        when "list"
                          tools.list_database_backups
                        when "delete"
                          return error_response("Filename is required for delete") unless filename
                          tools.delete_database_backup(filename)
                        end

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: format_backup_result(operation, result)
                }])
              rescue Client::AuthorizationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error: Admin role required for backup operations"
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error with backup operation: #{e.message}"
                }], error: true)
              end

              private

              def error_response(message)
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error: #{message}"
                }], error: true)
              end

              def format_backup_result(operation, result)
                case operation
                when "download"
                  format_download(result)
                when "list"
                  format_list(result)
                when "delete"
                  format_delete(result)
                end
              end

              def format_download(result)
                parts = []
                parts << "# Database Backup Created"
                parts << ""

                if result["path"]
                  parts << "**Status:** ✅ Success"
                  parts << "**Saved to:** #{result['path']}"
                else
                  parts << "**Status:** ✅ Success"
                  parts << "**Size:** #{format_bytes(result['size'])}"
                  parts << ""
                  parts << "Backup downloaded to memory. Specify 'save_path' to save to file."
                end

                parts.join("\n")
              end

              def format_list(result)
                backups = result["backups"] || []
                total = result["total"] || 0

                parts = []
                parts << "# Available Backups"
                parts << ""
                parts << "**Total:** #{total} backups"
                parts << "**Directory:** #{result['backup_dir']}" if result["backup_dir"]
                parts << ""

                if backups.any?
                  backups.each_with_index do |backup, idx|
                    parts << "#{idx + 1}. **#{backup['filename']}**"
                    parts << "   Size: #{backup['size_human']}, Age: #{backup['age']}"
                    parts << "   Created: #{backup['created_at']}, Modified: #{backup['modified_at']}"
                    parts << ""
                  end
                else
                  parts << "No backups found."
                end

                parts.join("\n")
              end

              def format_delete(result)
                parts = []
                parts << "# Backup Deleted"
                parts << ""
                parts << "**Status:** ✅ Success"
                parts << "**Filename:** #{result['filename']}"
                parts << ""
                parts << result["message"] if result["message"]

                parts.join("\n")
              end

              def format_bytes(bytes)
                return "0 B" if bytes.zero?

                units = ['B', 'KB', 'MB', 'GB']
                exp = (Math.log(bytes) / Math.log(1024)).to_i
                exp = [exp, units.size - 1].min

                "%.2f %s" % [bytes.to_f / (1024 ** exp), units[exp]]
              end
            end
          end
        end
      end
    end
  end
end
