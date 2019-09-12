module UsersHelper
  include AwsIam

  # Returns the Gravatar (http://gravatar.com/) for the given user.
  def gravatar_for(user, options = { size: 50 })
    gravatar_id = Digest::MD5::hexdigest(user.email.downcase)
    gravatar_url = "https://secure.gravatar.com/avatar/#{gravatar_id}?s=#{options[:size]}"
    image_tag(gravatar_url, alt: user.name, class: "gravatar")
  end

  # Returns a list of roles we have permission to assign
  def roles_for_select
    Role.all.select {|role| policy(role).add_user? }.sort.map {|r| [r.name.titleize, r.id] }
  end

  def institutions_for_select
    Institution.all.order('name').select {|institution| policy(institution).add_user? }
  end

  def generate_key_confirmation_msg(user)
    if user.encrypted_api_secret_key.nil? || user.encrypted_api_secret_key == ''
      ''
    else
      'Are you sure?  Your current API secret key will be destroyed and replaced with the new one.'
    end
  end

  def generate_aws_key_confirmation_msg(user)
    if user.aws_access_key.nil? || user.aws_access_key == ''
      ''
    else
      'Are you sure?  Your current AWS access key will be destroyed and replaced with the new one.'
    end
  end

  def persist_errors(user)
    user.errors.add(:phone_number, @user.errors.messages[:phone_number][0]) if @user && @user.errors.any? && user.id == @user.id
    user
  end

  def setup_aws_client
    creds = Aws::Credentials.new(ENV['AWS_SES_USER'], ENV['AWS_SES_PWD'])
    client = Aws::IAM::Client.new(region: ENV['AWS_DEFAULT_REGION'], credentials: creds, instance_profile_credentials_timeout: 15, instance_profile_credentials_retries: 5)
    client
  end

  def aws_response
    user_name = build_user_name(@user)
    @response = ''
    begin
      client = setup_aws_client
      @response = client.get_user({ user_name: user_name })
    rescue => e
      logger.error "Exception in user#show; User: #{@user.name}."
      logger.error e.message
      logger.error e.backtrace.join("\n")
      if e.message.include?('cannot be found')
        @response = 'You do not have an AWS IAM account. You will not be able to generate credentials until you have one. Please talk to your administrator about setting up an account.'
      else
        @response = "There was an error verifying your AWS account, please check back later. Response was '#{e}'."
      end
    end
  end
end
