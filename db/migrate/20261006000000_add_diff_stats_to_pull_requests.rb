class AddDiffStatsToPullRequests < ActiveRecord::Migration[8.0]
  def change
    add_column :pull_requests, :additions, :integer
    add_column :pull_requests, :deletions, :integer
    add_column :pull_requests, :changed_files, :integer
  end
end
