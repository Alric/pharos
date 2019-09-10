class UsersController < ApplicationController
  require 'authy'
  inherit_resources
  before_action :authenticate_user!
  before_action :set_user, only: [:show, :edit, :update, :destroy, :generate_api_key, :admin_password_reset, :deactivate, :reactivate,
                                  :vacuum, :enable_otp, :disable_otp, :register_authy_user, :verify_twofa, :generate_backup_codes,
                                  :verify_email, :email_confirmation, :forced_password_update, :indiv_confirmation_email, :confirm_account,
                                  :change_authy_phone_number, :issue_aws_credentials, :revoke_aws_credentials, :update_phone_number,
                                  :create_iam_user]
  after_action :verify_authorized, :except => :index
  after_action :verify_policy_scoped, :only => :index

  def index
    @users = policy_scope(User)
  end

  def new
    @user = User.new
    authorize @user
  end

  def create
    @user = build_resource
    authorize @user
    create!
    if @user.save
      session[:user_id] = @user.id
      password = "ABCabc-#{SecureRandom.hex(4)}"
      @user.password = password
      @user.password_confirmation = password
      @user.save!
      unless Rails.env.test?
        if Rails.env.production?
          user_name = @user.name.split(' ').join('.')
        elsif Rails.env.demo?
          user_name = @user.name.split(' ').join('.') + '.test'
        else
          user_name = @user.name.split(' ').join('.') + '.' + Rails.env
        end
        msg = ''
        begin
          client = setup_aws_client
          @response = client.create_user({ user_name: user_name })
          msg =  "AWS IAM username is #{@response.user.user_name}."
        rescue => e
          logger.error "Exception in user#create; Pharos and/or AWS was unsuccessful in creating an IAM account for #{@user.name}."
          logger.error e.message
          logger.error e.backtrace.join("\n")
          msg =  "Pharos and/or AWS was unsuccessful in creating an IAM account for #{@user.name}. Response was: #{e}."
        end
      end
      NotificationMailer.welcome_email(@user, password).deliver!
    end
    flash[:notice] = "User was successfully created. #{msg}"
  end

  def show
    authorize @user
    unless Rails.env.test?
      if Rails.env.production?
        user_name = @user.name.split(' ').join('.')
      elsif Rails.env.demo?
        user_name = @user.name.split(' ').join('.') + '.test'
      else
        user_name = @user.name.split(' ').join('.') + '.' + Rails.env
      end
      @response = 'You do not have an AWS IAM account. You will not be able to generate credentials until you have one. Please talk to your administrator about setting up an account.'
      begin
        client = setup_aws_client
        @response = client.get_user({ user_name: user_name })
      rescue => e
        logger.error "Exception in user#show; User: #{@user.name} does not have an AWS IAM account."
        logger.error e.message
        logger.error e.backtrace.join("\n")
        if e.include?('not found')
          @response = 'You do not have an AWS IAM account. You will not be able to generate credentials until you have an IAM. Please talk to your administrator about setting up an account.'
        else
          @response = "There was an error verifying your AWS account, please check back later. Response was #{e}"
        end
      end
    end
    show!
  end

  def edit
    authorize @user
    edit!
  end

  def update
    authorize @user
    old_num = @user.phone_number
    update!
    if @user.authy_id.present? && !(@user.phone_number == old_num)
      response = Authy::API.delete_user(id: @user.authy_id)
      if response.ok?
        @user.update(authy_id: nil)
        second_response = generate_authy_account(@user)
        if second_response.ok? && (second_response['errors'].nil? || second_response['errors'].empty?)
          message = ' The phone number for both this Pharos account and Authy account has been successfully updated.'
          flash[:notice] ? flash[:notice] += message : flash[:notice] = message
        else
          logger.info "Re-Generate Authy Account Errors: #{second_response.errors.inspect}"
          message = 'The phone number associated with this Authy account was unable to be updated at this time. Authy push notifications will not be able to be used until it has been properly updated.'
          flash[:error] ? flash[:error] += message : flash[:error] = message
        end
      else
        logger.info "Delete Authy Account Errors: #{response.errors.inspect}"
        message = 'The phone number associated with this Authy account was unable to be updated at this time. Authy push notifications will not be able to be used until it has been properly updated.'
        flash[:error] ? flash[:error] += message : flash[:error] = message
      end
    end
  end

  def destroy
    authorize @user
    unless Rails.env.test?
      if Rails.env.production?
        user_name = @user.name.split(' ').join('.')
      elsif Rails.env.demo?
        user_name = @user.name.split(' ').join('.') + '.test'
      else
        user_name = @user.name.split(' ').join('.') + '.' + Rails.env
      end
      begin
        client = setup_aws_client
        @response = client.delete_user({ user_name: user_name })
        msg = "IAM account #{@response.user.user_name} was deleted."
      rescue => e
        logger.error "Exception in user#destroy; Pharos and/or AWS was unsuccessful in deleting the IAM account for #{@user.name}."
        logger.error e.message
        logger.error e.backtrace.join("\n")
        msg = "Pharos and/or AWS was unsuccessful in deleting the IAM account for this user. Response was: #{e}."
      end
    end
    destroy!(notice: "User #{@user.to_s} was deleted. #{msg}")
  end

  def edit_password
    @user = current_user
    authorize @user
  end

  def update_password
    @user = User.find(current_user.id)
    authorize @user
    if @user.update_with_password(user_params)
      update_password_attributes(@user)
      bypass_sign_in(@user)
      redirect_to @user
      flash[:notice] = 'Successfully changed password.'
    else
      render :edit_password
    end
  end

  def forced_password_update
    authorize @user
    @user.force_password_update = true
    @user.save!
    msg = "#{@user.name} will be forced to change their password upon next login."
    respond_to do |format|
      format.json { render json: { message: msg }, status: :ok }
      format.html { redirect_to @user, flash: { notice: msg } }
    end
  end

  def enable_otp
    authorize @user
    flash.clear
    params[:phone_number] = @user.phone_number if params[:phone_number].nil?
    if params[:phone_number].blank?
      msg = 'You must have a phone number listed in order to enable Two Factor Authentication.'
      flash[:error] = msg
      @user.errors.add(:phone_number, 'must not be blank')
    elsif Phonelib.invalid?(params[:phone_number])
      msg = "The phone number #{params[:phone_number]} is invalid. Please try again."
      flash[:error] = msg
      @user.errors.add(:phone_number, 'is invalid')
    else
      @user.phone_number = params[:phone_number]
      @user.save!
      unless Rails.env.test?
        authy = generate_authy_account(@user) if (@user.authy_id.blank?)
      end
      if authy && !authy['errors'].nil? && !authy['errors'].empty?
        logger.info "Testing Authy Errors hash: #{authy.errors.inspect}"
        msg = 'An error occurred while trying to enable Two Factor Authentication.'
        flash[:error] = msg
      else
        @codes = update_enable_otp_attributes(@user)
        (current_user == @user) ? usr = ' for your account' : usr = " for #{@user.name}"
        msg = "Two Factor Authentication has been enabled#{usr}. Authy ID is #{@user.authy_id}."
        flash[:notice] = msg
      end
    end
    respond_to do |format|
      @codes ? format.json { render json: {user: @user, codes: @codes, message: msg} } : format.json { render json: {user: @user, message: msg} }
      format.html {
        if params[:redirect_loc] && params[:redirect_loc] == 'index'
          @users = policy_scope(User)
          if msg.include?('Authy ID is')
            redirect_to users_path
          else
            render 'index'
          end
        else
          render 'show'
        end
      }
    end
  end

  def disable_otp
    authorize @user
    if current_user_is_an_admin
      if current_user == @user || user_is_an_admin(@user)
        (current_user == @user) ? msg_opt = 'you based on your role as an administrator' : msg_opt = "#{@user.name} based on their role as an administrator"
        msg = "Two Factor Authentication cannot be disabled at this time because it is required for #{msg_opt}."
        flash[:alert] = msg
      elsif user_inst_requires_twofa(@user)
        msg = 'Two Factor Authentication cannot be disabled at this time because it is required for all users at this institution.'
        flash[:alert] = msg
      else
        disable_twofa(@user)
        msg = "Two Factor Authentication has been disabled for #{@user.name}."
        flash[:notice] = msg
      end
    else
      if user_inst_requires_twofa(@user)
        msg = 'Two Factor Authentication cannot be disabled at this time because it is required for all users at your institution.'
        flash[:alert] = msg
      else
        disable_twofa(@user)
        msg = 'Two Factor Authentication has been disabled.'
        flash[:notice] = msg
      end
    end
    respond_to do |format|
      format.json { render json: { user: @user, message: msg } }
      format.html { (params[:redirect_loc] && params[:redirect_loc] == 'index') ? (redirect_to users_path) : (render 'show') }
    end
  end

  def register_authy_user
    authorize @user
    if @user.authy_id.blank?
      authy = generate_authy_account(@user)
    end
    if authy && !authy['errors'].nil? && !authy['errors'].empty?
      logger.info "Register Authy Errors Hash: #{authy.errors.inspect}"
      message = 'An error occurred while trying to register for Authy.'
      flash[:error] = message
    else
      message = "Registered for Authy. Authy ID is #{@user.authy_id}."
      flash[:notice] = message
    end
    respond_to do |format|
      format.json { render json: { user: @user, message: message } }
      format.html { redirect_to @user }
    end
  end

  def change_authy_phone_number
    authorize @user
    flash.clear
    if params[:phone_number].blank?
      msg = 'You must have a phone number listed in order to change your number with Authy.'
      flash[:error] = msg
      @user.errors.add(:phone_number, 'must not be blank')
    elsif Phonelib.invalid?(params[:phone_number])
      msg = "The phone number #{params[:phone_number]} is invalid. Please try again."
      flash[:error] = msg
      @user.errors.add(:phone_number, 'is invalid')
    else
      @user.phone_number = params[:phone_number]
      @user.save
      response = Authy::API.delete_user(id: @user.authy_id)
      if response.ok?
        @user.update(authy_id: nil)
        second_response = generate_authy_account(@user)
        if !second_response['errors'].nil? && !second_response['errors'].empty?
          logger.info "Re-Generate Authy Account Errors: #{second_response.errors.inspect}"
          message = 'The Authy account was unable to be updated at this time, you will not be able to use Authy push notifications until it has been properly updated. If you now see a "Register with Authy" button, please try using that.'
          flash[:error] = message
        elsif second_response.ok?
          message = 'The phone number for both this Pharos account and Authy account has been successfully updated.'
          flash[:notice] = message
        end
      else
        logger.info "Delete Authy Account Errors: #{response.errors.inspect}"
        message = 'The Authy account was unable to be updated at this time, you will not be able to use Authy push notifications until it has been properly updated. Please try again later.'
        flash[:error] = message
      end
    end
    respond_to do |format|
      format.json { render json: { user: @user, message: message } }
      format.html { render 'show' }
    end
  end

  def generate_backup_codes
    authorize @user
    @codes = @user.generate_otp_backup_codes!
    @user.save!
    respond_to do |format|
      format.json { render json: { user: @user, codes: @codes } }
      format.html { render 'show' }
    end
  end

  def verify_twofa
    authorize @user
    if params[:verification_option] == 'push'
      one_touch = generate_one_touch('Request to Verify Phone Number for APTrust Repository Website')
      if !one_touch['errors'].nil? && !one_touch['errors'].empty?
        logger.info "Checking one touch contents: #{one_touch.inspect}"
        respond_to do |format|
          format.json { render json: { error: 'Create Push Error', message: one_touch.inspect }, status: :internal_server_error }
          format.html { redirect_to @user, flash: { error: "There was an error creating your push notification. Please contact your administrator or an APTrust administrator for help, and let them know that the error was: #{one_touch['errors']['message']}" } }
        end
      elsif one_touch.ok?
        check_one_touch_verify(one_touch)
      end
    elsif params[:verification_option] == 'sms'
      send_sms
      redirect_to edit_verification_path(id: current_user.id, verification_type: 'phone_number')
    end
  end

  def verify_email
    authorize @user
    token = create_user_confirmation_token(@user)
    NotificationMailer.email_verification(@user, token).deliver!
    respond_to do |format|
      format.json { render json: { user: @user, message: 'Instructions on verifying email address have been sent.' } }
      format.html {
        render 'show'
        flash[:notice] = 'Instructions on verifying email address have been sent.'
      }
    end
  end

  def email_confirmation
    authorize @user
    token = ConfirmationToken.where(user_id: @user.id).first
    if token.token == params[:confirmation_token]
      @user.email_verified = true
      @user.save!
      msg = 'Your email has been successfully verified.'
      flash[:notice] = msg
    else
      msg = 'Invalid confirmation token.'
      flash[:error] = msg
    end
    respond_to do |format|
      format.json { render json: { user: @user, message: msg } }
      format.html { render 'show' }
    end
  end

  def generate_api_key
    authorize @user
    @user.generate_api_key
    if @user.save
      msg = ['Please record this key.  If you lose it, you will have to generate a new key.',
             "Your API secret key is: #{@user.api_secret_key}"]
      msg = msg.join('<br/>').html_safe
      flash[:notice] = msg
    else
      flash[:alert] = 'ERROR: Unable to create API key.'
    end
    redirect_to user_path(@user)
  end

  def admin_password_reset
    authorize current_user
    password = "ABCabc-#{SecureRandom.hex(4)}"
    @user.password = password
    @user.password_confirmation = password
    @user.save!
    NotificationMailer.admin_password_reset(@user, password).deliver!
    redirect_to @user
    flash[:notice] = "Password has been reset for #{@user.email}. They will be notified of their new password via email."
  end

  def deactivate
    authorize @user
    unless Rails.env.test?
      if Rails.env.production?
        user_name = @user.name.split(' ').join('.')
      elsif Rails.env.demo?
        user_name = @user.name.split(' ').join('.') + '.test'
      else
        user_name = @user.name.split(' ').join('.') + '.' + Rails.env
      end
      msg_one = ''
      msg_two = ''
      begin
        client = setup_aws_client
        unless @user.aws_access_key.nil? || @user.aws_access_key == ''
          @response = client.delete_access_key({ access_key_id: @user.aws_access_key, user_name: user_name })
        end
        @user.aws_access_key = ''
        @user.save!
        msg_one = "AWS credentials for #{@user.name} were deleted."
      rescue => e
        logger.error "Exception in user#deactivate; Pharos and/or AWS was unsuccessful in deleting AWS credentials for #{@user.name}."
        logger.error e.message
        logger.error e.backtrace.join("\n")
        msg_one = "Pharos and/or AWS was unsuccessful in deleting AWS credentials for #{@user.name}. Response was: #{e}."
      end
      begin
        client = setup_aws_client
        @response_two = client.delete_user({ user_name: user_name })
        msg_two = "IAM user account for #{@user.name} was deleted."
      rescue => e
        logger.error "Exception in user#deactivate; Pharos and/or AWS was unsuccessful in deleting IAM account for #{@user.name}."
        logger.error e.message
        logger.error e.backtrace.join("\n")
        msg_two = "Pharos and/or AWS was unsuccessful in deleting IAM account for #{@user.name}. Response was: #{e}."
      end
    end
    @user.soft_delete
    (@user == current_user) ? sign_out(@user) : redirect_to(@user)
    flash[:notice] = "#{@user.name}'s account has been deactivated. #{msg_one} #{msg_two}"
  end

  def reactivate
    authorize current_user
    @user.reactivate
    unless Rails.env.test?
      if Rails.env.production?
        user_name = current_user.name.split(' ').join('.')
      elsif Rails.env.demo?
        user_name = current_user.name.split(' ').join('.') + '.test'
      else
        user_name = current_user.name.split(' ').join('.') + '.' + Rails.env
      end
      msg = ''
      begin
        client = setup_aws_client
        @response = client.create_user({ user_name: user_name })
        msg = "AWS IAM username is #{@response.user.user_name}."
      rescue => e
        logger.error "Exception in user#reactivate; Pharos and/or AWS was unsuccessful in creating an IAM account for #{@user.name}."
        logger.error e.message
        logger.error e.backtrace.join("\n")
        msg = "Pharos and/or AWS was unsuccessful in creating an IAM account for #{@user.name}. Response was: #{e}."
      end
    end
    redirect_to @user
    flash[:notice] = "#{@user.name}'s account has been reactivated. #{msg}"
  end

  def create_iam_user
    authorize @user
    unless Rails.env.test?
      if Rails.env.production?
        user_name = @user.name.split(' ').join('.')
      elsif Rails.env.demo?
        user_name = @user.name.split(' ').join('.') + '.test'
      else
        user_name = @user.name.split(' ').join('.') + '.' + Rails.env
      end
      msg = ''
      @response = 'You do not have an AWS IAM account. You will not be able to generate credentials until you have one. Please talk to your administrator about setting up an account.'
      begin
        client = setup_aws_client
        @response = client.create_user({ user_name: user_name })
        msg = "AWS IAM account was successfully created. Username is #{@response.user.user_name}."
      rescue => e
        logger.error "Exception in user#create_iam_user; Pharos and/or AWS was unsuccessful in creating an IAM account for #{@user.name}."
        logger.error e.message
        logger.error e.backtrace.join("\n")
        msg = "Pharos and/or AWS was unsuccessful in creating an IAM account for #{@user.name}. Response was: #{e}"
      end
      flash[:notice] = msg
    end
    respond_to do |format|
      format.html { render 'show' }
      format.json { render json: { status: :ok, message: msg } }
    end
  end

  def issue_aws_credentials
    authorize current_user
    if Rails.env.production?
      user_name = current_user.name.split(' ').join('.')
    elsif Rails.env.demo?
      user_name = current_user.name.split(' ').join('.') + '.test'
    else
      user_name = current_user.name.split(' ').join('.') + '.' + Rails.env
    end
    msg_one = ''
    msg_two = ''
    begin
      client = setup_aws_client
      unless @user.aws_access_key.nil? || @user.aws_access_key == ''
        @response = client.delete_access_key({ access_key_id: @user.aws_access_key, user_name: user_name })
      end
      msg_one = ''
    rescue => e
      logger.error "Exception in user#issue_aws_credentials; Pharos and/or AWS was unsuccessful in deleting AWS credentials for #{@user.name}, which is a necessary step in issuing new credentials."
      logger.error e.message
      logger.error e.backtrace.join("\n")
      msg_one = "Pharos and/or AWS was unsuccessful in deleting AWS credentials for #{@user.name}, which is a necessary step in issuing new credentials. Response was: #{e}."
    end
    if msg_one == ''
      begin
        client = setup_aws_client
        @response_two = client.create_access_key({ user_name: user_name })
        current_user.aws_access_key = response.access_key.access_key_id
        current_user.save!
        @acc_key_id = response.access_key.access_key_id
        @secret_key = response.access_key.secret_access_key
        msg_two = 'Your AWS credentials have been successfully created. Please store them somewhere safe.'
      rescue => e
        logger.error "Exception in user#issue_aws_credentials; Pharos and/or AWS was unsuccessful in creating AWS credentials for #{@user.name}."
        logger.error e.message
        logger.error e.backtrace.join("\n")
        msg_two = "Pharos and/or AWS was unsuccessful in creating AWS credentials for #{@user.name}. Response was: #{e}."
      end
    else
      msg_two = ''
    end
    respond_to do |format|
      format.html {
        render 'show'
        flash[:notice] = "#{msg_one} #{msg_two}"
      }
      format.json { render json: { status: :ok, message: "#{msg_one} #{msg_two}" } }
    end
  end

  def revoke_aws_credentials
    authorize @user
    if Rails.env.production?
      user_name = @user.name.split(' ').join('.')
    elsif Rails.env.demo?
      user_name = @user.name.split(' ').join('.') + '.test'
    else
      user_name = @user.name.split(' ').join('.') + '.' + Rails.env
    end
    msg = ''
    begin
      client = setup_aws_client
      unless @user.aws_access_key.nil? || @user.aws_access_key == ''
        @response = client.delete_access_key({ access_key_id: @user.aws_access_key, user_name: user_name })
      end
      @user.aws_access_key = ''
      @user.save!
      msg = "AWS credentials for #{@user.name} were deleted."
    rescue => e
      logger.error "Exception in user#revoke_aws_credentials; Pharos and/or AWS was unsuccessful in deleting AWS credentials for #{@user.name}."
      logger.error e.message
      logger.error e.backtrace.join("\n")
      msg = "Pharos and/or AWS was unsuccessful in deleting AWS credentials for #{@user.name}. Response was: #{e}."
    end
    respond_to do |format|
      format.json { render json: { status: :ok, message: msg } }
      format.html {
        render 'show'
        flash[:notice] = msg
      }
    end
  end

  def vacuum
    authorize current_user
    if params[:vacuum_target]
      query = set_query(params[:vacuum_target])
      ActiveRecord::Base.connection.exec_query(query)
      vacuum_associated_tables(params[:vacuum_target]) if params[:vacuum_target] == 'emails' || params[:vacuum_target] == 'roles'
      respond_to do |format|
        if params[:vacuum_target] == 'entire_database'
          msg = 'The whole database'
        else
          msg = "#{params[:vacuum_target].gsub('_', ' ').capitalize.chop!} table"
        end
        format.json { render json: { status: 'success', message: "#{msg} has been vacuumed."  } }
        format.html { flash[:notice] = "#{msg} has been vacuumed." }
      end
    else
      respond_to do |format|
        format.json { }
        format.html { }
      end
    end
  end

  def account_confirmations
    authorize current_user
    User.all.each do |user|
      unless user.admin?
        update_account_attributes(user)
        token = create_user_confirmation_token(user)
        NotificationMailer.account_confirmation(user, token).deliver!
      end
    end
    respond_to do |format|
      format.json { render json: { status: 'success', message: 'All users except admins have been sent their yearly account confirmation email.' }, status: :ok }
      format.html {
        flash[:notice] = 'All users except admins have been sent their yearly account confirmation email.'
        redirect_back fallback_location: root_path
      }
    end
  end

  def indiv_confirmation_email
    authorize @user
    update_account_attributes(@user)
    token = create_user_confirmation_token(@user)
    NotificationMailer.account_confirmation(@user, token).deliver!
    respond_to do |format|
      format.json { render json: { status: 'success', message: "A new account confirmation email has been sent to this email address: #{@user.email}." }, status: :ok }
      format.html { redirect_to @user, flash: { notice: "A new account confirmation email has been sent to this email address: #{@user.email}." } }
    end
  end

  def confirm_account
    authorize @user
    token = ConfirmationToken.where(user_id: @user.id).first
    if token.token == params[:confirmation_token]
      @user.account_confirmed = true
      @user.save!
      respond_to do |format|
        format.json { render json: { user: @user, message: 'Your account has been confirmed for the next year.' } }
        format.html { redirect_to @user, flash: { notice: 'Your account has been confirmed for the next year.' } }
      end
    else
      respond_to do |format|
        format.json { render json: { user: @user, message: 'Invalid confirmation token.' } }
        format.html { redirect_to @user, flash: { error: 'Invalid confirmation token.' } }
      end
    end
  end

  def stale_user_notification
    authorize current_user
    stale_users = User.stale_users
    if stale_users == []
      msg = 'There are no stale users at this time, no email has been sent out.'
    else
      NotificationMailer.stale_user_notification(stale_users).deliver!
      msg = 'The stale user notification email has been sent to the team.'
    end
    flash[:notice] = msg
    respond_to do |format|
      format.json { render json: { status: 'success', message: msg }, status: :ok }
      format.html {
        request.env['HTTP_REFERER'].nil? ? (redirect_to root_path) : (redirect_to(request.env['HTTP_REFERER']))
      }
    end
  end

  private

  # If an id is passed through params, use it.  Otherwise default to show the current user.
  def set_user
    @user = params[:id].nil? ? current_user : User.readable(current_user).find(params[:id])
  end

  def build_resource_params
    [params.fetch(:user, {}).permit(:name, :email, :phone_number, :password, :password_confirmation, :institution_id, :two_factor_enabled).tap do |p|
       p[:institution_id] = build_institution_id if params[:user][:institution_id] unless params[:user].nil?
       p[:role_ids] = build_role_ids if params[:user][:role_ids] unless params[:user].nil?
     end]
  end

  def build_institution_id
    if params[:user][:institution_id].empty?
      if @user.nil?
        instituion = ''
      else
        institution = Institution.find(@user.institution_id)
      end
    else
      institution = Institution.find(params[:user][:institution_id])
    end
    unless institution.nil?
      authorize institution, :add_user?
      institution.id
    end
  end

  def build_role_ids
    [].tap do |role_ids|
      unless params[:user][:role_ids].empty?
        roles = Role.find(params[:user][:role_ids])

        authorize roles, :add_user?
        role_ids << roles.id

      end
    end
  end

  def user_params
    params.required(:user).permit(:password, :password_confirmation, :current_password, :name, :email, :phone_number, :institution_id, :role_ids, :two_factor_enabled)
  end

  def setup_aws_client
    creds = Aws::Credentials.new(ENV['AWS_SES_USER'], ENV['AWS_SES_PWD'])
    client = Aws::IAM::Client.new(region: ENV['AWS_DEFAULT_REGION'], credentials: creds, instance_profile_credentials_timeout: 15, instance_profile_credentials_retries: 5)
    client
  end

  def set_query(target)
    case target
      when 'checksums'
        query = 'VACUUM (VERBOSE, ANALYZE) checksums'
      when 'confirmation_tokens'
        query = 'VACUUM (VERBOSE, ANALYZE) confirmation_tokens'
      when 'dpn_bags'
        query = 'VACUUM (VERBOSE, ANALYZE) dpn_bags'
      when 'dpn_work_items'
        query = 'VACUUM (VERBOSE, ANALYZE) dpn_work_items'
      when 'emails'
        query = 'VACUUM (VERBOSE, ANALYZE) emails'
      when 'generic_files'
        query = 'VACUUM (VERBOSE, ANALYZE) generic_files'
      when 'institutions'
        query = 'VACUUM (VERBOSE, ANALYZE) institutions'
      when 'intellectual_objects'
        query = 'VACUUM (VERBOSE, ANALYZE) intellectual_objects'
      when 'premis_events'
        query = 'VACUUM (VERBOSE, ANALYZE) premis_events'
      when 'roles'
        query = 'VACUUM (VERBOSE, ANALYZE) roles'
      when 'snapshots'
        query = 'VACUUM (VERBOSE, ANALYZE) snapshots'
      when 'usage_samples'
        query = 'VACUUM (VERBOSE, ANALYZE) usage_samples'
      when 'users'
        query = 'VACUUM (VERBOSE, ANALYZE) users'
      when 'work_items'
        query = 'VACUUM (VERBOSE, ANALYZE) work_items'
      when 'work_item_states'
        query = 'VACUUM (VERBOSE, ANALYZE) work_item_states'
      when 'entire_database'
        query = 'VACUUM (VERBOSE, ANALYZE)'
    end
    query
  end

  def vacuum_associated_tables(target)
    case target
      when 'emails'
        query = 'VACUUM (VERBOSE, ANALYZE) emails_premis_events'
        ActiveRecord::Base.connection.exec_query(query)
        query = 'VACUUM (VERBOSE, ANALYZE) emails_work_items'
        ActiveRecord::Base.connection.exec_query(query)
      when 'roles'
        query = 'VACUUM (VERBOSE, ANALYZE) roles_users'
        ActiveRecord::Base.connection.exec_query(query)
    end
  end

  def one_touch_status_for_users
    @user = current_user
    status = Authy::OneTouch.approval_request_status({uuid: session[:uuid]})
    if !status['errors'].nil? && !status['errors'].empty?
      logger.info "Checking one touch contents: #{status.inspect}"
      msg = "There was a problem verifying your push notification. Please try again. If the problem persists, please contact your administrator or an APTrust administrator for help, and let them know that the error message was: #{status['errors']['message']}."
      flash[:error] = msg
      respond_to do |format|
        format.json { render json: { message: msg }, status: :internal_server_error }
        format.html { redirect_to @user }
      end
    elsif status.ok?
      if session[:verify_timeout] <= 0
        msg = 'This push notification has expired'
        flash[:error] = msg
        respond_to do |format|
          format.json { render json: { message: msg }, status: :conflict }
          format.html { redirect_to @user }
        end
      else
        if status['approval_request']['status'] == 'approved'
          confirmed_two_factor_updates(@user)
          msg = 'Your phone number has been verified.'
          flash[:notice] = msg
          respond_to do |format|
            format.json { render json: { message: msg }, status: :ok }
            format.html { redirect_to @user }
          end
        elsif status['approval_request']['status'] == 'denied'
          msg = 'This request was denied, phone number has not been verified.'
          flash[:error] = msg
          respond_to do |format|
            format.json { render json: { message: msg }, status: :forbidden }
            format.html { redirect_to @user }
          end
        else
          recheck_one_touch_status_user
        end
      end
    end
  end
end