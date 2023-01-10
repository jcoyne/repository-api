# frozen_string_literal: true

# Moves files from the ActiveStorage to the staging mount
class StageGlobus
  def self.stage(signed_ids, druid)
    # Skip side effects if no signed IDs provided
    return yield if signed_ids.empty?

    dir = StagingDirectory.new(druid: druid, staging_location: Settings.staging_location)
    signed_ids.select { |_key, value| value&.match?(%r{^globus://}) }.each do |filename, globus_path|
      dir.copy_file(globus_path.gsub('globus://', Settings.globus_location), filename)
    end
    yield
  end
end
