class InstitutionsController < ApplicationController
  inherit_resources
  before_action :authenticate_user!
  before_action :load_institution, only: [:edit, :update, :show, :destroy, :single_snapshot]
  respond_to :json, :html
  after_action :verify_authorized, :except => :index
  after_action :verify_policy_scoped, :only => :index

  def index
    respond_to do |format|
      @institutions = policy_scope(Institution)
      @institutions = @institutions.order('name')
      @sizes = find_all_sizes unless request.url.include?("/api/")
      @count = @institutions.count
      page_results(@institutions)
      format.json { render json: {count: @count, next: @next, previous: @previous, results: @institutions.map{ |item| item.serializable_hash }} }
      format.html { render 'index' }
    end
  end

  def new
    @institution = Institution.new
    authorize @institution
  end

  def create
    @institution = build_resource
    authorize @institution
    create!
  end

  def show
    authorize @institution || Institution.new
    if @institution.nil? || @institution.state == 'D'
      respond_to do |format|
        format.json {render body: nil, :status => 404}
        format.html {
          redirect_to root_path
          flash[:alert] = 'The institution you requested does not exist or has been deleted.'
        }
      end
    else
      set_recent_objects
      respond_to do |format|
        format.json { render json: @institution }
        format.html
      end
    end
  end

  def edit
    authorize @institution
    edit!
  end

  def update
    authorize @institution
    update!
  end

  def destroy
    authorize current_user, :delete_institution?
    destroy!
  end

  def single_snapshot
    authorize @institution, :snapshot?
    if @institution.is_a?(MemberInstitution)
      @snapshots = @institution.snapshot
      respond_to do |format|
        format.json { render json: { institution: @institution.name, snapshots: @snapshots.map{ |item| item.serializable_hash } } }
        format.html {
          redirect_to root_path
          flash[:notice] = "A snapshot of #{@institution.name} has been taken and archived on #{@snapshots.first.audit_date}. Please see the reports page for that analysis."
        }
      end
    else
      @snapshot = @institution.snapshot
      respond_to do |format|
        format.json { render json: { institution: @institution.name, snapshot: @snapshot.serializable_hash }  }
        format.html {
          redirect_to root_path
          flash[:notice] = "A snapshot of #{@institution.name} has been taken and archived on #{@snapshot.audit_date}. Please see the reports page for that analysis."
        }
      end
    end
  end

  def group_snapshot
    authorize current_user, :snapshot?
    @snapshots = []
    email_snap_hash = {}
    MemberInstitution.all.each do |institution|
      current_snaps = institution.snapshot
      @snapshots.push(current_snaps)
      current_snaps.each do |snap|
        email_snap_hash[institution.name] = snap.apt_bytes if snap.snapshot_type == 'Subscribers Included'
      end
    end
    total_bytes = Institution.total_file_size_across_repo
    email_snap_hash['APTrust'] = total_bytes
    NotificationMailer.snapshot_notification(email_snap_hash).deliver!
    respond_to do |format|
      format.json { render json: { snapshots: @snapshots.each { |snap_set| snap_set.map { |item| item.serializable_hash } } } }
      format.html {
        redirect_to root_path
        flash[:notice] = "A snapshot of all Member Institutions has been taken and archived on #{@snapshots.first.first.audit_date}. Please see the reports page for that analysis."
      }
    end
  end

  private
  def load_institution
    @institution = params[:institution_identifier].nil? ? current_user.institution : Institution.where(identifier: params[:institution_identifier]).first
  end

  # Never trust parameters from the scary internet, only allow the white list through.
  def build_resource_params
    params[:action] == 'new' ? [] : [params.require(:institution).permit(:name, :identifier, :brief_name, :dpn_uuid, :type, :member_institution_id)]
  end

  def set_recent_objects
    if (current_user.admin? && current_user.institution.identifier == @institution.identifier)  ||
        (current_user.institutional_admin? && current_user.institution.name == 'APTrust' && current_user.institution.identifier == @institution.identifier)
      @items = WorkItem.limit(10).order('date').reverse_order
      @size = GenericFile.where(state: 'A').sum(:size)
      @item_count = WorkItem.all.count
      @object_count = IntellectualObject.with_state('A').size
    else
      items = WorkItem.with_institution(@institution.id)
      @items = items.limit(10).order('date').reverse_order
      @size = @institution.active_files.sum(:size)
      @item_count = items.size
      @object_count = @institution.intellectual_objects.with_state('A').size
    end
  end

  def find_all_sizes
    size = {}
    total_size = 0
    Institution.all.each do |inst|
      size[inst.name] = inst.active_files.sum(:size)
      total_size = size[inst.name] + total_size
    end
    size['APTrust'] = total_size
    size
  end

end
