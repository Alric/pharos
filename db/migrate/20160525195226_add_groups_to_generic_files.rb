class AddGroupsToGenericFiles < ActiveRecord::Migration[4.2]
  def change
    add_column :generic_files, :read_groups, :string
    add_column :generic_files, :edit_groups, :string
    add_column :generic_files, :discover_groups, :string
  end
end
