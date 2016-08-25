class WorkItemPolicy < ApplicationPolicy

  def create?
    user.admin?
  end

  def new?
    create?
  end

  def index?
    record.first.nil? || user.admin? ||  (user.institution.id == record.first.institution_id)
  end

  def search?
    record.first.nil? || user.admin? || (user.institution.id == record.first.institution_id)
  end

  def admin_api?
    user.admin?
  end

  def admin_show?
    user.admin?
  end

  def show?
    record.nil? || user.admin? || (user.institution.id == record.institution_id)
  end

  def update?
    user.admin? ||
        (user.institutional_admin? && (user.institution.id == record.institution_id))
  end

  def edit?
    update?
  end

  def destroy?
    false
  end

  def set_restoration_status?
    record.nil? || user.admin?
  end

  def items_for_delete?
    user.admin?
  end

  def items_for_restore?
    user.admin?
  end

  def items_for_dpn?
    user.admin?
  end

  def delete_test_items?
    user.admin?
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
        scope.where(institution: user.institution.id)
      end
    end
  end
end
