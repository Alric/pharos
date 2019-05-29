module RequeueHelper

  def issue_requeue_http_post(stage)
    uri = item_action_case(stage)
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Post.new(uri)
    request.body = @work_item.id.to_s
    http.request(request)
  end

  def item_action_case(stage)
    case @work_item.action
      when Pharos::Application::PHAROS_ACTIONS['delete']
        uri = deletion_uri
      when Pharos::Application::PHAROS_ACTIONS['restore']
        uri = restore_uri
      when Pharos::Application::PHAROS_ACTIONS['ingest']
        uri = ingest_uri(stage)
      when Pharos::Application::PHAROS_ACTIONS['dpn']
        uri = dpn_uri(stage)
      when Pharos::Application::PHAROS_ACTIONS['glacier_restore']
        uri = glacier_restore_uri
    end
    uri
  end

  def deletion_uri
    URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=apt_file_delete_topic")
  end

  def restore_uri
    if @work_item.generic_file_identifier.blank?
      uri = URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=apt_restore_topic")
    else
      gf = GenericFile.find_by_identifier(@work_item.generic_file_identifier)
      (gf && gf.storage_option == 'Standard') ?
          uri = URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=apt_file_restore_topic") :
          uri = URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=apt_glacier_restore_init_topic")
    end
    uri
  end

  def ingest_uri(stage)
    if stage == Pharos::Application::PHAROS_STAGES['fetch']
      uri = URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=apt_fetch_topic")
    elsif stage == Pharos::Application::PHAROS_STAGES['store']
      uri = URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=apt_store_topic")
    elsif stage == Pharos::Application::PHAROS_STAGES['record']
      uri = URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=apt_record_topic")
    end
    uri
  end

  def dpn_uri(stage)
    if stage == Pharos::Application::PHAROS_STAGES['package']
      uri = URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=dpn_package_topic")
    elsif stage == Pharos::Application::PHAROS_STAGES['store']
      uri = URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=dpn_ingest_store_topic")
    elsif stage == Pharos::Application::PHAROS_STAGES['record']
      uri = URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=dpn_record_topic")
    end
    uri
  end

  def glacier_restore_uri
    URI("#{Pharos::Application::NSQ_BASE_URL}/pub?topic=apt_glacier_restore_init_topic")
  end

  def set_options(params)
    options = { }
    options[:stage] = params[:item_stage] if params[:item_stage]
    options[:work_item_state_delete] = 'true' if params[:delete_state_item] && params[:delete_state_item] == 'true'
    options
  end

  def set_requeue_response_dev
    flash[:notice] = 'The response from NSQ to the requeue request is as follows: Status: 200, Body: ok'
    status = { }
    status[:status] = 200
    status[:body] = 'ok'
    status
  end

  def set_requeue_response(response)
    flash[:notice] = "The response from NSQ to the requeue request is as follows: Status: #{response.code}, Body: #{response.body}"
    status = { }
    status[:status] = response.code
    status[:body] = response.body
    status
  end

end
