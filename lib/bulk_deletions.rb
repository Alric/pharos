module BulkDeletions

  def inst_trigger_bulk_delete(current_user)
    create_bulk_delete_job(current_user)
    build_bulk_deletion_list
    csv = @institution.generate_confirmation_csv(@bulk_job)
    log = Email.log_deletion_request(@institution)
    token = create_confirmation_token('institution')
    NotificationMailer.bulk_deletion_inst_admin_approval(@institution, @bulk_job, @forbidden_idents, log, token, csv).deliver!
  end

  def partial_conf_bulk_delete(current_user)
    edit_bulk_delete_job('partial', current_user)
    csv = @institution.generate_confirmation_csv(@bulk_job)
    log = Email.log_bulk_deletion_confirmation(@institution, 'partial')
    token = create_confirmation_token('institution')
    NotificationMailer.bulk_deletion_apt_admin_approval(@institution, @bulk_job, log, token, csv).deliver!
  end

  def confirmed_destroy(current_user)
    edit_bulk_delete_job('final', current_user)
    requesting_user = User.readable(current_user).where(email: @bulk_job.requested_by).first
    attributes = { requestor: requesting_user.email, inst_app: @bulk_job.institutional_approver, apt_app: @bulk_job.aptrust_approver }
    @t = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ConfirmationToken.where(institution_id: @institution.id).delete_all
        soft_delete_objects(attributes)
        soft_delete_files(attributes)
        log = Email.log_bulk_deletion_confirmation(@institution, 'final')
        csv = @institution.generate_confirmation_csv(@bulk_job)
        NotificationMailer.bulk_deletion_queued(@institution, @bulk_job, log, csv).deliver!
      end
      ActiveRecord::Base.connection_pool.release_connection
    end
  end

  def finish_bulk_deletions
    bulk_mark_deleted
    log = Email.log_deletion_finished(@institution)
    csv = @institution.generate_confirmation_csv(@bulk_job)
    NotificationMailer.bulk_deletion_finished(@institution, @bulk_job, log, csv).deliver!
  end

  def object_or_file_start_destroy(type, subject, current_user)
    log = Email.log_deletion_request(subject)
    token = create_confirmation_token(type)
    NotificationMailer.deletion_request(subject, current_user, log, token).deliver!
  end

  def object_confirmed_destroy(user_id, current_user)
    requesting_user = User.find(user_id)
    @t = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { object_or_file_confirm_destroy(@intellectual_object, requesting_user, current_user) }
      ActiveRecord::Base.connection_pool.release_connection
    end
  end

  def file_confirmed_destroy(user_id, current_user)
    requesting_user = User.find(user_id)
    object_or_file_confirm_destroy(@generic_file, requesting_user, current_user)
  end

  def object_or_file_confirm_destroy(subject, requesting_user, current_user)
    attributes = { requestor: requesting_user.email, inst_app: current_user.email }
    subject.soft_delete(attributes)
    log = Email.log_deletion_confirmation(subject)
    NotificationMailer.deletion_confirmation(subject, requesting_user.id, current_user.id, log).deliver!
    subject.is_a?(IntellectualObject) ?
        ConfirmationToken.where(intellectual_object_id: subject.id).delete_all :
        ConfirmationToken.where(generic_file_id: subject.id).delete_all
  end

  def object_finish_destroy
    deletion_item = WorkItem.with_object_identifier(@intellectual_object.identifier).with_action(Pharos::Application::PHAROS_ACTIONS['delete']).first
    (deletion_item.aptrust_approver.nil? || deletion_item.aptrust_approver == '') ?
        outcome_information = "Object deleted at the request of #{deletion_item.user}. Institutional Approver: #{deletion_item.inst_approver}." :
        outcome_information = "Object deleted as part of bulk deletion at the request of #{deletion_item.user}. Institutional Approver: #{deletion_item.inst_approver}. APTrust Approver: #{deletion_item.aptrust_approver}"
    mark_object_deleted(@intellectual_object, outcome_information, deletion_item.user)
  end

  def soft_delete_objects(attributes)
    @bulk_job.intellectual_objects.each do |obj|
      begin
        obj.soft_delete(attributes)
      rescue => e
        logger.error "Exception in Bulk Delete. Object Identifier: #{obj.identifier}"
        logger.error e.message
        logger.error e.backtrace.join("\n")
      end
    end
  end

  def soft_delete_files(attributes)
    @bulk_job.generic_files.each do |file|
      begin
        file.soft_delete(attributes)
      rescue => e
        logger.error "Exception in Bulk Delete. File Identifier: #{file.identifier}"
        logger.error e.message
        logger.error e.backtrace.join("\n")
      end
    end
  end

  def create_bulk_delete_job(current_user)
    @bulk_job = BulkDeleteJob.create(requested_by: current_user.email, institution_id: @institution.id)
    @bulk_job.save!
  end

  def edit_bulk_delete_job(type, current_user)
    case type
      when 'partial'
        @bulk_job.institutional_approver = current_user.email
        @bulk_job.institutional_approval_at = Time.now.utc
      when 'final'
        @bulk_job.aptrust_approver = current_user.email
        @bulk_job.aptrust_approval_at = Time.now.utc
    end
    @bulk_job.save!
  end

  def create_confirmation_token(type)
    case type
      when 'institution'
        ConfirmationToken.where(institution_id: @institution.id).delete_all
        token = ConfirmationToken.create(institution: @institution, token: SecureRandom.hex)
      when 'object'
        ConfirmationToken.where(intellectual_object_id: @intellectual_object.id).delete_all
        token = ConfirmationToken.create(intellectual_object: @intellectual_object, token: SecureRandom.hex)
      when 'file'
        ConfirmationToken.where(generic_file_id: @generic_file.id).delete_all
        token = ConfirmationToken.create(generic_file: @generic_file, token: SecureRandom.hex)
    end
    token.save!
    token
  end

  def build_bulk_deletion_list
    @forbidden_idents = { }
    initial_identifiers = @ident_list
    initial_identifiers.each do |identifier|
      current = IntellectualObject.find_by_identifier(identifier)
      current = GenericFile.find_by_identifier(identifier) if current.nil?
      pending = WorkItem.pending_action(identifier)
      if current.state == 'D'
        @forbidden_idents[identifier] = 'This item has already been deleted.'
      elsif !pending.nil?
        @forbidden_idents[identifier] = "Your item cannot be deleted at this time due to a pending #{pending.action} request. You may delete this object after the #{pending.action} request has completed."
      else
        current.is_a?(IntellectualObject) ? @bulk_job.intellectual_objects.push(current) : @bulk_job.generic_files.push(current)
      end
    end
  end

  def bulk_mark_deleted
    outcome_information = "Object deleted as part of bulk deletion at the request of #{@bulk_job.requested_by}. Institutional Approver: #{@bulk_job.institutional_approver}. APTrust Approver: #{@bulk_job.aptrust_approver}"
    @bulk_job.intellectual_objects.each do |obj|
      if WorkItem.deletion_finished?(obj.identifier)
        mark_object_deleted(obj, outcome_information, @bulk_job.requested_by)
      end
    end
    @bulk_job.generic_files.each do |file|
      mark_file_deleted(file)
    end
  end

  def mark_object_deleted(obj, outcome_information, user)
    attributes = object_attributes(outcome_information, user)
    obj.mark_deleted(attributes)
  end

  def object_attributes(outcome_information, user)
    attributes = { event_type: Pharos::Application::PHAROS_EVENT_TYPES['delete'],
                   date_time: "#{Time.now}",
                   detail: 'Object deleted from S3 storage',
                   outcome: 'Success',
                   outcome_detail: user,
                   object: 'AWS Go SDK S3 Library',
                   agent: 'https://github.com/aws/aws-sdk-go',
                   identifier: SecureRandom.uuid,
                   outcome_information: outcome_information

    }
    attributes
  end

  def mark_file_deleted(file)
    if WorkItem.deletion_finished_for_file?(file.identifier)
      file.state = 'D'
      file.save!
    end
  end

  def set_status_ok(message)
    status = {}
    flash[:notice] = message
    status[:one] = 'ok'
    status[:two] = :ok
    status
  end

  def set_status_error(message)
    status = {}
    flash[:alert] = message
    status[:one] = 'error'
    status[:two] = :conflict
    status
  end

  def email_log_deletions(email, institution)
    email_log = Email.log_daily_deletion_notification(institution)
    email_log.user_list = email.to
    email_log.email_text = email.body.encoded
    email_log.save!
  end

end