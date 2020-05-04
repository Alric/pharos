# == Schema Information
#
# Table name: checksums
#
#  id              :integer          not null, primary key
#  algorithm       :string
#  datetime        :datetime
#  digest          :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  generic_file_id :integer
#
# Indexes
#
#  index_checksums_on_generic_file_id  (generic_file_id)
#
# Foreign Keys
#
#  fk_rails_...  (generic_file_id => generic_files.id)
#
class Checksum < ApplicationRecord
  self.primary_key = 'id'
  belongs_to :generic_file

  validates :digest, presence: true
  validates :algorithm, presence: true
  validates :datetime, presence: true

  ### Scopes
  scope :with_digest, ->(param) { where(digest: param) if param.present? }
  scope :with_algorithm, ->(param) { where(algorithm: param) if param.present? }
  scope :created_before, ->(param) { where('checksums.created_at < ?', param) if param.present? }
  scope :created_after, ->(param) { where('checksums.created_at > ?', param) if param.present? }
  scope :datetime_before, ->(param) { where('checksums.datetime < ?', param) if param.present? }
  scope :datetime_after, ->(param) { where('checksums.datetime > ?', param) if param.present? }
  scope :with_generic_file_identifier, lambda { |param|
    if param.present?
      joins(:generic_file)
        .where('generic_files.identifier = ?', param)
    end
  }
  scope :with_generic_file_identifier_like, lambda { |param|
    if param.present?
      joins(:generic_file)
        .where('generic_files.identifier LIKE ?', "%#{param}%")
    end
  }
  # TODO: find a way to make something like this work.
  # scope :with_institution, ->(param) {
  #   joins(:generic_file).joins(:intellectual_objects)
  #       .where('intellectual_objects.institution_id = ?', param) unless param.blank?
  # }
end
