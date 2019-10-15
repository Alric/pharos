class IntellectualObjectsController < ApplicationController
  include FilterCounts
  include SearchAssist
  include BulkDeletions
  inherit_resources
  before_action :authenticate_user!
  before_action :load_institution, only: [:index, :create]
  before_action :load_object, only: [:show, :edit, :update, :destroy, :confirm_destroy, :finished_destroy, :send_to_dpn, :restore]
  after_action :verify_authorized

  def index
    authorize @institution
    (current_user.admin? && @institution.identifier == Pharos::Application::APTRUST_ID) ? @intellectual_objects = IntellectualObject.all : @intellectual_objects = IntellectualObject.discoverable(current_user).with_institution(@institution.id)
    filter_count_and_sort
    page_results(@intellectual_objects)
    respond_to do |format|
      format.json { render json: { count: @count, next: @next, previous: @previous, results: @paged_results.map { |item| item.serializable_hash } } }
      format.html { index! }
    end
  end

  def create
    authorize current_user, :intellectual_object_create?
    @intellectual_object = IntellectualObject.new(create_params)
    @intellectual_object.state = 'A'
    if @intellectual_object.save
      respond_to do |format|
        format.json { render json: @intellectual_object, status: :created }
        format.html {
          render status: :created
          super
        }
      end
    else
      respond_to do |format|
        format.json { render json: @intellectual_object.errors, status: :unprocessable_entity }
        format.html {
          render status: :unprocessable_entity
          super
        }
      end
    end
  end

  def show
    if @intellectual_object
      authorize @intellectual_object
      @institution = @intellectual_object.institution
      respond_to do |format|
        format.json { render json: object_as_json }
        format.html
      end
    else
      authorize current_user, :nil_object?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'This object could not be found.', url: request.original_url }, :status => 404 }
        format.html { redirect_to root_url, alert: "An intellectual object with identifer: #{params[:intellectual_object_identifier]} could not be found." }
      end
    end
  end

  def edit
    authorize @intellectual_object
    edit!
  end

  def update
    if @intellectual_object
      authorize @intellectual_object
      @intellectual_object.update!(update_params)
      respond_to do |format|
        format.json { render json: object_as_json }
        format.html { redirect_to intellectual_object_path(@intellectual_object) }
      end
    else
      authorize current_user, :nil_object?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'This object could not be found.', url: request.original_url }, :status => 404 }
        format.html { redirect_to root_url, alert: "An intellectual object with identifer: #{params[:intellectual_object_identifier]} could not be found." }
      end
    end
  end

  def destroy
    if @intellectual_object
      authorize @intellectual_object, :soft_delete?
      pending = WorkItem.pending_action(@intellectual_object.identifier)
      if @intellectual_object.state == 'D'
        message = 'This object has already been deleted.'
        status = set_status_error(message)
      elsif pending.nil?
        object_or_file_start_destroy('object', @intellectual_object, current_user)
        message = 'An email has been sent to the administrators of this institution to confirm deletion of this object.'
        status = set_status_ok(message)
      else
        message = "Your object cannot be deleted at this time due to a pending #{pending.action} request. You may delete this object after the #{pending.action} request has completed."
        status = set_status_error(message)
      end
      respond_to do |format|
        format.json { render json: { status: status[:one], message: message }, status: status[:two] }
        format.html { redirect_to @intellectual_object }
      end
    else
      authorize current_user, :nil_object?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'This object could not be found.', url: request.original_url }, :status => 404 }
        format.html { redirect_to root_url, alert: "An intellectual object with identifer: #{params[:intellectual_object_identifier]} could not be found." }
      end
    end
  end

  def confirm_destroy
    authorize @intellectual_object, :soft_delete?
    if @intellectual_object.confirmation_token.nil? && (WorkItem.with_action(Pharos::Application::PHAROS_ACTIONS['delete']).with_object_identifier(@intellectual_object.identifier).count != 0)
      message = 'This deletion request has already been confirmed and queued for deletion by someone else.'
      status = set_status_ok(message)
    else
      if params[:confirmation_token] == @intellectual_object.confirmation_token.token
        object_confirmed_destroy(params[:requesting_user_id], current_user)
        message = "Delete job has been queued for object: #{@intellectual_object.title}. Depending on the size of the object, it may take a few minutes for all associated files to be marked as deleted."
        status = set_status_ok(message)
      else
        message = 'Your object cannot be deleted at this time due to an invalid confirmation token. Please contact your APTrust administrator for more information.'
        status = set_status_error(message)
      end
    end
    respond_to do |format|
      format.json { render json: { status: status[:one], message: message }, status: status[:two] }
      format.html { redirect_to @intellectual_object }
    end
  end

  def finished_destroy
    authorize @intellectual_object
    object_finish_destroy
    message = "Delete job has been finished for object: #{@intellectual_object.title}. Object has been marked as deleted."
    status = set_status_ok(message)
    respond_to do |format|
        format.json { render json: { status: status[:one], message: message }, status: status[:two] }
        format.html { redirect_to root_path }
    end
  end

  def send_to_dpn
    authorize @intellectual_object, :dpn?
    dpn_item = nil
    message = ""
    api_status_code = :ok
    pending = WorkItem.pending_action(@intellectual_object.identifier)
    if Pharos::Application.config.show_send_to_dpn_button == false
      message = 'We are not currently sending objects to DPN.'
      api_status_code = :conflict
    elsif @intellectual_object.institution.dpn_uuid == ''
      message = 'This item cannot be sent to DPN because the depositing institution is not a DPN member.'
      api_status_code = :conflict
    elsif @intellectual_object.in_dpn?
      message = 'This item has already been sent to DPN.'
      api_status_code = :conflict
    elsif @intellectual_object.state == 'D'
      message = 'This item has been deleted and cannot be sent to DPN.'
      api_status_code = :conflict
    elsif @intellectual_object.too_big?
      message = 'This item cannot be sent to DPN at this time because it is greater than 250GB.'
      api_status_code = :conflict
    elsif pending.nil?
      dpn_item = WorkItem.create_dpn_request(@intellectual_object.identifier, current_user.email)
      message = 'Your item has been queued for DPN.'
    else
      message = "Your object cannot be sent to DPN at this time due to a pending #{pending.action} request."
      api_status_code = :conflict
    end
    respond_to do |format|
      status = dpn_item.nil? ? 'error' : 'ok'
      item_id = dpn_item.nil? ? 0 : dpn_item.id
      format.json {
        if (status == 'ok')
          render json: dpn_item, status: api_status_code
        else
          render json: {status: status, message: message}, status: api_status_code
        end }
      format.html {
        dpn_item.nil? ? flash[:alert] = message : flash[:notice] = message
        redirect_to @intellectual_object
      }
    end
  end

  def restore
    if @intellectual_object
      authorize @intellectual_object, :restore?
      message = ""
      api_status_code = :ok
      restore_item = nil
      pending = WorkItem.pending_action(@intellectual_object.identifier)
      if @intellectual_object.state == 'D'
        api_status_code = :conflict
        message = 'This item has been deleted and cannot be queued for restoration.'
      elsif pending.nil?
        (@intellectual_object.storage_option == 'Standard') ?
            restore_item = WorkItem.create_restore_request(@intellectual_object.identifier, current_user.email) :
            restore_item = WorkItem.create_glacier_restore_request(@intellectual_object.identifier, current_user.email)
        message = 'Your item has been queued for restoration.'
      else
        api_status_code = :conflict
        message = "Your object cannot be queued for restoration at this time due to a pending #{pending.action} request."
      end
      respond_to do |format|
        status = restore_item.nil? ? 'error' : 'ok'
        item_id = restore_item.nil? ? 0 : restore_item.id
        format.json { render :json => { status: status, message: message, work_item_id: item_id }, :status => api_status_code }
        format.html {
          restore_item.nil? ? flash[:alert] = message : flash[:notice] = message
          redirect_to @intellectual_object
        }
      end
    else
      authorize current_user, :nil_object?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'This object could not be found.', url: request.original_url }, :status => 404 }
        format.html { redirect_to root_url, alert: "An intellectual object with identifer: #{params[:intellectual_object_identifier]} could not be found." }
      end
    end
  end

  private

  def object_as_json
    include_list = []
    include_list.push(:premis_events, active_files: {include: [:checksums, :premis_events]}) if params[:include_all_relations]
    include_list.push(:premis_events) if params[:include_events]
    include_list.push(active_files: {include: [:checksums]}) if params[:include_files]
    include_list.push(:ingest_state) if (params[:with_ingest_state] == 'true' && current_user.admin?)
    options_hash = {include: include_list}
    data = @intellectual_object.serializable_hash(options_hash)
    data[:state] = @intellectual_object.state
    data[:generic_files] = data.delete('active_files') if params[:include_all_relations] || params[:include_files]
    data
  end

  def create_params
    params.require(:intellectual_object).permit(:institution_id, :title, :etag, :storage_option,
                                                :description, :access, :identifier,
                                                :bag_name, :alt_identifier, :ingest_state,
                                                :bag_group_identifier, generic_files_attributes:
                                                [:id, :uri, :identifier,
                                                 :size, :created, :modified, :file_format,
                                                 premis_events_attributes:
                                                 [:id, :identifier, :event_type, :date_time,
                                                  :outcome, :outcome_detail,
                                                  :outcome_information, :detail,
                                                  :object, :agent, :intellectual_object_id,
                                                  :generic_file_id, :institution_id,
                                                  :created_at, :updated_at]],
                                                premis_events_attributes:
                                                [:id, :identifier, :event_type,
                                                 :date_time, :outcome, :outcome_detail,
                                                 :outcome_information, :detail, :object,
                                                 :agent, :intellectual_object_id,
                                                 :generic_file_id, :institution_id,
                                                 :created_at, :updated_at])

  end

  def update_params
    params.require(:intellectual_object).permit(:title, :description, :access, :ingest_state, :storage_option,
                                                :alt_identifier, :state, :dpn_uuid, :etag, :bag_group_identifier)
  end

  def load_object
    if params[:intellectual_object_identifier]
      @intellectual_object = IntellectualObject.where(identifier: params[:intellectual_object_identifier]).first
      # if @intellectual_object.nil?
      #   msg = "IntellectualObject '#{params[:intellectual_object_identifier]}' not found"
      #   raise ActionController::RoutingError.new(msg)
      # end
    else
      @intellectual_object ||= IntellectualObject.readable(current_user).find(params[:id])
    end
  end

  def load_institution
    if current_user.admin? and params[:institution_id]
      @institution = Institution.find(params[:institution_id])
    elsif current_user.admin? and params[:institution_identifier]
      @institution = Institution.where(identifier: params[:institution_identifier]).first
    else
      @institution = current_user.institution
    end
  end

  def filter_count_and_sort
    @selected = {}
    parameter_deprecation
    @intellectual_objects = object_filter(@intellectual_objects, params)
    get_object_format_counts(@intellectual_objects)
    get_institution_counts(@intellectual_objects)
    get_object_access_counts(@intellectual_objects)
    get_state_counts(@intellectual_objects)
    params[:sort] = 'name' if params[:sort].nil?
    case_sort(@intellectual_objects, params, 'object')
    count = @intellectual_objects.count
    set_page_counts(count)
  end

  def parameter_deprecation
    params[:identifier] = params[:identifier_like] if params[:identifier_like]
    params[:description] = params[:description_like] if params[:description_like]
    params[:bag_group_identifier] = params[:bag_group_identifier_like] if params[:bag_group_identifier_like]
    params[:bag_name] = params[:bag_name_like] if params[:bag_name_like]
    params[:alt_identifier] = params[:alt_identifier_like] if params[:alt_identifier_like]
    params[:etag] = params[:etag_like] if params[:etag_like]
  end

end
