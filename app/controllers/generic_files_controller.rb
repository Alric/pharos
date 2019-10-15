class GenericFilesController < ApplicationController
  include FilterCounts
  include SearchAssist
  include BulkDeletions
  respond_to :html, :json
  before_action :authenticate_user!
  before_action :load_generic_file, only: [:show, :update, :destroy, :confirm_destroy, :finished_destroy, :restore]
  before_action :load_intellectual_object, only: [:create, :create_batch]
  before_action :set_format
  after_action :verify_authorized

  def index
    # Below can be removed during redesign if no problems appear.
    # if params[:alt_action]
    #   case params[:alt_action]
    #     when 'file_summary'
    #       load_intellectual_object
    #       authorize @intellectual_object
    #       file_summary
    #   end
    # else
    if params[:not_checked_since]
      authorize current_user, :not_checked_since?
      @generic_files = GenericFile.not_checked_since(params[:not_checked_since])
    else
      load_parent_object
      if @intellectual_object
        authorize @intellectual_object
        @generic_files = GenericFile.where(intellectual_object_id: @intellectual_object.id)
      else
        authorize @institution, :index_through_institution?
        (current_user.admin? && @institution.identifier == Pharos::Application::APTRUST_ID) ? @generic_files = GenericFile.all : @generic_files = GenericFile.with_institution(@institution.id)
      end
    end
    filter_count_and_sort
    page_results(@generic_files)
    respond_to do |format|
      format.json { render json: {count: @count, next: @next, previous: @previous, results: @paged_results.map { |f| f.serializable_hash }} }
      format.html {}
    end
    # end
  end

  def show
    if @generic_file
      authorize @generic_file
      respond_to do |format|
        format.json { render json: object_as_json }
        format.html { }
      end
    else
      authorize current_user, :nil_file?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'This file could not be found. Please check to make sure the identifier was properly escaped.', url: request.original_url }, status: 404 }
        format.html { redirect_to root_url, alert: "A Generic File with identifier: #{params[:generic_file_identifier]} was not found. Please check to make sure the identifier was properly escaped." }
      end
    end
  end

  def create
    authorize current_user, :object_create?
    @generic_file = @intellectual_object.generic_files.new(single_generic_file_params)
    @generic_file.state = 'A'
    @generic_file.institution_id = @intellectual_object.institution_id
    respond_to do |format|
      if @generic_file.save
        format.json { render json: object_as_json, status: :created }
      else
        log_model_error(@generic_file)
        format.json { render json: @generic_file.errors, status: :unprocessable_entity }
      end
    end
  end

  # This method is open to admin only, through the admin API.
  def create_batch
    authorize @intellectual_object, :create?
    begin
      files = JSON.parse(request.body.read)
    rescue JSON::ParserError, Exception => e
      respond_to do |format|
        format.json { render json: {error: "JSON parse error: #{e.message}"}, status: 400 } and return
      end
    end
    GenericFile.transaction do
      @generic_files = []
      files.each do |gf|
        file = @intellectual_object.generic_files.new(gf)
        file.state = 'A'
        file.institution_id = @intellectual_object.institution_id
        @generic_files.push(file)
      end
    end
    respond_to do |format|
      if @intellectual_object.save
        format.json { render json: array_as_json(@generic_files), status: :created }
      else
        errors = @generic_files.map(&:errors)
        format.json { render json: errors, status: :unprocessable_entity }
      end
    end
  end

  def update
    if @generic_file
      authorize @generic_file
      @generic_file.state = 'A'
      if resource.update(single_generic_file_params)
        render json: object_as_json, status: :ok
      else
        log_model_error(resource)
        render json: resource.errors, status: :unprocessable_entity
      end
    else
      authorize current_user, :nil_file?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'This file could not be found. Please check to make sure the identifier was properly escaped.', url: request.original_url }, status: 404 }
        format.html { redirect_to root_url, alert: "A Generic File with identifier: #{params[:generic_file_identifier]} was not found. Please check to make sure the identifier was properly escaped." }
      end
    end
  end

  def destroy
    if @generic_file
      authorize @generic_file, :soft_delete?
      result = WorkItem.can_delete_file?(@generic_file.intellectual_object.identifier, @generic_file.identifier)
      if @generic_file.state == 'D'
        message = 'This file has already been deleted.'
        status = set_status_error(message)
      elsif result == 'true'
        object_or_file_start_destroy('file', @generic_file, current_user)
        message = 'An email has been sent to the administrators of this institution to confirm deletion of this file.'
        status = set_status_ok(message)
      else
        message = "Your file cannot be deleted at this time due to a pending #{result} request."
        status = set_status_error(message)
      end
      respond_to do |format|
        format.json { render json: { status: status[:one], message: message }, status: status[:two] }
        format.html { redirect_to @generic_file }
      end
    else
      authorize current_user, :nil_file?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'This file could not be found. Please check to make sure the identifier was properly escaped.', url: request.original_url }, status: 404 }
        format.html { redirect_to root_url, alert: "A Generic File with identifier: #{params[:generic_file_identifier]} was not found. Please check to make sure the identifier was properly escaped." }
      end
    end
  end

  def confirm_destroy
    authorize @generic_file, :soft_delete?
    if @generic_file.confirmation_token.nil? && (WorkItem.with_action(Pharos::Application::PHAROS_ACTIONS['delete']).with_file_identifier(@generic_file.identifier).count == 1)
      message = 'This deletion request has already been confirmed and queued for deletion by someone else.'
      status = set_status_ok(message)
    else
      if params[:confirmation_token] == @generic_file.confirmation_token.token
        file_confirmed_destroy(params[:requesting_user_id], current_user)
        message = "Delete job has been queued for file: #{@generic_file.uri}."
        status = set_status_ok(message)
      else
        message = 'Your file cannot be deleted at this time due to an invalid confirmation token. Please contact your APTrust administrator for more information.'
        status = set_status_error(message)
      end
    end
    respond_to do |format|
      format.json { render json: { status: status[:one], message: message }, status: status[:two] }
      format.html { redirect_to @generic_file }
    end
  end

  def finished_destroy
    authorize @generic_file
    @generic_file.mark_deleted
    message = "Delete job has been finished for file: #{@generic_file.uri}. File has been marked as deleted."
    status = set_status_ok(message)
    respond_to do |format|
        format.json { render json: { status: status[:one], message: message }, status: status[:two] }
        format.html { redirect_to @generic_file.intellectual_object }
    end
  end

  def restore
    if @generic_file
      authorize @generic_file
      message = ""
      api_status_code = :ok
      restore_item = nil
      pending = WorkItem.pending_action_for_file(@generic_file.identifier)
      if @generic_file.state == 'D'
        api_status_code = :conflict
        message = 'This file has been deleted and cannot be queued for restoration.'
      elsif pending.nil?
        restore_item = WorkItem.create_restore_request_for_file(@generic_file, current_user.email)
        message = 'Your file has been queued for restoration.'
      else
        api_status_code = :conflict
        message = "Your file cannot be queued for restoration at this time due to a pending #{pending.action} request."
      end
      respond_to do |format|
        status = restore_item.nil? ? 'error' : 'ok'
        item_id = restore_item.nil? ? 0 : restore_item.id
        format.json { render :json => { status: status, message: message, work_item_id: item_id }, :status => api_status_code }
        format.html {
          restore_item.nil? ? flash[:alert] = message : flash[:notice] = message
          redirect_to @generic_file
        }
      end
    else
      authorize current_user, :nil_file?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'This file could not be found. Please check to make sure the identifier was properly escaped.', url: request.original_url }, status: 404 }
        format.html { redirect_to root_url, alert: "A Generic File with identifier: #{params[:generic_file_identifier]} was not found. Please check to make sure the identifier was properly escaped." }
      end
    end
  end

  protected

  def single_generic_file_params
    params[:generic_file] &&= params.require(:generic_file)
      .permit(:id, :uri, :identifier, :size, :ingest_state, :last_fixity_check,
              :file_format, :storage_option, premis_events_attributes:
              [:identifier, :event_type, :date_time, :outcome, :id,
               :outcome_detail, :outcome_information, :detail, :object,
               :agent, :intellectual_object_id, :generic_file_id,
               :institution_id],
              checksums_attributes:
              [:datetime, :algorithm, :digest, :generic_file_id])
  end

  def batch_generic_file_params
    params[:generic_files] &&= params.require(:generic_files)
      .permit(files: [:id, :uri, :identifier, :size, :ingest_state, :last_fixity_check,
                      :file_format, :storage_option, premis_events_attributes:
                      [:identifier, :event_type, :date_time, :outcome, :id,
                       :outcome_detail, :outcome_information, :detail, :object,
                       :agent, :intellectual_object_id, :generic_file_id,
                       :institution_id],
                      checksums_attributes:
                      [:datetime, :algorithm, :digest, :generic_file_id]])
  end

  def resource
    @generic_file
  end

  def load_parent_object
    if params[:intellectual_object_identifier]
      @intellectual_object = IntellectualObject.readable(current_user).find_by_identifier(params[:intellectual_object_identifier])
    elsif params[:intellectual_object_id]
      @intellectual_object = IntellectualObject.readable(current_user).find(params[:intellectual_object_id])
    elsif params[:institution_identifier]
      @institution = Institution.where(identifier: params[:institution_identifier]).first
    else
      @intellectual_object = GenericFile.readable(current_user).find(params[:id]).intellectual_object
    end
  end

  def load_intellectual_object
    if params[:intellectual_object_identifier]
      @intellectual_object = IntellectualObject.readable(current_user).find_by_identifier(params[:intellectual_object_identifier])
    elsif params[:intellectual_object_id]
      @intellectual_object = IntellectualObject.readable(current_user).find(params[:intellectual_object_id])
    else
      @intellectual_object = GenericFile.readable(current_user).find(params[:id]).intellectual_object
    end
  end

  def object_as_json
    if params[:with_ingest_state] == 'true' && current_user.admin? && params[:include_relations]
      options_hash = {include: [:checksums, :premis_events, :ingest_state]}
    elsif params[:with_ingest_state] == 'true' && current_user.admin?
      options_hash = {include: [:ingest_state]}
    elsif params[:include_relations]
      options_hash = {include: [:checksums, :premis_events]}
    else
      options_hash = {}
    end
    @generic_file.serializable_hash(options_hash)
  end

  def array_as_json(list_of_generic_files)
    (params[:with_ingest_state] == 'true' && current_user.admin?) ?
        options_hash = {include: [:checksums, :premis_events, :ingest_state]} :
        options_hash = {include: [:checksums, :premis_events]}
    files = list_of_generic_files.map { |gf| gf.serializable_hash(options_hash) }

    # For consistency on the client end, make this list
    # look like every other list the API returns.
    {
      count: files.count,
      next: nil,
      previous: nil,
      results: files,
    }
  end

  def load_generic_file
    if params[:generic_file_identifier]
      identifier = params[:generic_file_identifier]
      @generic_file = GenericFile.where(identifier: identifier).first
      if @generic_file.nil?
          if looks_like_fedora_file(identifier)
            fixed_identifier = fix_fedora_filename(identifier)
            if fixed_identifier != identifier
              logger.info("Rewrote #{identifier} -> #{fixed_identifier}")
              @generic_file = GenericFile.where(identifier: fixed_identifier).first
            end
          else
            @generic_file = GenericFile.find_by_identifier(identifier)
          end
      end
    elsif params[:id]
      @generic_file ||= GenericFile.readable(current_user).find(params[:id])
    end
    unless @generic_file.nil?
      @intellectual_object = @generic_file.intellectual_object
      @institution = @intellectual_object.institution
    end
  end

  # If this looks like a file that Fedora exported,
  # it will need some special handling.
  def looks_like_fedora_file(filename)
    filename.include?('fedora') || filename.include?('datastreamStore')
  end

  # Oh, the horror!
  # https://www.pivotaltracker.com/story/show/140235557
  def fix_fedora_filename(filename)
    match = filename.match(/\/[0-9a-f]{2}\//)
    return filename if match.nil?

    # Split the filename at the dirname after datastreamStore or objectStore.
    # That dirname always consists of two hex letters.
    dirname = match[0]
    parts = filename.split(dirname, 2)

    return filename if parts.count < 2

    # Now URL-encode slashes and colons AFTER the dirname,
    # and use capitals, because Postgres is case-sensitive.
    # Second arg to URI.encode forces it to escape slashes
    # and colons, which the encoder would otherwise let through
    start_of_name = parts[0]
    end_of_name = parts[1]
    encoded_end = URI.encode(end_of_name, "/:")

    # Now rebuild and return the fixed file name.
    return "#{start_of_name}#{dirname}#{encoded_end}"
  end

  def filter_count_and_sort
    @selected = {}
    parameter_deprecation
    @generic_files = file_filter(@generic_files, params)
    get_format_counts(@generic_files)
    get_institution_counts(@generic_files)
    get_state_counts(@generic_files)
    params[:sort] = 'name' if params[:sort].nil?
    case_sort(@generic_files, params, 'file')
    count = @generic_files.count
    set_page_counts(count)
  end

  def parameter_deprecation
    params[:identifier] = params[:identifier_like] if params[:identifier_like]
    params[:uri] = params[:uri_like] if params[:uri_like]
  end

  private

  def set_format
    request.format = 'html' unless request.format == 'json' || request.format == 'html'
  end

end
