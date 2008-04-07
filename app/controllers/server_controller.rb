class ServerController < ApplicationController
  
  # CSRF-protection must be skipped, because incoming
  # OpenID requests lack an authenticity token
  skip_before_filter :verify_authenticity_token
  # Actions other than index require a logged in user
  before_filter :login_required, :except => [:index, :cancel]
  before_filter :ensure_valid_checkid_request, :except => [:index, :cancel]
  before_filter :clear_checkid_request, :only => [:index]
  after_filter :clear_checkid_request, :only => [:cancel]
  # These methods are used to display information about the request to the user
  helper_method :sreg_request, :required_sreg_fields, :optional_sreg_fields
  
  # This is the server endpoint which handles all incoming OpenID requests.
  # Associate and CheckAuth requests are answered directly - functionality
  # therefor is provided by the ruby-openid gem. Handling of CheckId requests
  # dependents on the users login state (see handle_checkid_request).
  # Yadis requests return information about this endpoint.
  def index
    respond_to do |format|
      format.html do
        if openid_request.is_a?(OpenID::Server::CheckIDRequest)
          handle_checkid_request
        elsif openid_request
          handle_non_checkid_request
        else
          render :text => 'This is an OpenID server endpoint, not a human readable resource.'
        end
      end
      format.xrds { @types = [ OpenID::OPENID_IDP_2_0_TYPE ] }
    end
  end
  
  # This action decides how to process the current request and serves as
  # dispatcher and re-entry in case the request could not be processed 
  # directly (for instance if the user had to log in first).
  # When the user has already trusted the relying party, the request will
  # be answered based on the users release policy. If the request is immediate
  # (relying party wants no user interaction, used e.g. for ajax requests)
  # the request can only be answered if no further information (like simple 
  # registration data) is requested. Otherwise the user will be redirected
  # to the decision page.
  def proceed
    identity = identifier(current_account)
    if @site = current_account.sites.find_by_url(checkid_request.trust_root)
      resp = checkid_request.answer(true, nil, identity)
      resp = add_sreg(checkid_request, resp, @site.properties) if sreg_request
      resp = add_pape(checkid_request, resp)
      render_response(resp)
    elsif checkid_request.immediate && sreg_request
      render_response(checkid_request.answer(false))
    elsif checkid_request.immediate
      render_response(checkid_request.answer(true, nil, identity))
    else
      redirect_to decide_path
    end
  end
  
  # Displays the decision page on that the user can confirm the request and
  # choose which data should be transfered to the relying party.
  def decide
    @site = current_account.sites.find_or_initialize_by_url(checkid_request.trust_root)
    @site.persona = current_account.personas.find(params[:persona_id] || :first) if sreg_request
  end
  
  # This action is called by submitting the decision form, the information entered by
  # the user is used to answer the request. If the user decides to always trust the
  # relying party, a new site according to the release policies the will be created.
  def complete
    if params[:cancel]
      cancel
    else
      if params[:always]
        @site = current_account.sites.find_or_create_by_persona_id_and_url(params[:site][:persona_id], params[:site][:url])
        @site.update_attributes(params[:site])
      end
      resp = checkid_request.answer(true, nil, identifier(current_account))
      resp = add_pape(checkid_request, resp)
      resp = add_sreg(checkid_request, resp, params[:site][:properties]) if sreg_request && params[:site][:properties]
      render_response(resp)
    end
  end
  
  # Cancels the current OpenID request
  def cancel
    redirect_to checkid_request.cancel_url
  end
  
  protected
  
  # Decides how to process an incoming checkid request. If the user is
  # already logged in he will be forwarded to the proceed action. If
  # the user is not logged in and the request is immediate, the request
  # cannot be answered successfully. In case the user is not logged in,
  # the request will be stored and the user is asked to log in.
  def handle_checkid_request
    if allow_verification?
      save_checkid_request
      redirect_to proceed_path
    elsif openid_request.immediate
      render_response(openid_request.answer(false))
    else
      save_checkid_request
      flash[:notice]  = 'A website requests your identification, please log in to proceed.'
      session[:return_to] = proceed_path
      redirect_to login_path
    end
  end
  
  # Stores the current OpenID request
  def save_checkid_request
    clear_checkid_request
    session[:request_token] = OpenIdRequest.create(:parameters => openid_params).token
  end
  
  # Deletes the old request when a new one comes in.
  # Use this as before_filter for your server endpoint.
  def clear_checkid_request
    unless session[:request_token].blank?
      OpenIdRequest.destroy_all :token => session[:request_token]
      session[:request_token] = nil
    end
  end
  
  # Use this as before_filter for every CheckID request based action.
  # Loads the current openid request and cancels if none can be found.
  # The user has to log in, if he has not verified his ownership of
  # the identifier, yet.
  def ensure_valid_checkid_request
    self.openid_request = checkid_request
    if !openid_request.is_a?(OpenID::Server::CheckIDRequest)
      flash[:error] = 'The identity verification request is invalid.'
      redirect_to home_path
    elsif !allow_verification?
      flash[:notice] = 'Please log in to verify your identity.'
      session[:return_to] = proceed_path
      redirect_to login_path
    end
  end
  
  # Is the user allowed to verify the claimed identifier? The user
  # must be logged in, so that we know his identifier or the identifier
  # has to be selected by the server (id_select)
  def allow_verification?
    logged_in? && (openid_request.identity == identifier(current_account) || openid_request.id_select)
  end
  
  # Clears the stored request and answers
  def render_response(resp)
    clear_checkid_request
    render_openid_response(resp)
  end
  
end