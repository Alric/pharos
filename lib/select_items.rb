module SelectItems
  def select_items(type, request)
    restore = Pharos::Application::PHAROS_ACTIONS['restore']
    dpn = Pharos::Application::PHAROS_ACTIONS['dpn']
    delete = Pharos::Application::PHAROS_ACTIONS['delete']
    case type
      when 'restore'
        @items = @items.with_action(restore)
        restore_or_dpn_final_step(request)
      when 'dpn'
        @items = @items.with_action(dpn)
        restore_or_dpn_final_step(request)
      when 'delete'
        @items = @items.with_action(delete)
        delete_final_step(request)
    end
  end

  def restore_or_dpn_final_step(request)
    requested = Pharos::Application::PHAROS_STAGES['requested']
    pending = Pharos::Application::PHAROS_STATUSES['pend']
    !request[:object_identifier].blank? ?
        @items = @items.with_object_identifier(request[:object_identifier]) :
        @items = @items.where(stage: requested, status: pending, retry: true)
  end

  def delete_final_step(request)
    requested = Pharos::Application::PHAROS_STAGES['requested']
    pending = Pharos::Application::PHAROS_STATUSES['pend']
    failed = Pharos::Application::PHAROS_STATUSES['fail']
    !request[:generic_file_identifier].blank? ?
        @items = @items.with_file_identifier(request[:generic_file_identifier]) :
        @items = @items.where(stage: requested, status: [pending, failed], retry: true)
  end

end