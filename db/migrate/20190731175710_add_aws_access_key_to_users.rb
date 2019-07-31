class AddAwsAccessKeyToUsers < ActiveRecord::Migration[5.2]
  def up
    add_column :users, :aws_access_key, :string, default: ""
  end

  def down
    remove_column :users, :aws_access_key
  end
end
