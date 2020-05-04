class BulkDeleteJobsController < ApplicationController
  include FilterCounts
  before_action :authenticate_user!
  before_action :load_institution, only: :index
  before_action :load_job, only: :show
  after_action :verify_authorized

  def index
    authorize @institution, :bulk_delete_job_index?
    @bulk_delete_jobs = current_user.admin? && @institution.identifier == Pharos::Application::APTRUST_ID ? BulkDeleteJob.all : BulkDeleteJob.discoverable(current_user).with_institution(@institution.id)
    filter_sort_and_count
    page_results(@bulk_delete_jobs)
    respond_to do |format|
      format.json { render json: { count: @count, next: @next, previous: @previous, results: @paged_results.map(&:serializable_hash) } }
      format.html {}
    end
  end

  def show
    if @bulk_job.nil?
      authorize current_user, :nil_bulk_job_show?
      respond_to do |format|
        format.json { render(body: nil, status: :not_found) && return }
        format.html { redirect_to root_url, alert: 'That Bulk Delete Job could not be found.' }
      end
    else
      authorize @bulk_job
      @institution = Institution.find(@bulk_job.institution_id)
      respond_to do |format|
        format.json { render json: @bulk_job.serializable_hash }
        format.html {}
      end
    end
  end

  private

  def load_institution
    @institution = if current_user.admin? && params[:institution_id]
                     Institution.find(params[:institution_id])
                   elsif current_user.admin? && params[:institution_identifier]
                     Institution.where(identifier: params[:institution_identifier]).first
                   else
                     current_user.institution
                   end
  end

  def load_job
    if params[:id]
      begin
        @bulk_job = BulkDeleteJob.find(params[:id])
      rescue
        # Don't throw RecordNotFound. Just return 404 above.
      end
    end
  end

  def filter_sort_and_count
    @bulk_delete_jobs = @bulk_delete_jobs
                        .with_institution(params[:institution])
    @selected = {}
    get_institution_counts(@bulk_delete_jobs)
    count = @bulk_delete_jobs.count
    set_page_counts(count)
    case params[:sort]
    when 'date'
      @bulk_delete_jobs = @bulk_delete_jobs.order('updated_at DESC')
    when 'name'
      @bulk_delete_jobs = @bulk_delete_jobs.order('id').reverse_order
    when 'institution'
      @bulk_delete_jobs = @bulk_delete_jobs.joins(:institution).order('institutions.name')
    end
  end
end
