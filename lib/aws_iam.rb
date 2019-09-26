module AwsIam
  def setup_aws_client
    creds = Aws::Credentials.new(ENV['AWS_SES_USER'], ENV['AWS_SES_PWD'])
    client = Aws::IAM::Client.new(region: ENV['AWS_DEFAULT_REGION'], credentials: creds, instance_profile_credentials_timeout: 15, instance_profile_credentials_retries: 5)
    client
  end

  def build_user_name(user)
    if Rails.env.production?
      user_name = user.name.split(' ').join('.')
    elsif Rails.env.demo?
      user_name = user.name.split(' ').join('.') + '.test'
    else
      user_name = user.name.split(' ').join('.') + '.' + Rails.env
    end
    user_name
  end

  def build_group_name(user)
    inst_identifier = user.institution.identifier
    if Rails.env.production?
      group_name = "#{inst_identifier}.users"
    elsif Rails.env.demo?
      group_name = "test.#{inst_identifier}.users"
    else
      group_name = "#{Rails.env}.#{inst_identifier}.users"
    end
    group_name
  end

  def get_aws_iam_user(user_name)
    begin
      client = setup_aws_client
      client.get_user({ user_name: user_name })
      @flag = true
    rescue => e
      unless e.message.include?('cannot be found')
        logger.error "Exception in user##{params[:action]}; User: #{user_name}."
        logger.error e.message
        logger.error e.backtrace.join("\n")
        @msg = @msg + " There was an error verifying your AWS account, please check back later. Response was '#{e}'."
      end
    end
  end

  def create_aws_iam_user(user_name, user)
    begin
      client = setup_aws_client
      response = client.create_user({ user_name: user_name })
      @msg = @msg + " AWS IAM username is #{response.user.user_name}."
    rescue => e
      logger.error "Exception in user##{params[:action]}; There was an error creating an IAM account for #{user.name}."
      logger.error e.message
      logger.error e.backtrace.join("\n")
      @msg = @msg + " There was an error creating an IAM account for #{user.name}. Response was: '#{e}'"
    end
  end

  def delete_aws_iam_user(user_name)
    begin
      client = setup_aws_client
      client.delete_user({ user_name: user_name })
      @msg = @msg + " IAM user account #{user_name} was deleted."
    rescue => e
      logger.error "Exception in user##{params[:action]}; There was an error deleting the IAM account #{user_name}."
      logger.error e.message
      logger.error e.backtrace.join("\n")
      @msg = @msg + " There was an error deleting the IAM account #{user_name}. Response was: '#{e}'."
    end
  end

  def add_aws_user_to_group(user_name, group_name)
    begin
      client = setup_aws_client
      client.add_user_to_group({ group_name: group_name, user_name: user_name })
    rescue => e
      logger.error "Exception in users##{params[:action]}; There was an error adding #{user_name} to group #{group_name}."
      logger.error e.message
      logger.error e.backtrace.join("\n")
      @msg = @msg + " There was an error adding #{user_name} to group #{group_name}. Response was: '#{e}'."
    end
  end

  def remove_aws_user_from_group(user_name, group_name)
    begin
      client = setup_aws_client
      client.remove_user_from_group({ group_name: group_name, user_name: user_name })
      @msg = @msg + " Removed #{user_name} from group #{group_name}."
    rescue => e
      logger.error "Exception in users##{params[:action]}; There was an error removing #{user_name} from group #{group_name}."
      logger.error e
      logger.error e.backtrace.join("\n")
      @msg = @msg + " There was an error removing #{user_name} from group #{group_name}. Response was: '#{e}'."
    end
  end

  def get_aws_access_keys(user_name)
    key_response = ''
    begin
      client = setup_aws_client
      key_response = client.list_access_keys({ user_name: user_name })
      @key_flag = true if key_response.access_key_metadata == []
    rescue => e
      unless e.message.include?('cannot be found')
        logger.error "Exception in user##{params[:action]}; AWS couldn't retrieve keys for #{user_name}."
        logger.error e.message
        logger.error e.backtrace.join("\n")
        key_response = 'Error'
        @msg = @msg + " There was an error retrieving keys for #{user_name}. Response was: '#{e}'"
        @key_flag = false
      end
    end
    key_response
  end

  def create_aws_access_keys(user_name, user)
    begin
      client = setup_aws_client
      response_two = client.create_access_key({ user_name: user_name })
      user.aws_access_key = response_two.access_key.access_key_id
      user.save!
      @acc_key_id = response_two.access_key.access_key_id
      @secret_key = response_two.access_key.secret_access_key
      @msg = @msg + ' Your AWS credentials have been successfully created. Please store them somewhere safe.'
    rescue => e
      logger.error "Exception in user##{params[:action]}; There was an error creating AWS credentials for #{user_name}."
      logger.error e.message
      logger.error e.backtrace.join("\n")
      @msg = @msg + " There was an error creating AWS credentials for #{user_name}. Response was: '#{e}'."
    end
  end

  def delete_aws_access_keys(user_name, keys, user)
    begin
      client = setup_aws_client
      keys.access_key_metadata.each do |key|
        client.delete_access_key({ access_key_id: key.access_key_id, user_name: user_name })
      end
      user.aws_access_key = ''
      user.save!
      @msg = @msg + " AWS credentials for #{user_name} were deleted."
    rescue => e
      logger.error "Exception in user##{params[:action]}; There was an error deleting AWS credentials for #{user_name}."
      logger.error e.message
      logger.error e.backtrace.join("\n")
      @msg = @msg + " There was an error deleting AWS credentials for #{user_name}. Response was: '#{e}'."
      @key_flag = false
    end
  end
end