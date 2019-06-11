class WorkItemsController < ApplicationController
  include FilterCounts
  include SearchAssist
  include RequeueHelper
  include SelectItems
  require 'uri'
  require 'net/http'
  respond_to :html, :json
  before_action :authenticate_user!
  before_action :set_item, only: [:show, :requeue, :spot_test_restoration]
  before_action :init_from_params, only: :create
  before_action :load_institution, only: :index
  after_action :verify_authorized

  def index
    (current_user.admin? and params[:institution].present?) ? @items = WorkItem.with_institution(params[:institution]) : @items = WorkItem.readable(current_user)
    filter_count_and_sort
    page_results(@items)
    (@items.nil? || @items.empty?) ? (authorize current_user, :nil_index?) : (authorize @items)
    respond_to do |format|
      format.json {
        current_user.admin? ?
            json_list = @paged_results.map { |item| item.serializable_hash } :
            json_list = @paged_results.map { |item| item.serializable_hash(except: [:node, :pid]) }
        render json: { count: @count, next: @next, previous: @previous, results: json_list }
      }
      format.html { }
    end
  end

  def create
    authorize @work_item
    respond_to do |format|
      if @work_item.save
        format.json { render json: @work_item, status: :created }
      else
        format.json { render json: @work_item.errors, status: :unprocessable_entity }
      end
    end
  end

  def show
    if @work_item
      authorize @work_item
      (params[:with_state_json] == 'true' && current_user.admin?) ? @show_state = true : @show_state = false
      respond_to do |format|
        current_user.admin? ?
            format.json { render json: @work_item.serializable_hash } :
            format.json { render json: @work_item.serializable_hash(except: [:node, :pid]) }
        format.html
      end
    else
      authorize current_user, :nil_index?
      respond_to do |format|
        format.json { render body: nil, status: :not_found }
        format.html { redirect_to root_url, alert: 'That Work Item could not be found.' }
      end
    end
  end

  def requeue
    if @work_item
      authorize @work_item
      if @work_item.status == Pharos::Application::PHAROS_STATUSES['success']
        respond_to do |format|
          format.json { render :json => { status: 'error', message: 'Work Items that have succeeded cannot be requeued.' }, :status => :conflict }
          format.html { }
        end
      else
        options = set_options(params)
        @work_item.requeue_item(options)
        (options[:stage] ? response = issue_requeue_http_post(options[:stage]) : response = issue_requeue_http_post('')) unless Rails.env.development?
        Rails.env.development? ? status = set_requeue_response_dev : status = set_requeue_response(response)
        respond_to do |format|
          format.json { render json: { status: status[:status], body: status[:body] } }
          format.html { redirect_to work_item_path(@work_item.id) }
        end
      end
    else
      authorize current_user, :nil_index?
      respond_to do |format|
        format.json { render nothing: true, status: :not_found }
        format.html { redirect_to root_url, alert: 'That Work Item could not be found.' }
      end
    end
  end

  # Note that this method is available through the admin API, but is
  # not accessible to members. If we ever make it accessible to members,
  # we MUST NOT allow them to update :state, :node, or :pid!
  def update
    if params[:save_batch]
      authorize current_user, :work_item_batch_update?
      batch_update
      respond_to do |format|
        if @incomplete
          errors = @work_items.map(&:errors)
          format.json { render json: errors, status: :unprocessable_entity }
        else
          format.json { render json: array_as_json(@work_items), status: :ok }
        end
      end
    else
      find_and_update
      authorize @work_item
      respond_to do |format|
        @work_item.save ?
            format.json { render json: @work_item, status: :ok } :
            format.json { render json: @work_item.errors, status: :unprocessable_entity }
      end
    end
  end

  def ingested_since
    since = params[:since]
    begin
      dtSince = DateTime.parse(since)
    rescue
      # We'll get this below
    end
    respond_to do |format|
      if dtSince == nil
        authorize WorkItem.new, :admin_api?
        err = { 'error' => 'Param since must be a valid datetime' }
        format.json { render json: err, status: :bad_request }
      else
        @items = WorkItem.where("action='Ingest' and date >= ?", dtSince)
        authorize @items, :admin_api?
        format.json { render json: @items, status: :ok }
      end
    end
  end

  def set_restoration_status
    # Fix Apache/Passenger passthrough of %2f-encoded slashes in identifier
    params[:object_identifier] = params[:object_identifier].gsub(/%2F/i, "/")
    params[:node] = nil if params[:node] && params[:node] == ''
    restore = Pharos::Application::PHAROS_ACTIONS['restore']
    @item = WorkItem.where(object_identifier: params[:object_identifier],
                           action: restore).order(created_at: :desc).first
    if @item.nil?
      authorize current_user
      render body: nil, status: :not_found and return
    else
      authorize @item
      succeeded = @item.update_attributes(params_for_status_update)
      respond_to do |format|
        if succeeded == false
          errors = @item.errors.full_messages
          format.json { render json: errors, status: :bad_request }
        else
          format.json { render json: {result: 'OK'}, status: :ok }
        end
      end
    end
  end

  # These three methods were commented out on June 11, 2019 as they are legacy methods that were
  # used in bagman's 1.0 services but are no longer used. They will be deleted in due time if no
  # requests are made by depositors to bring them back. They were never advertised so the hope is
  # there will be no trouble removing them.

  # def items_for_restore
  #   @items = WorkItem.readable(current_user)
  #   select_items('restore', request)
  #   authorize @items
  #   respond_to do |format|
  #     format.json { render json: @items, status: :ok }
  #   end
  # end
  #
  # def items_for_dpn
  #   @items = WorkItem.readable(current_user)
  #   select_items('dpn', request)
  #   authorize @items
  #   respond_to do |format|
  #     format.json { render json: @items, status: :ok }
  #   end
  # end
  #
  # def items_for_delete
  #   @items = WorkItem.readable(current_user)
  #   select_items('delete', request)
  #   authorize @items
  #   respond_to do |format|
  #     format.json { render json: @items, status: :ok }
  #   end
  # end

  def notify_of_successful_restoration
    authorize current_user
    params[:since] = (DateTime.now - 24.hours) unless params[:since]
    @items = WorkItem.with_action(Pharos::Application::PHAROS_ACTIONS['restore'])
                     .with_status(Pharos::Application::PHAROS_STATUSES['success'])
                     .with_stage(Pharos::Application::PHAROS_STAGES['record'])
                     .updated_after(params[:since])
    institutions = @items.distinct.pluck(:institution_id)
    number_of_emails = 0
    inst_list = []
    institutions.each do |inst|
      inst_items = @items.where(institution_id: inst)
      institution = Institution.find(inst)
      log = Email.log_multiple_restoration(inst_items)
      NotificationMailer.multiple_restoration_notification(@items, log, institution).deliver!
      number_of_emails += 1
      inst_list.push(institution.name)
    end
    if number_of_emails == 0
      respond_to do |format|
        format.json { render json: { message: 'No new successful restorations, no emails sent.' }, status: 204 }
      end
    else
      inst_pretty = inst_list.join(', ')
      respond_to do |format|
        format.json { render json: { message: "#{number_of_emails} sent. Institutions that received a successful restoration notification: #{inst_pretty}." }, status: 200 }
      end
    end
  end

  def spot_test_restoration
    authorize current_user
    log = Email.log_restoration(@work_item.id)
    NotificationMailer.spot_test_restoration_notification(@work_item, log).deliver!
    @work_item.note += " Email sent to admins at #{@work_item.institution.name}"
    @work_item.save
    respond_to do |format|
      format.json { render json: @work_item, status: :ok }
    end
  end

  def api_search
    authorize WorkItem, :admin_api?
    current_user.admin? ? @items = WorkItem.all : @items = WorkItem.with_institution(current_user.institution_id)
    search_fields = [:name, :etag, :bag_date, :stage, :status, :institution,
                     :retry, :object_identifier, :generic_file_identifier,
                     :node, :needs_admin_review, :process_after]
    params[:retry] = to_boolean(params[:retry]) if params[:retry]
    params[:needs_admin_review] = to_boolean(params[:needs_admin_review]) if params[:needs_admin_review]
    search_fields.each do |field|
      if params[field].present?
        if field == :node and params[field] == 'null'
          @items = @items.where('node is null')
        elsif field == :assignment_pending_since and params[field] == 'null'
          @items = @items.where('assignment_pending_since is null')
        elsif field == :institution
          @items = @items.with_institution(params[field])
        else
          @items = @items.where(field => params[field])
        end
      end
    end
    @items = @items.with_action(params[:item_action]) if params[:item_action].present?
    respond_to do |format|
      format.json { render json: @items, status: :ok }
    end
  end

  private

  def load_institution
    (current_user.admin? and params[:institution].present?) ? @institution = Institution.find(params[:institution]) : @institution = current_user.institution
  end

  def array_as_json(list_of_work_items)
    list_of_work_items.map { |item| item.serializable_hash }
  end

  def init_from_params
    @work_item = WorkItem.new(writable_work_item_params)
    # When we're migrating data from Fluctus, we're
    # connecting as admin, and we want to preserve the existing
    # user attribute from the old system. In all other cases,
    # when we create a WorkItem, user should be set to the
    # current logged-in user.
    if !current_user.admin? || @work_item.user.blank?
      @work_item.user = current_user.email
    end
  end

  def find_and_update
    # Parse date explicitly, or ActiveRecord will not find records when date format string varies.
    set_item
    if @work_item
      @work_item.update(writable_work_item_params)
      # Never let non-admin set WorkItem.user.
      # Admin sets user only when importing WorkItems from Fluctus.
      if !current_user.admin? || @work_item.user.blank?
        @work_item.user = current_user.email
      end
    end
  end

  def batch_update
    WorkItem.transaction do
      batch_work_item_update_params
      @work_items = []
      params[:work_items][:items].each do |current|
        wi = WorkItem.find(current['id'])
        wi.update(current)
        # Only admin can explicitly set user.
        wi.user = current_user.email if (!current_user.admin? || wi.user.blank?)
        @work_items.push(wi)
        unless wi.save
          @incomplete = true
          break
        end
      end
      raise ActiveRecord::Rollback
    end
  end

  # Changed from the default "work_item_params" because Rails was
  # enforcing these on GET requests to the API and complaining
  # that "work_item: {}" was empty in requests that only used
  # a query string.
  def writable_work_item_params
    params.require(:work_item).permit(:name, :etag, :bag_date, :bucket,
                                      :institution_id, :date, :note, :action,
                                      :stage, :status, :outcome, :retry,
                                      :pid, :node, :object_identifier, :user,
                                      :generic_file_identifier, :needs_admin_review,
                                      :queued_at, :size, :stage_started_at)
  end

  def batch_work_item_update_params
    params[:work_items] &&= params.require(:work_items)
                                   .permit(items: [:name, :etag, :bag_date, :bucket,
                                                   :institution_id, :date, :note, :action,
                                                   :stage, :status, :outcome, :retry,
                                                   :node, :size, :stage_started_at, :id])
  end

  def params_for_status_update
    params.permit(:object_identifier, :stage, :status, :note, :retry,
                  :node, :pid, :needs_admin_review)
  end

  def set_item
    @institution = current_user.institution
    if params[:id].blank? == false
      begin
        @work_item = WorkItem.readable(current_user).find(params[:id])
      rescue
        # If we don't catch this, we get an internal server error
      end
    else
        @work_item = WorkItem.where(etag: params[:etag],
                                    name: params[:name],
                                    bag_date: params[:bag_date]).first
    end
  end

  def deletion_uri

  end

  def filter_count_and_sort
    @selected = {}
    parameter_deprecation
    @items = item_filter(@items, params)
    get_status_counts(@items)
    get_stage_counts(@items)
    get_action_counts(@items)
    get_institution_counts(@items)
    params[:sort] = 'date' if params[:sort].nil?
    case_sort(@items, params, 'item')
    count = @items.count
    set_page_counts(count)
  end

  def parameter_deprecation
    params[:name] = params[:name_contains] if params[:name_contains]
    params[:name] = params[:name_exact] if params[:name_exact]
    params[:object_identifier] = params[:object_identifier_contains] if params[:object_identifier_contains]
    params[:file_identifier] = params[:file_identifier_contains] if params[:file_identifier_contains]
    params[:etag] = params[:etag_contains] if params[:etag_contains]
  end

end
