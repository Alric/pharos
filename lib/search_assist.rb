module SearchAssist

  def object_filter(results, params)
    params[:state] = 'A' if params[:state].nil?
    results = results
                  .with_institution(params[:institution])
                  .with_description_like(params[:description])
                  .with_identifier_like(params[:identifier])
                  .with_bag_group_identifier_like(params[:bag_group_identifier])
                  .with_alt_identifier_like(params[:alt_identifier])
                  .with_bag_name_like(params[:bag_name])
                  .with_etag_like(params[:etag])
                  .created_before(params[:created_before])
                  .created_after(params[:created_after])
                  .updated_before(params[:updated_before])
                  .updated_after(params[:updated_after])
                  .with_access(params[:access])
                  .with_file_format(params[:file_format])
                  .with_state(params[:state])
    results
  end

  def file_filter(results, params)
    params[:state] = 'A' if params[:state].nil?
    results = results
                  .with_identifier_like(params[:identifier])
                  .with_uri_like(params[:uri])
                  .created_before(params[:created_before])
                  .created_after(params[:created_after])
                  .updated_before(params[:updated_before])
                  .updated_after(params[:updated_after])
                  .with_institution(params[:institution])
                  .with_file_format(params[:file_format])
                  .with_state(params[:state])
                  .with_access(params[:access])
    results
  end

  def item_filter(results, params)
    bag_date1 = DateTime.parse(params[:bag_date]) if params[:bag_date]
    bag_date2 = DateTime.parse(params[:bag_date]) + 1.seconds if params[:bag_date]
    date = format_date if params[:updated_since].present?
    results = results
                  .created_before(params[:created_before])
                  .created_after(params[:created_after])
                  .updated_before(params[:updated_before])
                  .updated_after(params[:updated_after])
                  .updated_after(date)
                  .with_bag_date(bag_date1, bag_date2)
                  .with_name_like(params[:name])
                  .with_etag(params[:etag])
                  .with_object_identifier_like(params[:object_identifier])
                  .with_file_identifier_like(params[:file_identifier])
                  .with_status(params[:status])
                  .with_stage(params[:stage])
                  .with_action(params[:item_action])
                  .queued(params[:queued])
                  .with_node(params[:node])
                  .with_pid(params[:pid])
                  .with_unempty_node(params[:node_not_empty])
                  .with_empty_node(params[:node_empty])
                  .with_unempty_pid(params[:pid_not_empty])
                  .with_empty_pid(params[:pid_empty])
                  .with_retry(params[:retry])
                  .with_access(params[:access])
                  .with_institution(params[:institution])
    results
  end

  def events_filter(results, params)
    results = results
                  .with_institution(params[:institution])
                  .with_type(params[:event_type])
                  .with_outcome(params[:outcome])
                  .with_create_date(params[:created_at])
                  .created_before(params[:created_before])
                  .created_after(params[:created_after])
                  .with_event_identifier(params[:event_identifier])
                  .with_access(params[:access])
    if @parent && @parent.is_a?(Institution)
      results = results
                           .with_object_identifier_like(params[:object_identifier])
                           .with_file_identifier_like(params[:file_identifier])
    end
    results
  end

  def dpn_bag_filter(results, params)
    results = results
                  .with_object_identifier(params[:object_identifier])
                  .with_dpn_identifier(params[:dpn_identifier])
                  .created_before(params[:created_before])
                  .created_after(params[:created_after])
                  .updated_before(params[:updated_before])
                  .updated_after(params[:updated_after])
    results
  end

  def dpn_item_filter(results, params)
    params[:status] = nil if params[:status] == 'Null Status'
    params[:stage] = nil if params[:stage] == 'Null Stage'
    results = results
                  .with_task(params[:task])
                  .with_identifier(params[:identifier])
                  .with_state(params[:state])
                  .with_stage(params[:stage])
                  .with_status(params[:status])
                  .with_retry(params[:retry])
                  .with_pid(params[:pid])
                  .queued_before(params[:queued_before])
                  .queued_after(params[:queued_after])
                  .completed_before(params[:completed_before])
                  .completed_after(params[:completed_after])
                  .is_completed(params[:is_completed])
                  .is_not_completed(params[:is_not_completed])
                  .with_remote_node(params[:remote_node])
                  .queued(params[:queued])
    results
  end

  def bulk_job_filter(results, params)
    results = results
                  .with_institution(params[:institution])
    results
  end

  def checksums_filter(results, params)
    results = results
                  .with_generic_file_identifier(params[:generic_file_identifier])
                  .with_algorithm(params[:algorithm])
                  .with_digest(params[:digest])
    results
  end

  def case_sort(results, params, type)
    case params[:sort]
      when 'date'
         sort_by_date(results, type)
      when 'name'
         sort_by_name(results, type)
      when 'institution'
         sort_by_institution(results)
    end
  end

  def sort_by_date(results, type)
    unless results.nil?
      case type
        when 'event'
          results = results.order('premis_events.date_time DESC')
        when 'item'
          results = results.order('work_items.date DESC')
        when 'dpn_item'
          results = results.order('dpn_work_items.queued_at DESC')
        when 'object'
          results = results.order('intellectual_objects.updated_at DESC')
        when 'file'
          results = results.order('generic_files.updated_at DESC')
        when 'bulk_job'
          results = results.order('bulk_delete_jobs.updated_at DESC')
        else

      end
    end
    results
  end

  def sort_by_name(results, type)
    unless results.nil?
      case type
        when 'object'
          results = results.order('title')
        when 'item'
          results = results.order('name')
        when 'event'
          results = results.order('identifier').reverse_order
        when 'bulk_job'
          results = results.order('id').reverse_order
        else
          results = results.order('identifier')
      end
    end
    results
  end

  def sort_by_institution(results)
    results.joins(:institution).order('institutions.name') unless results.nil?
  end

end