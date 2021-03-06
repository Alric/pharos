class IntellectualObjectsController < ApplicationController
  include FilterCounts
  inherit_resources
  before_action :authenticate_user!
  before_action :load_institution, only: [:index, :create]
  before_action :load_object, only: [:show, :edit, :update, :destroy, :confirm_destroy, :finished_destroy, :restore]
  after_action :verify_authorized

  def index
    authorize @institution
    (current_user.admin? && @institution.identifier == Pharos::Application::APTRUST_ID) ? @intellectual_objects = IntellectualObject.all : @intellectual_objects = IntellectualObject.discoverable(current_user).with_institution(@institution.id)
    filter_count_and_sort
    page_results(@intellectual_objects)
    (params[:with_ingest_state] == 'true' && current_user.admin?) ? options_hash = {include: [:ingest_state]} : options_hash = {}
    respond_to do |format|
      format.json { render json: { count: @count, next: @next, previous: @previous, results: @paged_results.map { |item| item.serializable_hash(options_hash) } } }
      format.html {
        index!
      }
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
        respond_to do |format|
          format.json { head :conflict }
          format.html {
            redirect_to @intellectual_object
            flash[:alert] = 'This item has already been deleted.'
          }
        end
      elsif pending.nil?
        log = Email.log_deletion_request(@intellectual_object)
        ConfirmationToken.where(intellectual_object_id: @intellectual_object.id).delete_all #delete any old tokens. Only the new one should be valid
        token = ConfirmationToken.create(intellectual_object: @intellectual_object, token: SecureRandom.hex)
        token.save!
        NotificationMailer.deletion_request(@intellectual_object, current_user, log, token).deliver!
        respond_to do |format|
          format.json { head :no_content }
          format.html {
            redirect_to @intellectual_object
            flash[:notice] = 'An email has been sent to the administrators of this institution to confirm deletion of this object.'
          }
        end
      else
        respond_to do |format|
          message = "Your object cannot be deleted at this time due to a pending #{pending.action} request. " +
              "You may delete this object after the #{pending.action} request has completed."
          format.json {
            render :json => { status: 'error', message: message }, :status => :conflict
          }
          format.html {
            redirect_to @intellectual_object
            flash[:alert] = message
          }
        end
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
      respond_to do |format|
        message = 'This deletion request has already been confirmed and queued for deletion by someone else.'
        format.json {
          render :json => { status: 'ok', message: message }, :status => :ok
        }
        format.html {
          redirect_to @intellectual_object
          flash[:notice] = message
        }
      end
    else
      if params[:confirmation_token] == @intellectual_object.confirmation_token.token
        confirmed_destroy
        respond_to do |format|
          format.json { head :no_content }
          format.html {
            flash[:notice] = "Delete job has been queued for object: #{@intellectual_object.title}. Depending on the size of the object, it may take a few minutes for all associated files to be marked as deleted."
            redirect_to root_path
          }
        end
      else
        respond_to do |format|
          message = 'Your object cannot be deleted at this time due to an invalid confirmation token. ' +
              'Please contact your APTrust administrator for more information.'
          format.json {
            render :json => { status: 'error', message: message }, :status => :conflict
          }
          format.html {
            redirect_to @intellectual_object
            flash[:alert] = message
          }
        end
      end
    end
  end

  def finished_destroy
    authorize @intellectual_object
    deletion_item = WorkItem.with_object_identifier(@intellectual_object.identifier).with_action(Pharos::Application::PHAROS_ACTIONS['delete']).order(updated_at: :desc).first
    if deletion_item.nil?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'There is no existing deletion request for the specified object.', intellectual_object_identifier: @intellectual_object.identifier}, :status => 404 }
        format.html { redirect_to root_url, alert: "An intellectual object with identifer: #{params[:intellectual_object_identifier]} could not be found." }
      end
      return
    end

    attributes = { event_type: Pharos::Application::PHAROS_EVENT_TYPES['delete'],
                   date_time: "#{Time.now}",
                   detail: 'Object deleted from S3 storage',
                   outcome: 'Success',
                   outcome_detail: deletion_item.user,
                   object: 'AWS Go SDK S3 Library',
                   agent: 'https://github.com/aws/aws-sdk-go',
                   identifier: SecureRandom.uuid
    }
    (deletion_item.aptrust_approver.nil? || deletion_item.aptrust_approver == '') ?
        attributes[:outcome_information] = "Object deleted at the request of #{deletion_item.user}. Institutional Approver: #{deletion_item.inst_approver}." :
        attributes[:outcome_information] = "Object deleted as part of bulk deletion at the request of #{deletion_item.user}. Institutional Approver: #{deletion_item.inst_approver}. APTrust Approver: #{deletion_item.aptrust_approver}"
    @intellectual_object.mark_deleted(attributes)
    respond_to do |format|
        format.json { head :no_content }
        format.html {
          flash[:notice] = "Delete job has been finished for object: #{@intellectual_object.title}. Object has been marked as deleted."
          redirect_to root_path
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
        if @intellectual_object.storage_option == 'Standard'
          restore_item = WorkItem.create_restore_request(@intellectual_object.identifier, current_user.email)
        else
          restore_item = WorkItem.create_glacier_restore_request(@intellectual_object.identifier, current_user.email)
        end

        message = 'Your item has been queued for restoration.'
      else
        api_status_code = :conflict
        message = "Your object cannot be queued for restoration at this time due to a pending #{pending.action} request."
      end
      respond_to do |format|
        status = restore_item.nil? ? 'error' : 'ok'
        item_id = restore_item.nil? ? 0 : restore_item.id
        format.json {
          render :json => { status: status, message: message, work_item_id: item_id }, :status => api_status_code
        }
        format.html {
          if restore_item.nil?
            flash[:alert] = message
          else
            flash[:notice] = message
          end
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
    current_user.admin? ? options_hash = {include: include_list} : options_hash = {include: include_list, except: [:bagit_profile_identifier]}

    data = @intellectual_object.serializable_hash(options_hash)
    data[:state] = @intellectual_object.state
    data[:generic_files] = data.delete('active_files') if params[:include_all_relations] || params[:include_files]
    data
  end

  def create_params
    params.require(:intellectual_object).permit(
      :access,
      :alt_identifier,
      :bag_group_identifier,
      :bag_name,
      :bagit_profile_identifier,
      :description,
      :etag,
      :identifier,
      :ingest_state,
      :institution_id,
      :internal_sender_description,
      :internal_sender_identifier,
      :source_organization,
      :storage_option,
      :title,
      # For generic files nested in intellectual object
      # in bulk create method.
      generic_files_attributes:
        [:id,
         :uri,
         :identifier,
         :size,
         :created,
         :modified,
         :file_format,
         # For premis events nested in generic file objects.
         # Used in bulk create.
         premis_events_attributes:
           [
             :agent,
             :created_at,
             :date_time,
             :detail,
             :event_type,
             :generic_file_id,
             :id,
             :identifier,
             :institution_id,
             :intellectual_object_id,
             :object,
             :outcome,
             :outcome_detail,
             :outcome_information,
             :updated_at
           ]],
      # For premis events attached to top-level intellectual
      # object. Used in bulk create.
      premis_events_attributes:
        [
          :agent,
          :created_at,
          :date_time,
          :detail,
          :event_type,
          :generic_file_id,
          :id,
          :identifier,
          :institution_id,
          :intellectual_object_id,
          :object,
          :outcome,
          :outcome_detail,
          :outcome_information,
          :updated_at
        ])
  end

  def update_params
    params.require(:intellectual_object).permit(
      :access,
      :alt_identifier,
      :bag_group_identifier,
      :bagit_profile_identifier,
      :description,
      :etag,
      :ingest_state,
      :internal_sender_description,
      :internal_sender_identifier,
      :source_organization,
      :state,
      :storage_option,
      :title
    )
  end

  def load_object
    if params[:intellectual_object_identifier]
      @intellectual_object = IntellectualObject.where(identifier: params[:intellectual_object_identifier]).first
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

  def confirmed_destroy
    requesting_user = User.find(params[:requesting_user_id])
    attributes = { requestor: requesting_user.email,
                   inst_app: current_user.email
    }
    @t = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        @intellectual_object.soft_delete(attributes)
        log = Email.log_deletion_confirmation(@intellectual_object)
        NotificationMailer.deletion_confirmation(@intellectual_object, requesting_user.id, current_user.id, log).deliver!
        ConfirmationToken.where(intellectual_object_id: @intellectual_object.id).delete_all
      end
      ActiveRecord::Base.connection_pool.release_connection
    end
    #t.join
  end

  def filter_count_and_sort
    params[:state] = 'A' if params[:state].nil?
    @intellectual_objects = @intellectual_objects
                              .with_institution(params[:institution])
                              .with_description(params[:description])
                              .with_description_like(params[:description_like])
                              .with_identifier(params[:identifier])
                              .with_identifier_like(params[:identifier_like])
                              .with_bag_group_identifier(params[:bag_group_identifier])
                              .with_bag_group_identifier_like(params[:bag_group_identifier_like])
                              .with_alt_identifier(params[:alt_identifier])
                              .with_alt_identifier_like(params[:alt_identifier_like])
                              .with_bag_name(params[:bag_name])
                              .with_bag_name_like(params[:bag_name_like])
                              .with_etag(params[:etag])
                              .with_etag_like(params[:etag_like])
                              .created_before(params[:created_before])
                              .created_after(params[:created_after])
                              .updated_before(params[:updated_before])
                              .updated_after(params[:updated_after])
                              .with_access(params[:access])
                              .with_file_format(params[:file_format])
                              .with_state(params[:state])
                              .with_source_organization(params[:source_organization])
                              .with_source_organization_like(params[:source_organization_like])
                              .with_internal_sender_identifier(params[:internal_sender_identifier])
                              .with_internal_sender_identifier_like(params[:internal_sender_identifier_like])
                              .with_internal_sender_description_like(params[:internal_sender_description])
    @selected = {}

    # Don't run counts for API requests
    if !api_request?
      get_object_format_counts(@intellectual_objects)
      get_institution_counts(@intellectual_objects)
      get_object_access_counts(@intellectual_objects)
      get_state_counts(@intellectual_objects)
    end

    set_page_counts(@intellectual_objects.count)
    params[:sort] = 'name' if params[:sort].nil?
    case params[:sort]
      when 'date'
        @intellectual_objects = @intellectual_objects.order('updated_at DESC')
      when 'name'
        @intellectual_objects = @intellectual_objects.order('bag_name').reverse_order
      when 'institution'
        @intellectual_objects = @intellectual_objects.joins(:institution).order('institutions.name')
    end
  end

end
