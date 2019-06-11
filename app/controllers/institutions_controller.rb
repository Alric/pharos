class InstitutionsController < ApplicationController
  include BulkDeletions
  require 'google_drive'
  inherit_resources
  skip_before_action :verify_authenticity_token, only: [:trigger_bulk_delete]
  before_action :authenticate_user!
  before_action :load_institution, only: [:edit, :update, :show, :destroy, :single_snapshot, :deactivate, :reactivate,
                                          :trigger_bulk_delete, :partial_confirmation_bulk_delete, :final_confirmation_bulk_delete,
                                          :finished_bulk_delete]
  respond_to :json, :html
  after_action :verify_authorized, except: :index
  after_action :verify_policy_scoped, only: :index

  def index
    @institutions = policy_scope(Institution)
    @institutions = @institutions.order('name')
    @sizes = Institution.find_all_sizes unless request.url.include?("/api/")
    @count = @institutions.count
    page_results(@institutions)
    respond_to do |format|
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
      @associations = @institution.set_associations_for_show(current_user)
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

  def deactivate
    authorize @institution
    @institution.deactivate
    flash[:notice] = "All users at #{@institution.name} have been deactivated."
    respond_to do |format|
      format.html { render 'show' }
    end
  end

  def reactivate
    authorize @institution
    @institution.reactivate
    flash[:notice] = "All users at #{@institution.name} have been reactivated."
    respond_to do |format|
      format.html { render 'show' }
    end
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
    @wb_hash = {}
    @date_str = Time.now.utc.strftime('%m/%d/%Y')
    @wb_hash['Repository Total'] = Institution.total_file_size_across_repo
    MemberInstitution.all.order('name').each do |institution|
      current_snaps = institution.snapshot
      @snapshots.push(current_snaps)
      current_snaps.each do |snap|
        if snap.snapshot_type == 'Individual'
          current_inst = Institution.find(snap.institution_id)
          @wb_hash[current_inst.name] = [snap.cs_bytes, snap.go_bytes]
        end
      end
    end
    NotificationMailer.snapshot_notification(@wb_hash).deliver!
    write_snapshots_to_spreadsheet if Rails.env.production?
    respond_to do |format|
      format.json { render json: { snapshots: @snapshots.each { |snap_set| snap_set.map { |item| item.serializable_hash } } } }
      format.html {
        redirect_to root_path
        flash[:notice] = "A snapshot of all Member Institutions has been taken and archived on #{@snapshots.first.first.audit_date}. Please see the reports page for that analysis."
      }
    end
  end

  def trigger_bulk_delete
    authorize @institution, :bulk_delete?
    parse_ident_list
    inst_trigger_bulk_delete(current_user)
    message = 'An email has been sent to the administrators of this institution to confirm this bulk deletion request.'
    status = set_status_ok(message)
    respond_to do |format|
      format.json { render json: { status: status[:one], message: message }, status: status[:two] }
      format.html { redirect_to root_path }
    end
  end

  def partial_confirmation_bulk_delete
    authorize @institution
    @bulk_job = BulkDeleteJob.find(params[:bulk_delete_job_id])
    if !@institution.confirmation_token.nil? && params[:confirmation_token] == @institution.confirmation_token.token
      if @bulk_job.institutional_approver.nil?
        partial_conf_bulk_delete(current_user)
        message = "Bulk delete job for: #{@institution.name} has been sent forward for final approval by an APTrust administrator."
        status = set_status_ok(message)
      else
        message = 'This bulk deletion request has already been confirmed and sent forward for APTrust approval by someone else.'
        status = set_status_ok(message)
      end
    else
      message = 'Your bulk deletion event cannot be queued at this time due to an invalid confirmation token. Please contact your APTrust administrator for more information.'
      status = set_status_error(message)
    end
    respond_to do |format|
      format.json { render json: { status: status[:one], message: message }, status: status[:two] }
      format.html { redirect_to institution_url(@institution) }
    end
  end

  def final_confirmation_bulk_delete
    authorize @institution
    @bulk_job = BulkDeleteJob.find(params[:bulk_delete_job_id])
    if @institution.confirmation_token.nil? && !@bulk_job.aptrust_approver.nil?
      message = 'This bulk deletion request has already been confirmed and queued for deletion by someone else.'
      status = set_status_ok(message)
    else
      if params[:confirmation_token] == @institution.confirmation_token.token
        confirmed_destroy(current_user)
        message = "Bulk deletion request for #{@institution.name} has been queued."
        status = set_status_ok(message)
      else
        message = 'This bulk deletion request cannot be completed at this time due to an invalid confirmation token. Please contact your APTrust administrator for more information.'
        status = set_status_error(message)
      end
    end
    respond_to do |format|
      format.json { render json: { status: status[:one], message: message }, :status => status[:two] }
      format.html { redirect_to root_path }
    end
  end

  def finished_bulk_delete
    authorize @institution
    @bulk_job = BulkDeleteJob.find(params[:bulk_delete_job_id])
    finish_bulk_deletions
    message = "Bulk deletion job for #{@institution.name} has been completed."
    status = set_status_ok(message)
    respond_to do |format|
      format.json { render json: { status: status[:one], message: message }, :status => status[:two] }
      format.html { redirect_to root_path }
    end
  end

  def deletion_notifications
    authorize current_user, :deletion_notifications?
    Institution.all.each do |current_inst|
      items = current_inst.new_deletion_items
      unless items.nil? || items.count == 0
        zip = current_inst.generate_deletion_zipped_csv(items)
        email = NotificationMailer.deletion_notification(current_inst, zip).deliver_now
        email_log_deletions(email, current_inst)
      end
    end
    respond_to do |format|
      format.json { head :no_content }
      format.html { redirect_to root_path }
    end
  end

  private

  def load_institution
    @institution = params[:institution_identifier].nil? ? current_user.institution : Institution.where(identifier: params[:institution_identifier]).first
  end

  # Never trust parameters from the scary internet, only allow the white list through.
  def build_resource_params
    params[:action] == 'new' ? [] : [params.require(:institution).permit(:name, :identifier, :dpn_uuid, :type, :member_institution_id)]
  end

  def set_attachment_name(name)
    escaped = URI.encode(name)
    response.headers['Content-Disposition'] = "attachment; filename*=UTF-8''#{escaped}"
  end

  def parse_ident_list
    begin
      list = JSON.parse(request.body.read)
    rescue JSON::ParserError, Exception => e
      respond_to do |format|
        format.json { render json: {error: "JSON parse error: #{e.message}"}, status: 400 } and return
      end
    end
    if list
      @ident_list = list['ident_list']
    end
  end

  def write_snapshots_to_spreadsheet
    session = GoogleDrive::Session.from_config('config.json')
    sheet = session.spreadsheet_by_key('1E29ttbnuRDyvWfYAh6_-Zn9s0ChOspUKCOOoeez1fZE').worksheets[0] # Chip Sheet
    # sheet = session.spreadsheet_by_key('1T_zlgluaGdEU_3Fm06h0ws_U4mONpDL4JLNP_z-CU20').worksheets[0] # Kelly Test Sheet
    date_column = 0
    counter = 2
    while date_column == 0
      cell = sheet[3, counter]
      date_column = counter if cell.nil? || cell.empty? || cell == ''
      counter += 1
    end
    i = 1
    unless date_column == 0
      sheet[3, date_column] = @date_str
      while i < 2000
        cell = sheet[i, 1]
        unless cell.nil?
          if @wb_hash.has_key?(cell)
            cs_gb = (@wb_hash[cell][0].to_f / 1073741824).round(2)
            go_gb = (@wb_hash[cell][1].to_f / 1073741824).round(2)
            column = to_s26(date_column)
            previous_column = to_s26(date_column - 1)
            sheet[(i+1), date_column] = cs_gb
            sheet[(i+2), date_column] = "=#{column}#{i+1}/1024"
            sheet[(i+3), date_column] = "=#{column}#{i+2}-#{previous_column}#{i+2}"
            sheet[(i+4), date_column] = "=#{column}#{i+2}-10"
            sheet[(i+5), date_column] = go_gb
            sheet[(i+6), date_column] = "=#{column}#{i+5}/1024"
            sheet[(i+7), date_column] = "=#{column}#{i+6}-#{previous_column}#{i+6}"
            sheet[(i+8), date_column] = "=((#{column}#{i+4}*#{column}$195)+((#{column}#{i+4}*#{column}$195)<0)*abs((#{column}#{i+4}*#{column}$195)))+(#{column}#{i+6}*#{column}$196)"
          end
        end
        i += 1
      end
    end
    sheet.save
  end

  Alpha26 = ("a".."z").to_a

  def to_s26(number)
    return "" if number < 1
    s, q = "", number
    loop do
      q, r = (q - 1).divmod(26)
      s.prepend(Alpha26[r])
      break if q.zero?
    end
    s
  end

end
