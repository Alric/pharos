class UserPolicy < ApplicationPolicy

  def create?
    user.admin? || user.institutional_admin?
  end

  def new?
    create?
  end

  def institution_breakdown?
    user.admin? || (user.institutional_admin? && user.institution.identifier == 'aptrust.org')
  end

  def alert_summary?
    user.admin? || user.institutional_admin?
  end

  def alert_index?
    user.admin? || user.institutional_admin?
  end

  def delete_institution?
    false
  end

  def index?
    user.admin? ||
        (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  def snapshot?
    user.admin?
  end

  def spot_test_restoration?
    user.admin?
  end

  def vacuum?
    user.admin?
  end

  def account_confirmations?
    user.admin?
  end

  def indiv_confirmation_email?
    user.admin? || (user.institutional_admin? && (user.institution_id == record.institution_id)) || user == record
  end

  def confirm_account?
    user == record
  end

  def deletion_notifications?
    user.admin?
  end

  def search?
    true
  end

  def feed?
    true
  end

  def nil_index?
    true
  end

  def nil_file?
    true
  end

  def nil_object?
    true
  end

  def nil_event?
    true
  end

  def object_create?
    user.admin?
  end

  def set_restoration_status?
    user.admin?
  end

  def notify_of_failed_fixity?
    user.admin?
  end

  def notify_of_successful_restoration?
    user.admin?
  end

  def state_show?
    user.admin?
  end

  def nil_bulk_job_show?
    user.admin? || user.institutional_admin?
  end

  def nil_item?
    true
  end

  def checksum_index?
    user.admin?
  end

  def checksum_show?
    user.admin?
  end

  def show?
    user == record ||  user.admin? ||
        (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  def verify_email?
    user == record || user.admin? || (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  def email_confirmation?
    user == record
  end

  def enable_otp?
    user == record ||  user.admin? ||
        (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  def disable_otp?
    user == record ||  user.admin? ||
        (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  def change_authy_phone_number?
    user == record ||  user.admin? ||
        (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  def register_authy_user?
    user == record ||  user.admin? ||
        (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  def verify_twofa?
    user == record
  end

  def generate_backup_codes?
    user == record ||  user.admin? ||
        (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  def stale_user_notification?
    user.admin?
  end

  def edit?
    update?
  end

  def update?
    return false if (user.institutional_admin? && record.admin?)
    user == record || user.admin? ||
        (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  # institutional_admin cannot generate key for institutional user
  def generate_api_key?
    user.admin? || user == record
  end

  def update_password?
    user.admin? || user == record
  end

  def edit_password?
    update_password?
  end

  def admin_password_reset?
    user.admin?
  end

  def forced_password_update?
    return false if (user.institutional_admin? && record.admin?)
    user.admin? || (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  def mass_forced_password_update?
    user.admin? || user.institutional_admin?
  end

  def deactivate?
    return false if (user.institutional_admin? && record.admin?)
    user.admin? || (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  def reactivate?
    deactivate?
  end

  def work_item_batch_update?
    user.admin?
  end

  def not_checked_since?
    user.admin?
  end

  def intellectual_object_create?
    user.admin?
  end

  def destroy?
    return false if user == record
    return false if (user.institutional_admin? && record.admin?)
    user.admin? ||
        (user.institutional_admin? && (user.institution_id == record.institution_id))
  end

  class Scope
    attr_reader :user, :scope

    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      if user.admin?
        scope.all
      else
        scope.where(institution_id: user.institution_id)
      end
    end
  end
end
