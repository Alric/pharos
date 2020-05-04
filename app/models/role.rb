# == Schema Information
#
# Table name: roles
#
#  id         :integer          not null, primary key
#  name       :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class Role < ApplicationRecord
  self.primary_key = 'id'
  validates :name, presence: true
end
