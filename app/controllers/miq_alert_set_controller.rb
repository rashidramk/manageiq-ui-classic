class MiqAlertSetController < ApplicationController
  before_action :check_privileges
  before_action :get_session_data
  after_action :cleanup_action
  after_action :set_session_data

  include Mixins::GenericFormMixin
  include Mixins::GenericListMixin
  include Mixins::GenericSessionMixin
  include Mixins::GenericShowMixin
  include Mixins::BreadcrumbsMixin
  include Mixins::PolicyMixin

  def title
    @title = _("Policies")
  end

  def alert_profile_load
    @alert_profile = @edit[:alert_profile_id] ? MiqAlertSet.find_by(:id => @edit[:alert_profile_id]) : MiqAlertSet.new
  end

  def alert_profile_edit_cancel
    return unless alert_profile_edit_load_edit
    @edit = nil
    if @alert_profile && @alert_profile.id.blank?
      flash_msg = _("Add of new Alert Profile was cancelled by the user")
    else
      flash_msg = _("Edit of Alert Profile \"%{name}\" was cancelled by the user") % {:name => @alert_profile.description}
    end
    @edit = session[:edit] = nil # clean out the saved info
    session[:changed] = false
    javascript_redirect(:action => @lastaction, :id => params[:id], :flash_msg => flash_msg)
  end

  def alert_profile_edit_reset
    alert_profile_build_edit_screen
    javascript_redirect(:action        => 'edit',
                        :id            => params[:id],
                        :flash_msg     => _("All changes have been reset"),
                        :flash_warning => true) if params[:button] == "reset"
  end

  def alert_profile_edit_save_add
    assert_privileges("miq_alert_set_#{@alert_profile.id ? "edit" : "new"}")
    add_flash(_("Alert Profile must contain at least one Alert"), :error) if @edit[:new][:alerts].empty?
    add_flash(_("Mode is required"), :error) if @edit[:new][:mode].blank?

    alert_profile = @alert_profile.id.blank? ? MiqAlertSet.new : MiqAlertSet.find(@alert_profile.id) # Get new or existing record
    alert_profile.description = @edit[:new][:description]
    alert_profile.notes = @edit[:new][:notes]
    alert_profile.mode = @edit[:new][:mode]

    unless alert_profile.valid? && !@flash_array && alert_profile.save
      alert_profile.errors.each do |field, msg|
        add_flash("#{field.to_s.capitalize} #{msg}", :error)
      end
      javascript_flash
      return
    end

    alerts = alert_profile.members                        # Get the sets members
    current = alerts.collect(&:id)                        # Build an array of the current alert ids
    mems = @edit[:new][:alerts].invert                    # Get the ids from the member list box
    begin
      alerts.each { |a| alert_profile.remove_member(MiqAlert.find(a)) unless mems.include?(a.id) } # Remove any alerts no longer in the members list box
      mems.each_key { |m| alert_profile.add_member(MiqAlert.find(m)) unless current.include?(m) }  # Add any alerts not in the set
    rescue StandardError => bang
      add_flash(_("Error during 'Alert Profile %{params}': %{message}") %
                  {:params => params[:button], :message => bang.message}, :error)
      javascript_flash
    end
    AuditEvent.success(build_saved_audit(alert_profile, @edit))
    flash_key = params[:button] == "save" ? _("Alert Profile \"%{name}\" was saved") : _("Alert Profile \"%{name}\" was added")
    flash_msg = (flash_key % {:name => @edit[:new][:description]})
    @edit = session[:edit] = nil # clean out the saved info
    session[:changed] = @changed = false
    javascript_redirect(:controller => 'miq_alert_set', :action => @lastaction, :id => params[:id], :flash_msg => flash_msg)
  end

  def alert_profile_edit_move
    handle_selection_buttons(:alerts)
  end

  def alert_profile_edit_load_edit
    # Load @edit/vars for other buttons
    id = params[:id] || 'new'
    return false unless load_edit("alert_profile_edit__#{id}")

    alert_profile_load
    true
  end

  def new
    alert_profile_edit_reset
  end

  def edit
    case params[:button]
    when 'cancel'
      alert_profile_edit_cancel
    when 'reset', nil # Reset or first time in
      @_params[:id] ||= find_checked_items[0]
      alert_profile_edit_reset
    when 'save', 'add'
      return unless alert_profile_edit_load_edit
      alert_profile_edit_save_add
    when 'move_right', 'move_left', 'move_allleft'
      return unless alert_profile_edit_load_edit
      alert_profile_edit_move
      @changed = (@edit[:new] != @edit[:current])
      render :update do |page|
        page << javascript_prologue
        page.replace("flash_msg_div", :partial => "layouts/flash_msg")
        page.replace_html("form_div", :partial => "form") unless @flash_errors
      end
    end
  end

  def edit_assignment
    miq_alert_set_assign
  end

  def miq_alert_set_assign
    assert_privileges("miq_alert_set_assign")
    @assign = @sb[:assign]
    @alert_profile = @assign[:alert_profile] if @assign
    case params[:button]
    when "cancel"
      @assign = nil
      flash_msg = _("Edit Alert Profile assignments cancelled by user")
      @assign = nil # clean out the saved info
      session[:changed] = false
      javascript_redirect(:action => @lastaction, :id => params[:id], :flash_msg => flash_msg)
    when "save"
      if @assign[:new][:assign_to].to_s.ends_with?("-tags") && !@assign[:new][:cat]
        add_flash(_("A Tag Category must be selected"), :error)
      elsif @assign[:new][:assign_to] && @assign[:new][:assign_to] != "enterprise" && @assign[:new][:objects].empty?
        add_flash(_("At least one Selection must be checked"), :error)
      end
      if flash_errors?
        javascript_flash
      else
        alert_profile_assign_save
        flash_msg = _("Alert Profile \"%{alert_profile}\" assignments successfully saved") %
                    {:alert_profile => @alert_profile.description}
        @assign = nil # clean out the saved info
        session[:changed] = @changed = false
        javascript_redirect(:controller => 'miq_alert_set', :action => @lastaction, :id => params[:id], :flash_msg => flash_msg)
      end
    when "reset", nil # Reset or first time in
      alert_profile_build_assign_screen
      javascript_redirect(:action        => 'edit_assignment',
                          :id            => params[:id],
                          :flash_msg     => _("All changes have been reset"),
                          :flash_warning => true) if params[:button] == "reset"
    end
  end

  def alert_profile_field_changed
    return unless load_edit("alert_profile_edit__#{params[:id]}", "replace_cell__explorer")

    @alert_profile = @edit[:alert_profile_id] ? MiqAlertSet.find(@edit[:alert_profile_id]) : MiqAlertSet.new

    @edit[:new][:description] = params[:description].presence if params[:description]
    @edit[:new][:notes] = params[:notes].presence if params[:notes]
    if params[:mode]
      @edit[:new][:mode] = params[:mode]
      get_alerts
    end

    send_button_changes
  end

  def alert_profile_assign_changed
    @assign = @sb[:assign]
    @alert_profile = @assign[:alert_profile]

    if params.key?(:chosen_assign_to)
      @assign[:new][:assign_to] = params[:chosen_assign_to].presence
      @assign[:new][:cat] = nil # Clear chosen tag category
    end

    @assign[:new][:cat] = params[:chosen_cat].blank? ? nil : params[:chosen_cat].to_i if params.key?(:chosen_cat)
    if params.key?(:chosen_assign_to) || params.key?(:chosen_cat)
      @assign[:new][:objects] = []                      # Clear selected objects
      @assign[:obj_tree] = alert_profile_build_obj_tree # Build the selection tree
    end
    if params.key?(:id)
      if params[:check] == "1"
        @assign[:new][:objects].push(params[:id].split("-").last.to_i)
        @assign[:new][:objects].sort!
      else
        @assign[:new][:objects].delete(params[:id].split("-").last.to_i)
      end
    end

    send_button_changes
  end

  # Get information for an alert profile
  def show
    super
    @alert_profile = @record
    aa = @alert_profile.get_assigned_tos
    @alert_profile_tag = Classification.find(aa[:tags].first.first.parent_id) unless aa[:tags].empty?
    @alert_profile_alerts = @alert_profile.miq_alerts.sort_by { |a| a.description.downcase }
  end

  private

  def alert_profile_get_assign_to_objects_empty?
    return true if @assign[:new][:assign_to].blank?
    return true if @assign[:new][:assign_to] == "enterprise"
    return true if @assign[:new][:assign_to].ends_with?("-tags") && @assign[:new][:cat].blank?

    false
  end

  # Build the assign objects selection tree
  def alert_profile_build_obj_tree
    return nil if alert_profile_get_assign_to_objects_empty?

    if @assign[:new][:assign_to] == "ems_folder"
      instantiate_tree("TreeBuilderEmsFolders", :ems_folders_tree,
                       @assign[:new][:objects].collect { |f| "EmsFolder_#{f}" })
    elsif @assign[:new][:assign_to] == "resource_pool"
      instantiate_tree("TreeBuilderResourcePools", :resource_pools_tree,
                       @assign[:new][:objects].collect { |f| "ResourcePool_#{f}" })
    else
      instantiate_tree("TreeBuilderAlertProfileObj", :object_tree, @assign[:new][:objects])
    end
  end

  def instantiate_tree(tree_class, tree_name, selected_nodes)
    tree_class.constantize.new(tree_name,
                               @sb,
                               true,
                               :assign_to      => @assign[:new][:assign_to],
                               :cat            => @assign[:new][:cat],
                               :selected_nodes => selected_nodes)
  end

  def alert_profile_build_edit_screen
    @edit = {}
    @edit[:new] = {}
    @edit[:current] = {}

    @alert_profile = params[:id] ? MiqAlertSet.find(params[:id]) : MiqAlertSet.new # Get existing or new record
    @edit[:key] = "alert_profile_edit__#{@alert_profile.id || "new"}"
    @edit[:rec_id] = @alert_profile.id || nil

    @edit[:alert_profile_id] = @alert_profile.id
    @edit[:new][:description] = @alert_profile.description
    @edit[:new][:notes] = @alert_profile.notes
    @edit[:new][:mode] = @alert_profile.mode # Use existing model or model from selected folder

    @edit[:new][:alerts] = {}
    alerts = @alert_profile.members # Get the set's members
    alerts.each { |a| @edit[:new][:alerts][a.description] = a.id } # Build a hash for the members list box

    get_alerts

    @edit[:current] = copy_hash(@edit[:new])

    @embedded = true
    @in_a_form = true
    @edit[:current][:add] = true unless @edit[:alert_profile_id] # Force changed to be true if adding a record
    session[:changed] = (@edit[:new] != @edit[:current])
  end

  def get_alerts
    @edit[:choices] = {}
    MiqAlert.where(:db => @edit[:new][:mode]).select(:id, :description).each do |a|
      @edit[:choices][a.description] = a.id # Build a hash for the alerts to choose from
    end

    @edit[:new][:alerts].each_key do |key|
      @edit[:choices].delete(key) # Remove any alerts that are in the members list box
    end
  end

  def alert_profile_build_assign_screen
    @assign = {}
    @assign[:new] = {}
    @assign[:current] = {}
    @sb[:action] = "miq_alert_set_assign"
    @assign[:rec_id] = params[:id]

    @alert_profile = MiqAlertSet.find(params[:id])            # Get existing record
    @assign[:alert_profile] = @alert_profile

    @assign[:cats] = {}
    Classification.categories.find_all { |c| !c.read_only? && c.show && !c.entries.empty? }
                  .each { |c| @assign[:cats][c.id] = c.description }

    @assign[:new][:assign_to] = nil
    @assign[:new][:cat] = nil
    @assign[:new][:objects] = []
    aa = @alert_profile.get_assigned_tos
    if !aa[:objects].empty?                                   # Objects are assigned
      if aa[:objects].first.kind_of?(MiqEnterprise)           # Assigned to Enterprise object
        @assign[:new][:assign_to] = "enterprise"
      else                                                    # Assigned to CIs
        @assign[:new][:assign_to] = aa[:objects].first.class.base_class.to_s.underscore
        @assign[:new][:objects] = aa[:objects].collect(&:id).sort!
      end
    elsif !aa[:tags].empty?                                   # Tags are assigned
      @assign[:new][:assign_to] = aa[:tags].first.last + "-tags"
      @assign[:new][:cat] = aa[:tags].first.first.parent_id
      @assign[:new][:objects] = aa[:tags].collect { |o| o.first.id }
    end
    @assign[:obj_tree] = alert_profile_build_obj_tree         # Build the selection tree

    @assign[:current] = copy_hash(@assign[:new])

    @embedded = true
    @in_a_form = true
    session[:changed] = (@assign[:new] != @assign[:current])
  end

  # Save alert profile assignments
  def alert_profile_assign_save
    @alert_profile.remove_all_assigned_tos                # Remove existing assignments
    if @assign[:new][:assign_to]                          # If an assignment is selected
      if @assign[:new][:assign_to] == "enterprise"        # Assign to enterprise
        @alert_profile.assign_to_objects(MiqEnterprise.first)
      elsif @assign[:new][:assign_to].ends_with?("-tags") # Assign to selected tags
        @alert_profile.assign_to_tags(@assign[:new][:objects], @assign[:new][:assign_to].split("-").first)
      elsif @assign[:new][:assign_to]                     # Assign to selected objects
        @alert_profile.assign_to_objects(@assign[:new][:objects], @assign[:new][:assign_to])
      end
    end
  end

  def get_session_data
    @title = _("Alert Profiles")
    @layout =  "miq_alert_set"
    @lastaction = session[:miq_alert_set_lastaction]
    @display = session[:miq_alert_set_display]
    @current_page = session[:miq_alert_set_current_page]
  end

  def set_session_data
    super
    session[:layout]                     = @layout
    session[:miq_alert_set_current_page] = @current_page
  end

  def breadcrumbs_options
    {
      :breadcrumbs  => [
        {:title => _("Control")},
        {:title => _('Alert Profiles'), :url => controller_url},
      ].compact,
      :record_title => :description,
    }
  end

  toolbar :miq_alert_set, :miq_alert_sets
  menu_section :con
end
