class SnapshotsController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized
  before_action :load_institution
  before_action :set_snapshots, only: :index
  before_action :find_snapshot, only: :show

  def index
    authorize @snapshots
    respond_to do |format|
      format.json { render json: { results: @snapshots.map(&:serializable_hash) } }
      format.html { render 'index' }
    end
  end

  def show
    authorize @snapshot
    respond_to do |format|
      format.json { render json: @snapshot.serializable_hash }
      format.html { render 'show' }
    end
  end

  private

  def load_institution
    @institution = current_user.institution
  end

  def set_snapshots
    @snapshots = if current_user.admin?
                   Snapshot.all
                 else
                   @institution.snapshots
                 end
  end

  def find_snapshot
    @snapshot = Snapshot.readable(current_user).find(params[:id])
  end
end
