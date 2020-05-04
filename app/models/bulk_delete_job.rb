# == Schema Information
#
# Table name: bulk_delete_jobs
#
#  id                        :bigint           not null, primary key
#  aptrust_approval_at       :datetime
#  aptrust_approver          :string
#  institutional_approval_at :datetime
#  institutional_approver    :string
#  note                      :text
#  requested_by              :string
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  institution_id            :integer          not null
#
class BulkDeleteJob < ApplicationRecord
  self.primary_key = 'id'
  # belongs_to :institution
  has_and_belongs_to_many :intellectual_objects
  has_and_belongs_to_many :generic_files
  has_and_belongs_to_many :emails

  validates :requested_by, :institution_id, presence: true

  ### Scopes
  scope :with_requested_by, ->(param) { where(requested_by: param) if param.present? }
  scope :with_institutional_approver, ->(param) { where(institutional_approver: param) if param.present? }
  scope :with_aptrust_approver, ->(param) { where(aptrust_approver: param) if param.present? }
  scope :created_before, ->(param) { where('bulk_delete_jobs.created_at < ?', param) if param.present? }
  scope :created_after, ->(param) { where('bulk_delete_jobs.created_at > ?', param) if param.present? }
  scope :updated_before, ->(param) { where('bulk_delete_jobs.updated_at < ?', param) if param.present? }
  scope :updated_after, ->(param) { where('bulk_delete_jobs.updated_at > ?', param) if param.present? }
  scope :institutional_approval_before, ->(param) { where('bulk_delete_jobs.institutional_approval_at < ?', param) if param.present? }
  scope :institutional_approval_after, ->(param) { where('bulk_delete_jobs.institutional_approval_at > ?', param) if param.present? }
  scope :aptrust_approval_before, ->(param) { where('bulk_delete_jobs.aptrust_approval_at < ?', param) if param.present? }
  scope :aptrust_approval_after, ->(param) { where('bulk_delete_jobs.aptrust_approval_at > ?', param) if param.present? }
  scope :with_institution_identifier, lambda { |param|
    if param.present?
      joins(:institution)
        .where('institutions.identifier = ?', param)
    end
  }
  scope :with_institution, ->(param) { where(institution_id: param) if param.present? }
  scope :with_intellectual_object, lambda { |param|
    if param.present?
      joins(:intellectual_object)
        .where('intellectual_objects.identifier = ?', param)
    end
  }
  scope :with_generic_file, lambda { |param|
    if param.present?
      joins(:generic_file)
        .where('generic_files.identifier = ?', param)
    end
  }
  scope :discoverable, lambda { |current_user|
    where(institution_id: current_user.institution.id) unless current_user.admin?
  }
  scope :readable, lambda { |current_user|
    where(institution_id: current_user.institution.id) unless current_user.admin?
  }

  def self.create_job(institution, user, objects = [], files = [])
    job = BulkDeleteJob.create(requested_by: user.email)
    job.institution_id = institution.id
    objects&.each do |obj|
      job.intellectual_objects.push(obj)
    end
    files&.each do |file|
      job.generic_files.push(file)
    end
    job.save!
    job
  end
end
